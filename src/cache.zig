//! Cache/download inspection and cleanup: `reclipz cache info` / `reclipz cache clean`, plus the
//! maintenance helpers used at startup and by the periodic sweeper.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const manifest = @import("payload_manifest");
const payload = @import("payload.zig");

pub const Usage =
    \\usage: reclipz cache <command>
    \\
    \\  reclipz cache info [--json]        show sizes of the engine cache and downloads
    \\  reclipz cache clean [options]      remove data that is safe to regenerate/delete
    \\    --tmp        stale temp files (older than RECLIPZ_TMP_TTL, default 1h)
    \\    --engines    engine versions other than the active one
    \\    --downloads  finished download files (destructive!)
    \\    --all        tmp + engines + downloads
    \\    --dry-run    print what would be removed
    \\
;

pub const Info = struct {
    cache_dir: []const u8,
    cache_bytes: u64,
    tmp_bytes: u64,
    tmp_entries: u64,
    engines_bytes: u64,
    downloads_dir: []const u8,
    downloads_bytes: u64,
    downloads_files: u64,
    active_version: []const u8,
    job_ttl_s: u64,
    tmp_ttl_s: u64,

    pub fn writeJson(self: Info, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(self, .{}, writer);
    }
};

const Size = struct { bytes: u64 = 0, entries: u64 = 0 };

fn dirSize(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Size {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return .{};
    defer walker.deinit();

    var size: Size = .{};
    while (walker.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
                size.bytes += st.size;
                size.entries += 1;
            },
            else => {},
        }
    }
    return size;
}

/// Newest mtime among the files inside `path` (used to decide whether a leaked extraction
/// directory is entirely stale).
fn newestMtime(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?i96 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(gpa) catch return null;
    defer walker.deinit();

    var newest: ?i96 = null;
    while (walker.next(io) catch null) |entry| {
        const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        const t = st.mtime.nanoseconds;
        if (newest == null or t > newest.?) newest = t;
    }
    return newest;
}

pub fn inspect(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config) !Info {
    const cache = dirSize(io, gpa, cfg.cache_dir);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}/tmp", .{cfg.cache_dir});
    const tmp = dirSize(io, gpa, tmp_path);
    const engines_path = try std.fmt.allocPrint(gpa, "{s}/bin", .{cfg.cache_dir});
    const engines = dirSize(io, gpa, engines_path);
    const downloads = dirSize(io, gpa, cfg.download_dir);

    return .{
        .cache_dir = cfg.cache_dir,
        .cache_bytes = cache.bytes -| tmp.bytes,
        .tmp_bytes = tmp.bytes,
        .tmp_entries = tmp.entries,
        .engines_bytes = engines.bytes,
        .downloads_dir = cfg.download_dir,
        .downloads_bytes = downloads.bytes,
        .downloads_files = downloads.entries,
        .active_version = payload.readActiveVersion(gpa, io, cfg) orelse manifest.ytdlp_version,
        .job_ttl_s = cfg.job_ttl_s,
        .tmp_ttl_s = cfg.tmp_ttl_s,
    };
}

