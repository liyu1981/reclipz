//! Child process execution: capture stdout/stderr to files (no pipe deadlocks), enforce a wall
//! clock timeout, stream progress lines, support cancellation, and kill the whole process group
//! so yt-dlp's ffmpeg children die with it.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");

pub const ProgressSink = struct {
    ctx: *anyopaque,
    onLine: *const fn (ctx: *anyopaque, line: []const u8) void,
};

pub const Options = struct {
    timeout_ms: u64 = 300_000,
    max_capture: usize = 8 << 20,
    /// Directory for the temporary stdout/stderr capture files.
    tmp_dir: []const u8,
    stdout_path: ?[]const u8 = null,
    stderr_path: ?[]const u8 = null,
    /// Environment for the child (TMPDIR, PATH, ...). `null` inherits the parent's.
    env_map: ?*const std.process.Environ.Map = null,
    /// Optional progress line sink (engine `--progress-template` output).
    progress: ?ProgressSink = null,
    /// Set to true to abort the child (kills the whole process group).
    cancel: ?*const std.atomic.Value(bool) = null,
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool,
    cancelled: bool,

    pub fn exitCode(self: Result) i32 {
        return switch (self.term) {
            .exited => |code| @as(i32, code),
            else => -1,
        };
    }

    pub fn ok(self: Result) bool {
        return !self.timed_out and !self.cancelled and self.exitCode() == 0;
    }

    /// yt-dlp prints `ERROR: ...` lines; reclip shows the last stderr line verbatim.
    pub fn lastStderrLine(self: Result) []const u8 {
        var it = std.mem.splitBackwardsScalar(u8, self.stderr, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0) return trimmed;
        }
        return "Download failed";
    }
};

/// Live child process groups, so a shutdown or timeout can kill them all.
var live_pids: [64]std.atomic.Value(i32) = @splat(.init(0));

fn registerPid(pid: i32) void {
    for (&live_pids) |*slot| {
        if (slot.cmpxchgStrong(0, pid, .acq_rel, .acquire) == null) return;
    }
}

fn unregisterPid(pid: i32) void {
    for (&live_pids) |*slot| {
        if (slot.load(.acquire) == pid) {
            slot.store(0, .release);
            return;
        }
    }
}

/// SIGTERM every live engine process group (used on server shutdown).
pub fn killAll() void {
    for (&live_pids) |*slot| {
        const pid = slot.load(.acquire);
        if (pid > 0) killGroup(pid);
    }
}

