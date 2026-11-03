//! In-memory job registry + worker threads (mirrors reclip's `jobs` dict + thread-per-download).

const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const payload = @import("payload.zig");
const proc = @import("proc.zig");

pub const Status = enum {
    downloading,
    done,
    failed,

    pub fn asApiString(self: Status) []const u8 {
        return switch (self) {
            .downloading => "downloading",
            .done => "done",
            .failed => "error",
        };
    }
};

pub const Job = struct {
    id: []const u8,
    url: []const u8,
    title: []const u8,
    status: Status = .downloading,
    err: ?[]const u8 = null,
    file: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    created_ns: i128 = 0,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    paths: *const payload.Paths,
    mutex: std.Io.Mutex = .init,
    jobs: std.StringHashMap(*Job),
    sem: std.Io.Semaphore = .{},
    active: std.atomic.Value(u32) = .init(0),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, paths: *const payload.Paths) !Registry {
        var reg: Registry = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .paths = paths,
            .jobs = std.StringHashMap(*Job).init(gpa),
        };
        reg.sem.permits = if (cfg.max_concurrent == 0) 1 else cfg.max_concurrent;
        return reg;
    }

    fn lock(self: *Registry) void {
        self.mutex.lockUncancelable(self.io);
    }
    fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io);
    }

    /// A copy of a job's state, safe to use after the lock is released (and across sweeps).
    pub const Snapshot = struct {
        status: Status,
        err: ?[]const u8 = null,
        filename: ?[]const u8 = null,
        file: ?[]const u8 = null,
    };

    pub fn snapshot(self: *Registry, allocator: std.mem.Allocator, id: []const u8) !?Snapshot {
        self.lock();
        defer self.unlock();
        const job = self.jobs.get(id) orelse return null;
        return Snapshot{
            .status = job.status,
            .err = if (job.err) |e| try allocator.dupe(u8, e) else null,
            .filename = if (job.filename) |f| try allocator.dupe(u8, f) else null,
            .file = if (job.file) |f| try allocator.dupe(u8, f) else null,
        };
    }

    /// Start a download job. Returns the job id (10 hex chars, like reclip).
    pub fn start(
        self: *Registry,
        url: []const u8,
        choice: engine.FormatChoice,
        format_id: ?[]const u8,
        title: []const u8,
    ) ![]const u8 {
        const id = try self.newId();
        const job = try self.gpa.create(Job);
        job.* = .{
            .id = id,
            .url = try self.gpa.dupe(u8, url),
            .title = try self.gpa.dupe(u8, title),
            .created_ns = self.now(),
        };

        self.lock();
        try self.jobs.put(job.id, job);
        self.unlock();

        const ctx = try self.gpa.create(Ctx);
        ctx.* = .{
            .reg = self,
            .job = job,
            .choice = choice,
            .format_id = if (format_id) |f| try self.gpa.dupe(u8, f) else null,
        };
        const thread = std.Thread.spawn(.{}, worker, .{ctx}) catch |e| {
            self.gpa.destroy(ctx);
            self.setError(job, "Could not start download worker");
            return e;
        };
        thread.detach();
        return job.id;
    }

    fn now(self: *Registry) i128 {
        return std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds;
    }

    fn newId(self: *Registry) ![]const u8 {
        var bytes: [5]u8 = undefined;
        self.io.random(&bytes);
        return std.fmt.allocPrint(self.gpa, "{x}", .{&bytes});
    }

    fn setError(self: *Registry, job: *Job, message: []const u8) void {
        self.lock();
        defer self.unlock();
        if (job.status != .done) {
            job.status = .failed;
            job.err = self.gpa.dupe(u8, message) catch null;
        }
    }

    fn setDone(self: *Registry, job: *Job, file: []const u8, filename: []const u8) void {
        self.lock();
        defer self.unlock();
        job.status = .done;
        job.file = file;
        job.filename = filename;
        job.err = null;
    }

    /// Drop finished jobs older than the TTL (no-op when TTL is 0).
    pub fn sweep(self: *Registry) void {
        if (self.cfg.job_ttl_s == 0) return;
        const ttl_ns: i128 = @as(i128, @intCast(self.cfg.job_ttl_s)) * std.time.ns_per_s;
        const cutoff = self.now() - ttl_ns;
        var doomed = std.ArrayList(*Job).empty;
        defer doomed.deinit(self.gpa);

        self.lock();
        var it = self.jobs.iterator();
        while (it.next()) |kv| {
            const job = kv.value_ptr.*;
            if (job.status == .downloading) continue;
            if (job.created_ns > cutoff) continue;
            if (job.file) |f| std.Io.Dir.cwd().deleteFile(self.io, f) catch {};
            doomed.append(self.gpa, job) catch continue;
        }
        for (doomed.items) |job| {
            _ = self.jobs.remove(job.id);
            self.gpa.free(job.id);
            self.gpa.free(job.url);
            self.gpa.free(job.title);
            if (job.err) |e| self.gpa.free(e);
            if (job.file) |f| self.gpa.free(f);
            if (job.filename) |f| self.gpa.free(f);
            self.gpa.destroy(job);
        }
        self.unlock();
    }
};