const Options = struct {
    tmp: bool = false,
    engines: bool = false,
    downloads: bool = false,
    dry_run: bool = false,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, args: []const []const u8) !void {
    const sub = if (args.len > 0) args[0] else "info";

    if (std.mem.eql(u8, sub, "info")) {
        const info = try inspect(io, gpa, cfg);
        for (args[1..]) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                var out = std.Io.Writer.Allocating.init(gpa);
                defer out.deinit();
                try info.writeJson(&out.writer);
                try out.writer.writeByte('\n');
                try std.Io.File.stdout().writeStreamingAll(io, out.written());
                return;
            }
        }
        std.debug.print(
            \\cache       {s}  ({d:.1} MiB)
            \\  engines   {d:.1} MiB  (active yt-dlp {s})
            \\  temp      {d:.1} MiB in {d} files  (stale entries swept after {d}s)
            \\downloads   {s}  ({d:.1} MiB in {d} files)
            \\  retention {s}
            \\
        , .{
            info.cache_dir,
            mib(info.cache_bytes + info.tmp_bytes),
            mib(info.engines_bytes),
            info.active_version,
            mib(info.tmp_bytes),
            info.tmp_entries,
            info.tmp_ttl_s,
            info.downloads_dir,
            mib(info.downloads_bytes),
            info.downloads_files,
            if (info.job_ttl_s == 0) "keep forever (RECLIPZ_JOB_TTL=0)" else "jobs+files expire (RECLIPZ_JOB_TTL, seconds)",
        });
        return;
    }

    if (!std.mem.eql(u8, sub, "clean")) {
        std.debug.print("{s}", .{Usage});
        std.process.exit(2);
    }

    var opts: Options = .{};
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--tmp")) {
            opts.tmp = true;
        } else if (std.mem.eql(u8, a, "--engines")) {
            opts.engines = true;
        } else if (std.mem.eql(u8, a, "--downloads")) {
            opts.downloads = true;
        } else if (std.mem.eql(u8, a, "--all")) {
            opts.tmp = true;
            opts.engines = true;
            opts.downloads = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{Usage});
            return;
        } else {
            std.debug.print("reclipz: unknown option '{s}'\n\n{s}", .{ a, Usage });
            std.process.exit(2);
        }
    }
    if (!opts.tmp and !opts.engines and !opts.downloads) opts.tmp = true;

    var freed: u64 = 0;
    if (opts.tmp) freed += cleanTmp(io, gpa, cfg, opts.dry_run);
    if (opts.engines) freed += pruneEngines(io, gpa, cfg, opts.dry_run);
    if (opts.downloads) freed += cleanDownloads(io, gpa, cfg, opts.dry_run);

    if (opts.dry_run) {
        log.info("dry run: would free {d:.1} MiB", .{mib(freed)});
    } else {
        log.info("freed {d:.1} MiB", .{mib(freed)});
    }
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

/// Remove stale entries from `<cache>/tmp` (old `_MEI*` extraction dirs, leftover run-*.out/.err).
/// Age-based, so it never races with a running job.
pub fn cleanTmp(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, dry_run: bool) u64 {
    if (cfg.tmp_ttl_s == 0) return 0;
    const tmp_path = std.fmt.allocPrint(gpa, "{s}/tmp", .{cfg.cache_dir}) catch return 0;
    var dir = std.Io.Dir.cwd().openDir(io, tmp_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    const now = std.Io.Clock.Timestamp.now(io, .real).raw;
    const ttl_ns: i96 = @as(i96, @intCast(cfg.tmp_ttl_s)) * std.time.ns_per_s;

    var freed: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
        var mtime: i96 = st.mtime.nanoseconds;
        if (entry.kind == .directory) {
            // A leaked extraction dir keeps an old mtime on every file inside it; only treat it
            // as stale when *all* of its contents are stale (never race with a running job).
            const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_path, entry.name }) catch continue;
            mtime = newestMtime(io, gpa, full) orelse mtime;
        }
        if (now.nanoseconds - mtime < ttl_ns) continue;
        const size: u64 = if (entry.kind == .directory) dirSize(io, gpa, std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_path, entry.name }) catch continue).bytes else st.size;
        if (dry_run) {
            log.info("would remove {s}/{s} ({d} bytes)", .{ tmp_path, entry.name, size });
        } else {
            switch (entry.kind) {
                .directory => dir.deleteTree(io, entry.name) catch continue,
                else => dir.deleteFile(io, entry.name) catch continue,
            }
            log.debug("removed {s}/{s}", .{ tmp_path, entry.name });
        }
        freed += size;
    }
    return freed;
}

