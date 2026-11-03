//! Engine payload resolution.
//!
//! reclipz embeds the official yt-dlp release binary plus a static ffmpeg/ffprobe. They are
//! extracted into a versioned cache directory (atomic, hash-verified) and executed from there.
//! `reclipz update` installs newer yt-dlp builds into the same cache and repoints `engine.json`,
//! so site fixes do not require rebuilding reclipz.
//!
//! Layout:
//!   <cache>/engine.json                          {"ytdlp_version":"2026.10.26"}
//!   <cache>/bin/yt-dlp/<version>/yt-dlp
//!   <cache>/bin/ffmpeg/<sha12>/{ffmpeg,ffprobe}
//!   <cache>/cacert.pem                           embedded roots for `reclipz update`
//!   <cache>/tmp/                                 TMPDIR for engine children

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const manifest = @import("payload_manifest");

const blob_ytdlp = @embedFile("payload-ytdlp");
const blob_ffmpeg = @embedFile("payload-ffmpeg");
const blob_ffprobe = @embedFile("payload-ffprobe");

pub const cacert_pem = @embedFile("assets/cacert.pem");

pub const Source = enum { embedded, system, override, updated };

pub const Paths = struct {
    ytdlp: []const u8,
    ffmpeg: ?[]const u8 = null,
    ffprobe: ?[]const u8 = null,
    /// Directory containing ffmpeg/ffprobe for yt-dlp's `--ffmpeg-location`.
    ffmpeg_dir: ?[]const u8 = null,
    version: []const u8 = "unknown",
    source: Source = .embedded,
};

pub const Error = error{
    PayloadMissing,
    EngineNotFound,
    PayloadCorrupt,
    NotExecutable,
};

pub const EngineState = struct {
    ytdlp_version: []const u8 = manifest.ytdlp_version,
};

/// Resolve the engine binaries, extracting the embedded payloads on first use.
pub fn resolve(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    env: std.process.Environ.Map,
) !Paths {
    if (cfg.ytdlp_override) |p| {
        return .{
            .ytdlp = p,
            .ffmpeg = cfg.ffmpeg_override,
            .ffmpeg_dir = if (cfg.ffmpeg_override) |f| fsutil.dirName(f) else null,
            .version = "override",
            .source = .override,
        };
    }

    if (cfg.engine == .system) {
        const yt = (try fsutil.findInPath(io, gpa, env, "yt-dlp")) orelse
            return Error.EngineNotFound;
        const ff = cfg.ffmpeg_override orelse try fsutil.findInPath(io, gpa, env, "ffmpeg");
        const fp = try fsutil.findInPath(io, gpa, env, "ffprobe");
        return .{
            .ytdlp = yt,
            .ffmpeg = ff,
            .ffprobe = fp,
            .ffmpeg_dir = if (ff) |f| fsutil.dirName(f) else null,
            .version = "system",
            .source = .system,
        };
    }

    if (!manifest.has_ytdlp) {
        if (cfg.engine == .auto) {
            if (try fsutil.findInPath(io, gpa, env, "yt-dlp")) |yt| {
                return .{ .ytdlp = yt, .version = "system", .source = .system };
            }
        }
        log.err("no embedded yt-dlp payload in this build and no system yt-dlp found", .{});
        log.err("build with -Dpayload-dir=<dir> containing yt-dlp, or set RECLIPZ_YTDLP=<path>", .{});
        return Error.PayloadMissing;
    }

    return resolveEmbedded(gpa, io, cfg, env);
}