const Ctx = struct {
    reg: *Registry,
    job: *Job,
    choice: engine.FormatChoice,
    format_id: ?[]const u8,
};

fn worker(ctx: *Ctx) void {
    const reg = ctx.reg;
    defer reg.gpa.destroy(ctx);
    _ = reg.active.fetchAdd(1, .monotonic);
    defer _ = reg.active.fetchSub(1, .monotonic);
    reg.sem.waitUncancelable(reg.io);
    defer reg.sem.post(reg.io);

    download(reg, ctx) catch |e| {
        log.err("job {s} internal error: {s}", .{ ctx.job.id, @errorName(e) });
        reg.setError(ctx.job, @errorName(e));
    };
}

fn download(reg: *Registry, ctx: *Ctx) !void {
    const gpa = reg.gpa;
    const io = reg.io;
    const cfg = reg.cfg;
    const job = ctx.job;

    const job_dir = try std.fmt.allocPrint(gpa, "{s}/.tmp/{s}", .{ cfg.download_dir, job.id });
    try fsutil.ensureDir(io, job_dir);
    const template = try std.fmt.allocPrint(gpa, "{s}/{s}.%(ext)s", .{ job_dir, job.id });

    const argv = try engine.downloadArgv(gpa, cfg, reg.paths, job.url, ctx.choice, ctx.format_id, template);
    const res = engine.run(io, gpa, cfg, argv) catch |e| {
        reg.setError(job, try std.fmt.allocPrint(gpa, "Engine failed to start: {s}", .{@errorName(e)}));
        return;
    };

    if (res.timed_out) {
        reg.setError(job, "Download timed out (5 min limit)");
        return;
    }
    if (!res.ok()) {
        const line = try gpa.dupe(u8, res.lastStderrLine());
        log.info("job {s} failed: {s}", .{ job.id, line });
        reg.setError(job, line);
        return;
    }

    const want_ext = if (ctx.choice == .audio) ".mp3" else ".mp4";
    const found = (try engine.findOutputFile(io, gpa, job_dir, job.id, want_ext)) orelse {
        reg.setError(job, "Download completed but no file was found");
        return;
    };

    const base = fsutil.baseName(found);
    const ext = std.fs.path.extension(base);
    const final_path = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ cfg.download_dir, job.id, ext });
    std.Io.Dir.cwd().rename(found, std.Io.Dir.cwd(), final_path, io) catch |e| {
        reg.setError(job, try std.fmt.allocPrint(gpa, "Could not finalize file: {s}", .{@errorName(e)}));
        return;
    };
    std.Io.Dir.cwd().deleteTree(io, job_dir) catch {};

    const safe = try engine.sanitizeFilename(gpa, job.title);
    const filename = if (safe.len != 0)
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ safe, ext })
    else
        try gpa.dupe(u8, base);

    reg.setDone(job, final_path, filename);
    log.info("job {s} done -> {s}", .{ job.id, filename });
}