/// Keep only the active yt-dlp version (plus the embedded one) and the active ffmpeg payload.
pub fn pruneEngines(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, dry_run: bool) u64 {
    const active = payload.readActiveVersion(gpa, io, cfg) orelse manifest.ytdlp_version;
    var freed: u64 = 0;

    const yt_root = std.fmt.allocPrint(gpa, "{s}/bin/yt-dlp", .{cfg.cache_dir}) catch return 0;
    var yt = std.Io.Dir.cwd().openDir(io, yt_root, .{ .iterate = true }) catch return 0;
    {
        defer yt.close(io);
        var it = yt.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, active) or std.mem.eql(u8, entry.name, manifest.ytdlp_version)) continue;
            const size = dirSize(io, gpa, std.fmt.allocPrint(gpa, "{s}/{s}", .{ yt_root, entry.name }) catch continue).bytes;
            if (dry_run) {
                log.info("would remove yt-dlp {s} ({d} bytes)", .{ entry.name, size });
            } else {
                yt.deleteTree(io, entry.name) catch continue;
                log.info("removed yt-dlp {s}", .{entry.name});
            }
            freed += size;
        }
    }

    const ff_root = std.fmt.allocPrint(gpa, "{s}/bin/ffmpeg", .{cfg.cache_dir}) catch return freed;
    var ff = std.Io.Dir.cwd().openDir(io, ff_root, .{ .iterate = true }) catch return freed;
    defer ff.close(io);
    const keep = manifest.ffmpeg_sha256[0..@min(12, manifest.ffmpeg_sha256.len)];
    var it2 = ff.iterate();
    while (it2.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (manifest.has_ffmpeg and std.mem.eql(u8, entry.name, keep)) continue;
        const size = dirSize(io, gpa, std.fmt.allocPrint(gpa, "{s}/{s}", .{ ff_root, entry.name }) catch continue).bytes;
        if (dry_run) {
            log.info("would remove ffmpeg {s} ({d} bytes)", .{ entry.name, size });
        } else {
            ff.deleteTree(io, entry.name) catch continue;
            log.info("removed ffmpeg {s}", .{entry.name});
        }
        freed += size;
    }
    return freed;
}

fn isJobFile(name: []const u8) bool {
    if (name.len < 11) return false;
    for (name[0..10]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return name[10] == '.';
}

/// Delete finished download files (`<job_id>.<ext>`) and leftover `.tmp/<job_id>` dirs.
pub fn cleanDownloads(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, dry_run: bool) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, cfg.download_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var freed: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".tmp")) {
            const path = std.fmt.allocPrint(gpa, "{s}/.tmp", .{cfg.download_dir}) catch continue;
            const size = dirSize(io, gpa, path).bytes;
            if (dry_run) {
                log.info("would remove {s} ({d} bytes)", .{ path, size });
            } else {
                dir.deleteTree(io, ".tmp") catch continue;
            }
            freed += size;
            continue;
        }
        if (entry.kind != .file or !isJobFile(entry.name)) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        if (dry_run) {
            log.info("would remove {s}/{s} ({d} bytes)", .{ cfg.download_dir, entry.name, st.size });
        } else {
            dir.deleteFile(io, entry.name) catch continue;
        }
        freed += st.size;
    }
    return freed;
}

/// Startup maintenance: stale temp files, obsolete engine versions.
pub fn startupMaintenance(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config) void {
    const tmp_freed = cleanTmp(io, gpa, cfg, false);
    const eng_freed = pruneEngines(io, gpa, cfg, false);
    if (tmp_freed + eng_freed > 0) {
        log.info("cache maintenance freed {d:.1} MiB", .{mib(tmp_freed + eng_freed)});
    }
}

test "job file detection" {
    try std.testing.expect(isJobFile("a1b2c3d4e5.mp4"));
    try std.testing.expect(!isJobFile("a1b2c3d4e5"));
    try std.testing.expect(!isJobFile("a1b2c3d4e5f.mp4"));
    try std.testing.expect(!isJobFile("notajob.mp4"));
    try std.testing.expect(!isJobFile(".tmp"));
}
