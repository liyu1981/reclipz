//! Child process execution: capture stdout/stderr to files (no pipe deadlocks), enforce a wall
//! clock timeout, and kill the whole process group so yt-dlp's ffmpeg children die with it.

const std = @import("std");
const builtin = @import("builtin");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");

pub const Options = struct {
    timeout_ms: u64 = 300_000,
    max_capture: usize = 8 << 20,
    /// Directory for the temporary stdout/stderr capture files.
    tmp_dir: []const u8,
    stdout_path: ?[]const u8 = null,
    stderr_path: ?[]const u8 = null,
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool,

    pub fn exitCode(self: Result) i32 {
        return switch (self.term) {
            .exited => |code| @as(i32, code),
            else => -1,
        };
    }

    pub fn ok(self: Result) bool {
        return !self.timed_out and self.exitCode() == 0;
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
    }) catch |e| {
        out_file.close(io);
        err_file.close(io);
        return e;
    };
    // The child inherited the descriptors; our copies can be closed now.
    out_file.close(io);
    err_file.close(io);

    const pid = child.id orelse 0;

    var done = std.atomic.Value(bool).init(false);
    var killed = std.atomic.Value(bool).init(false);

    const Watchdog = struct {
        io: std.Io,
        pid: std.posix.pid_t,
        done: *std.atomic.Value(bool),
        killed: *std.atomic.Value(bool),
        timeout_ms: u64,

        fn main(w: @This()) void {
            var waited: u64 = 0;
            while (waited < w.timeout_ms) : (waited += 100) {
                if (w.done.load(.acquire)) return;
                w.io.sleep(.fromMilliseconds(100), .awake) catch {};
            }
            if (w.done.load(.acquire)) return;
            w.killed.store(true, .release);
            log.warn("job exceeded {d} ms; killing process group {d}", .{ w.timeout_ms, w.pid });
            killGroup(w.pid);
        }
    };

    var thread: ?std.Thread = null;
    if (opts.timeout_ms > 0 and builtin.os.tag != .windows) {
        thread = std.Thread.spawn(.{}, Watchdog.main, .{Watchdog{
            .io = io,
            .pid = @intCast(pid),
            .done = &done,
            .killed = &killed,
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
    };
}

fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, std.posix.SIG.KILL) catch {
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    };
}

/// Run with inherited stdio (used by `reclipz yt-dlp ...` / `reclipz ffmpeg ...`).
pub fn passthrough(io: std.Io, argv: []const []const u8) !u8 {
    var child = try std.process.spawn(io, .{ .argv = argv });
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
    };
    try std.testing.expectEqualStrings("ERROR: Unsupported URL: https://x", r.lastStderrLine());
}
