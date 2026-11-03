//! Engine payload resolution.
//!
//! reclipz embeds the official yt-dlp release binary plus a static ffmpeg/ffprobe. On start they are
//! extracted once into a versioned cache directory (atomic, hash-verified) and executed from there.
//! `RECLIPZ_ENGINE=system` / `RECLIPZ_YTDLP` / `RECLIPZ_FFMPEG` bypass the embedded payloads.

const std = @import("std");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const manifest = @import("payload_manifest");

const blob_ytdlp = @embedFile("payload-ytdlp");
const blob_ffmpeg = @embedFile("payload-ffmpeg");
const blob_ffprobe = @embedFile("payload-ffprobe");

pub const Source = enum { embedded, system, override };

pub const Paths = struct {
    ytdlp: []const u8,
    ffmpeg: ?[]const u8 = null,
    ffprobe: ?[]const u8 = null,
    /// Directory containing ffmpeg/ffprobe, for yt-dlp's `--ffmpeg-location`.
    dir: ?[]const u8 = null,
    version: []const u8 = "unknown",
    source: Source = .embedded,
};

pub const Error = error{
    PayloadMissing,
    EngineNotFound,
    PayloadCorrupt,
    NotExecutable,
};

/// Resolve the engine binaries, extracting the embedded payloads on first use.
pub fn resolve(
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    env: std.process.Environ.Map,
) !Paths {
    // 1. Explicit override.
    if (cfg.ytdlp_override) |p| {
        return .{
            .ytdlp = p,
            .ffmpeg = cfg.ffmpeg_override,
            .dir = if (cfg.ffmpeg_override) |f| fsutil.dirName(f) else null,
            .version = "override",
            .source = .override,
        };
    }

    // 2. System engine.
    if (cfg.engine == .system) {
        const yt = (try fsutil.findInPath(io, gpa, env, "yt-dlp")) orelse
            return Error.EngineNotFound;
        const ff = cfg.ffmpeg_override orelse try fsutil.findInPath(io, gpa, env, "ffmpeg");
        const fp = try fsutil.findInPath(io, gpa, env, "ffprobe");
        return .{
            .ytdlp = yt,
            .ffmpeg = ff,
            .ffprobe = fp,
            .dir = if (ff) |f| fsutil.dirName(f) else null,
            .version = "system",
            .source = .system,
        };
    }

    // 3. Embedded payloads (auto falls back to the system engine).
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

    return extractEmbedded(gpa, io, cfg, env);
}

fn extractEmbedded(gpa: std.mem.Allocator, io: std.Io, cfg: *const config.Config, env: std.process.Environ.Map) !Paths {
    const dir = try std.fmt.allocPrint(gpa, "{s}/bin/{s}", .{ cfg.cache_dir, manifest.ytdlp_version });
    const marker = try std.fmt.allocPrint(gpa, "{s}/.complete", .{dir});
    const tmp_dir = try std.fmt.allocPrint(gpa, "{s}/tmp", .{cfg.cache_dir});
    fsutil.ensureDir(io, tmp_dir) catch {};

    if (!fsutil.exists(io, marker)) {
        log.info("extracting embedded engine payloads to {s}", .{dir});
        try fsutil.ensureDir(io, dir);

        try writeVerified(gpa, io, dir, "yt-dlp", blob_ytdlp, manifest.ytdlp_sha256);

        var have_ffmpeg = false;
        if (manifest.has_ffmpeg) {
            try writeVerified(gpa, io, dir, "ffmpeg", blob_ffmpeg, manifest.ffmpeg_sha256);
            try writeVerified(gpa, io, dir, "ffprobe", blob_ffprobe, manifest.ffprobe_sha256);
            have_ffmpeg = true;
        }
        {
            const text = try std.fmt.allocPrint(gpa, "reclipz payload {s}\n", .{manifest.ytdlp_version});
            try fsutil.writeFileAtomic(io, gpa, marker, text, 0o644);
        }
        if (!have_ffmpeg) log.warn("no embedded ffmpeg payload; merging/conversion needs a system ffmpeg", .{});
    }

    const yt = try std.fmt.allocPrint(gpa, "{s}/yt-dlp", .{dir});
    const ff = try std.fmt.allocPrint(gpa, "{s}/ffmpeg", .{dir});
    const fp = try std.fmt.allocPrint(gpa, "{s}/ffprobe", .{dir});

    var paths: Paths = .{
        .ytdlp = yt,
        .version = manifest.ytdlp_version,
        .source = .embedded,
    };
    if (manifest.has_ffmpeg and fsutil.exists(io, ff)) {
        paths.ffmpeg = ff;
        paths.ffprobe = fp;
        paths.dir = dir;
    } else {
        // Fall back to a host ffmpeg so merging/MP3 conversion still works.
        const ff_sys = cfg.ffmpeg_override orelse try fsutil.findInPath(io, gpa, env, "ffmpeg");
        if (ff_sys) |p| {
            paths.ffmpeg = p;
            paths.ffprobe = try fsutil.findInPath(io, gpa, env, "ffprobe");
            paths.dir = fsutil.dirName(p);
            log.warn("using system ffmpeg at {s} (no embedded ffmpeg payload)", .{p});
        }
    }
    return paths;
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
