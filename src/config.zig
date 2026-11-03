const std = @import("std");
const log = @import("log.zig");

pub const EngineMode = enum {
    embedded,
    system,
    auto,

    pub fn parse(s: []const u8) EngineMode {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "auto")) return .auto;
        return .embedded;
    }
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8899,
    download_dir: []const u8 = "downloads",
    cache_dir: []const u8 = "",
    max_concurrent: usize = 3,
    job_timeout_ms: u64 = 300_000,
    job_ttl_s: u64 = 24 * 3600,
    engine: EngineMode = .embedded,
    ytdlp_override: ?[]const u8 = null,
    ffmpeg_override: ?[]const u8 = null,
    cookies: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    extra_args: ?[]const u8 = null,
    log_level: log.Level = .info,
    /// Environment for engine child processes (TMPDIR, PATH); set by main.
    child_env: ?*std.process.Environ.Map = null,

    pub const Env = std.process.Environ.Map;

    pub fn load(gpa: std.mem.Allocator, env: Env) !Config {
        var cfg: Config = .{};

        if (env.get("HOST")) |v| {
            // `HOST=auto` (and friends) show up in some CI/shell environments; Flask would reject
            // them too. Normalize the values that obviously mean "bind locally".
            const norm = std.mem.trim(u8, v, " \t");
            if (std.mem.eql(u8, norm, "auto") or std.mem.eql(u8, norm, "localhost")) {
                cfg.host = "127.0.0.1";
            } else if (norm.len != 0) {
                cfg.host = try gpa.dupe(u8, norm);
            }
        }
        if (env.get("PORT")) |v| cfg.port = std.fmt.parseInt(u16, v, 10) catch cfg.port;
        if (env.get("RECLIPZ_DOWNLOAD_DIR")) |v| cfg.download_dir = try gpa.dupe(u8, v);
        if (env.get("RECLIPZ_MAX_CONCURRENT")) |v| cfg.max_concurrent = std.fmt.parseInt(usize, v, 10) catch cfg.max_concurrent;
        if (env.get("RECLIPZ_JOB_TIMEOUT")) |v| cfg.job_timeout_ms = 1000 * (std.fmt.parseInt(u64, v, 10) catch 300);
        if (env.get("RECLIPZ_JOB_TTL")) |v| cfg.job_ttl_s = std.fmt.parseInt(u64, v, 10) catch cfg.job_ttl_s;
        if (env.get("RECLIPZ_ENGINE")) |v| cfg.engine = EngineMode.parse(v);
        if (env.get("RECLIPZ_YTDLP")) |v| cfg.ytdlp_override = try gpa.dupe(u8, v);
        if (env.get("RECLIPZ_FFMPEG")) |v| cfg.ffmpeg_override = try gpa.dupe(u8, v);
        if (env.get("RECLIPZ_COOKIES")) |v| cfg.cookies = try gpa.dupe(u8, v);
        if (env.get("RECLIPZ_PROXY")) |v| cfg.proxy = try gpa.dupe(u8, v);
        if (env.get("RECLIPZ_YTDLP_ARGS")) |v| cfg.extra_args = try gpa.dupe(u8, v);
        if (env.get("RECLIPZ_LOG")) |v| cfg.log_level = log.Level.parse(v);

        cfg.cache_dir = try cacheDir(gpa, env);
        return cfg;
    }

    fn cacheDir(gpa: std.mem.Allocator, env: Env) ![]const u8 {
        if (env.get("RECLIPZ_CACHE_DIR")) |v| return gpa.dupe(u8, v);
        if (env.get("XDG_CACHE_HOME")) |v| return std.fmt.allocPrint(gpa, "{s}/reclipz", .{v});
        if (env.get("HOME")) |v| return std.fmt.allocPrint(gpa, "{s}/.cache/reclipz", .{v});
        return gpa.dupe(u8, "/tmp/reclipz");
    }
};

test "config defaults" {
    var env: Config.Env = .empty;
    defer env.deinit(std.testing.allocator);
    const cfg = try Config.load(std.testing.allocator, env);
    defer std.testing.allocator.free(cfg.cache_dir);
    try std.testing.expectEqual(@as(u16, 8899), cfg.port);
    try std.testing.expectEqual(EngineMode.embedded, cfg.engine);
}