fn resolveEmbedded(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    env: std.process.Environ.Map,
) !Paths {
    // ffmpeg payload is shared across yt-dlp versions, keyed by content hash.
    var ffmpeg: ?[]const u8 = null;
    var ffprobe: ?[]const u8 = null;
    var ffmpeg_dir: ?[]const u8 = null;
    if (manifest.has_ffmpeg) {
        const ff_dir = try std.fmt.allocPrint(gpa, "{s}/bin/ffmpeg/{s}", .{ cfg.cache_dir, manifest.ffmpeg_sha256[0..12] });
        const ff_path = try std.fmt.allocPrint(gpa, "{s}/ffmpeg", .{ff_dir});
        const fp_path = try std.fmt.allocPrint(gpa, "{s}/ffprobe", .{ff_dir});
        if (!fsutil.exists(io, ff_path)) {
            log.info("extracting embedded ffmpeg payload to {s}", .{ff_dir});
            try fsutil.ensureDir(io, ff_dir);
            try writeVerified(gpa, io, ff_dir, "ffmpeg", blob_ffmpeg, manifest.ffmpeg_sha256);
            try writeVerified(gpa, io, ff_dir, "ffprobe", blob_ffprobe, manifest.ffprobe_sha256);
        }
        ffmpeg = ff_path;
        ffprobe = fp_path;
        ffmpeg_dir = ff_dir;
    } else {
        const sys_ff = cfg.ffmpeg_override orelse try fsutil.findInPath(io, gpa, env, "ffmpeg");
        if (sys_ff) |p| {
            ffmpeg = p;
            ffprobe = try fsutil.findInPath(io, gpa, env, "ffprobe");
            ffmpeg_dir = fsutil.dirName(p);
            log.warn("using system ffmpeg at {s} (no embedded ffmpeg payload)", .{p});
        }
    }

    // Active yt-dlp version: engine.json wins (set by `reclipz update`), else the embedded one.
    const active = readActiveVersion(gpa, io, cfg) orelse manifest.ytdlp_version;
    var version = active;
    var source: Source = if (std.mem.eql(u8, active, manifest.ytdlp_version)) .embedded else .updated;

    const yt_dir = try std.fmt.allocPrint(gpa, "{s}/bin/yt-dlp/{s}", .{ cfg.cache_dir, version });
    const yt_path = try std.fmt.allocPrint(gpa, "{s}/yt-dlp", .{yt_dir});

    if (!fsutil.exists(io, yt_path)) {
        if (std.mem.eql(u8, version, manifest.ytdlp_version)) {
            log.info("extracting embedded yt-dlp payload to {s}", .{yt_dir});
            try fsutil.ensureDir(io, yt_dir);
            try writeVerified(gpa, io, yt_dir, "yt-dlp", blob_ytdlp, manifest.ytdlp_sha256);
        } else {
            // engine.json points at an update that vanished: fall back to the embedded build.
            log.warn("engine.json points at yt-dlp {s}, which is missing; using the embedded build", .{version});
            version = manifest.ytdlp_version;
            source = .embedded;
            const fallback_path = try std.fmt.allocPrint(gpa, "{s}/bin/yt-dlp/{s}/yt-dlp", .{ cfg.cache_dir, version });
            if (!fsutil.exists(io, fallback_path)) {
                const dir = try std.fmt.allocPrint(gpa, "{s}/bin/yt-dlp/{s}", .{ cfg.cache_dir, version });
                try fsutil.ensureDir(io, dir);
                try writeVerified(gpa, io, dir, "yt-dlp", blob_ytdlp, manifest.ytdlp_sha256);
            }
            try writeActiveVersion(gpa, io, cfg, version);
            return .{
                .ytdlp = fallback_path,
                .ffmpeg = ffmpeg,
                .ffprobe = ffprobe,
                .ffmpeg_dir = ffmpeg_dir,
                .version = version,
                .source = source,
            };
        }
    }

    if (!fsutil.exists(io, try std.fmt.allocPrint(gpa, "{s}/engine.json", .{cfg.cache_dir}))) {
        try writeActiveVersion(gpa, io, cfg, version);
    }

    return .{
        .ytdlp = yt_path,
        .ffmpeg = ffmpeg,
        .ffprobe = ffprobe,
        .ffmpeg_dir = ffmpeg_dir,
        .version = version,
        .source = source,
    };
}