fn killGroup(pid: i32) void {
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    };
}

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    opts: Options,
) !Result {
    var id_bytes: [8]u8 = undefined;
    io.random(&id_bytes);
    const id = std.mem.readInt(u64, &id_bytes, .little);
    const out_path = opts.stdout_path orelse try std.fmt.allocPrint(gpa, "{s}/run-{x}.out", .{ opts.tmp_dir, id });
    const err_path = opts.stderr_path orelse try std.fmt.allocPrint(gpa, "{s}/run-{x}.err", .{ opts.tmp_dir, id });

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    var err_file = try std.Io.Dir.cwd().createFile(io, err_path, .{ .truncate = true });

    log.debug("exec: {s}", .{try std.mem.join(gpa, " ", argv)});

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = out_file },
        .stderr = .{ .file = err_file },
        .pgid = 0,
        .environ_map = opts.env_map,
    }) catch |e| {
        out_file.close(io);
        err_file.close(io);
        return e;
    };
    out_file.close(io);
    err_file.close(io);

    const pid: i32 = @intCast(child.id orelse 0);
    if (pid > 0) registerPid(pid);
    defer if (pid > 0) unregisterPid(pid);

    var done = std.atomic.Value(bool).init(false);
    var killed = std.atomic.Value(bool).init(false);
    var cancelled = std.atomic.Value(bool).init(false);

    const Monitor = struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        pid: i32,
        done: *std.atomic.Value(bool),
        killed: *std.atomic.Value(bool),
        cancelled: *std.atomic.Value(bool),
        cancel: ?*const std.atomic.Value(bool),
        progress: ?ProgressSink,
        stdout_path: []const u8,
        timeout_ms: u64,

        fn main(m: @This()) void {
            const step_ms: u64 = 200;
            var waited: u64 = 0;
            var consumed: usize = 0;
            var progress_eof = false;

            while (!m.done.load(.acquire)) {
                if (m.cancel) |flag| {
                    if (flag.load(.acquire)) {
                        m.cancelled.store(true, .release);
                        log.info("cancelling engine pid {d}", .{m.pid});
                        killGroup(m.pid);
                        return;
                    }
                }

                if (m.progress) |sink| {
                    if (!progress_eof) consumed = pumpProgress(m.io, m.gpa, m.stdout_path, consumed, sink, &progress_eof);
                }

                if (waited >= m.timeout_ms) {
                    m.killed.store(true, .release);
                    log.warn("job exceeded {d} ms; killing process group {d}", .{ m.timeout_ms, m.pid });
                    killGroup(m.pid);
                    return;
                }
                m.io.sleep(.fromMilliseconds(step_ms), .awake) catch {};
                waited += step_ms;
            }
        }
    };

    var thread: ?std.Thread = null;
    if (builtin.os.tag != .windows and (opts.timeout_ms > 0 or opts.progress != null or opts.cancel != null)) {
        thread = std.Thread.spawn(.{}, Monitor.main, .{Monitor{
            .io = io,
            .gpa = gpa,
            .pid = pid,
            .done = &done,
            .killed = &killed,
            .cancelled = &cancelled,
            .cancel = opts.cancel,
            .progress = opts.progress,
            .stdout_path = out_path,
            .timeout_ms = opts.timeout_ms,
        }}) catch null;
    }

    const term = child.wait(io) catch |e| {
        done.store(true, .release);
        if (thread) |t| t.join();
        return e;
    };
    done.store(true, .release);
    if (thread) |t| t.join();

    const stdout = fsutil.readFileAlloc(io, gpa, out_path, opts.max_capture) catch try gpa.dupe(u8, "");
    const stderr = fsutil.readFileAlloc(io, gpa, err_path, opts.max_capture) catch try gpa.dupe(u8, "");

    if (opts.stdout_path == null) std.Io.Dir.cwd().deleteFile(io, out_path) catch {};
    if (opts.stderr_path == null) std.Io.Dir.cwd().deleteFile(io, err_path) catch {};

    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
        .timed_out = killed.load(.acquire),
        .cancelled = cancelled.load(.acquire),
    };
}

/// Read new complete lines from the child's stdout capture file and feed the progress sink.
fn pumpProgress(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    consumed_start: usize,
    sink: ProgressSink,
    eof: *bool,
) usize {
    const max = 4 << 20;
    const data = fsutil.readFileAlloc(io, gpa, path, max) catch return consumed_start;
    defer gpa.free(data);

    var consumed = consumed_start;
    if (consumed >= data.len) return consumed;
    while (std.mem.indexOfScalar(u8, data[consumed..], '\n')) |rel| {
        const line = std.mem.trim(u8, data[consumed .. consumed + rel], " \t\r");
        consumed += rel + 1;
        if (line.len != 0) sink.onLine(sink.ctx, line);
    }
    if (data.len >= max) eof.* = true;
    return consumed;
}

/// Run with inherited stdio (used by `reclipz yt-dlp ...` / `reclipz ffmpeg ...`).
pub fn passthrough(io: std.Io, argv: []const []const u8, env_map: ?*const std.process.Environ.Map) !u8 {
    var child = try std.process.spawn(io, .{ .argv = argv, .environ_map = env_map });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

test "last stderr line" {
    const r: Result = .{
        .term = .{ .exited = 1 },
        .stdout = "",
        .stderr = "noise\n\nERROR: Unsupported URL: https://x\n",
        .timed_out = false,
        .cancelled = false,
    };
    try std.testing.expectEqualStrings("ERROR: Unsupported URL: https://x", r.lastStderrLine());
}