fn writeVerified(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    bytes: []const u8,
    expected_hex: []const u8,
) !void {
    var buf: [64]u8 = undefined;
    const actual = fsutil.sha256Hex(bytes, &buf);
    if (expected_hex.len != 0 and !std.mem.eql(u8, actual, expected_hex)) {
        log.err("embedded payload {s} hash mismatch (build manifest corrupt)", .{name});
        return Error.PayloadCorrupt;
    }
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
    log.debug("writing payload {s} ({d} bytes)", .{ path, bytes.len });
    try fsutil.writeFileAtomic(io, gpa, path, bytes, 0o755);
}

// ---------------------------------------------------------------------------------------------
// engine.json
// ---------------------------------------------------------------------------------------------

fn statePath(gpa: std.mem.Allocator, cfg: *const config.Config) ![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/engine.json", .{cfg.cache_dir});
}

pub fn readActiveVersion(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config) ?[]const u8 {
    const path = statePath(gpa, cfg) catch return null;
    const data = fsutil.readFileAlloc(io, gpa, path, 4096) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return null;
    // The parsed tree is intentionally leaked into `gpa` for the process lifetime; the version
    // string is used for the lifetime of the server as well.
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    return switch (root.get("ytdlp_version") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn writeActiveVersion(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, version: []const u8) !void {
    try fsutil.ensureDir(io, cfg.cache_dir);
    const path = try statePath(gpa, cfg);
    const text = try std.fmt.allocPrint(gpa, "{{\"ytdlp_version\":\"{s}\"}}\n", .{version});
    try fsutil.writeFileAtomic(io, gpa, path, text, 0o644);
    log.info("active yt-dlp payload set to {s}", .{version});
}

/// Install a downloaded yt-dlp binary into the cache and make it active.
pub fn installYtdlp(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, version: []const u8, file_path: []const u8) !void {
    const dir = try std.fmt.allocPrint(gpa, "{s}/bin/yt-dlp/{s}", .{ cfg.cache_dir, version });
    try fsutil.ensureDir(io, dir);
    const dest = try std.fmt.allocPrint(gpa, "{s}/yt-dlp", .{dir});
    try std.Io.Dir.cwd().rename(file_path, std.Io.Dir.cwd(), dest, io);
    {
        var f = try std.Io.Dir.cwd().openFile(io, dest, .{ .mode = .read_write });
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o755));
    }
    try writeActiveVersion(gpa, io, cfg, version);
}

/// Remove yt-dlp versions other than `keep`, freeing disk space.
pub fn prune(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, keep: []const u8) void {
    const root = std.fmt.allocPrint(gpa, "{s}/bin/yt-dlp", .{cfg.cache_dir}) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, keep)) continue;
        if (std.mem.eql(u8, entry.name, manifest.ytdlp_version)) continue;
        log.debug("pruning old yt-dlp payload {s}", .{entry.name});
        dir.deleteTree(io, entry.name) catch |e| log.debug("prune failed: {s}", .{@errorName(e)});
    }
}

// ---------------------------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------------------------

/// The release asset name for this build target.
pub fn assetName() []const u8 {
    const musl = builtin.abi.isMusl();
    return switch (builtin.cpu.arch) {
        .x86_64 => if (musl) "yt-dlp_musllinux" else "yt-dlp_linux",
        .aarch64 => if (musl) "yt-dlp_musllinux_aarch64" else "yt-dlp_linux_aarch64",
        .arm => if (musl) "yt-dlp_linux_armv7l" else "yt-dlp_linux_armv7l",
        else => "yt-dlp_linux",
    };
}

/// Write the embedded CA bundle to the cache (once) and return its path.
pub fn cacertPath(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config) ![]const u8 {
    try fsutil.ensureDir(io, cfg.cache_dir);
    const path = try std.fmt.allocPrint(gpa, "{s}/cacert.pem", .{cfg.cache_dir});
    if (!fsutil.exists(io, path)) {
        try fsutil.writeFileAtomic(io, gpa, path, cacert_pem, 0o644);
    }
    return path;
}

/// TMPDIR used for engine child processes (also PyInstaller's extraction dir).
pub fn tmpPath(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config) ![]const u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/tmp", .{cfg.cache_dir});
    fsutil.ensureDir(io, path) catch {};
    return path;
}

test "asset name is non-empty" {
    try std.testing.expect(assetName().len > 0);
}
