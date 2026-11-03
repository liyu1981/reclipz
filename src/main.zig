const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");
const fsutil = @import("fsutil.zig");
const jobs = @import("jobs.zig");
const log = @import("log.zig");
const manifest = @import("payload_manifest");
const payload = @import("payload.zig");
const proc = @import("proc.zig");
const server = @import("server.zig");

const version_string = "0.1.0";

const usage =
    \\reclipz — ReClip, a self-hosted video/audio downloader (Zig host, embedded yt-dlp engine)
    \\
    \\Usage:
    \\  reclipz [serve] [options]     Start the web UI (default command)
    \\  reclipz yt-dlp <args...>      Run the embedded yt-dlp
    \\  reclipz ffmpeg <args...>      Run the embedded ffmpeg
    \\  reclipz ffprobe <args...>     Run the embedded ffprobe
    \\  reclipz which [--json]        Show resolved engine paths and versions
    \\  reclipz selftest              Check that the embedded engine runs
    \\  reclipz version               Show versions
    \\
    \\Serve options:
    \\  --port <n>          Port to listen on            (env PORT, default 8899)
    \\  --host <addr>       Address to bind              (env HOST, default 127.0.0.1)
    \\  --download-dir <p>  Where downloads are saved    (env RECLIPZ_DOWNLOAD_DIR, default ./downloads)
    \\  --cache-dir <p>     Payload/cache directory      (env RECLIPZ_CACHE_DIR)
    \\  --cookies <file>    Netscape cookies.txt         (env RECLIPZ_COOKIES)
    \\  --proxy <url>       Proxy for the engine         (env RECLIPZ_PROXY)
    \\  --engine <mode>     embedded | system | auto     (env RECLIPZ_ENGINE, default embedded)
    \\  --log <level>       error | warn | info | debug  (env RECLIPZ_LOG, default info)
    \\  -h, --help          Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;

    // Startup allocations (args/config/payload paths) live for the whole process.
    var startup_arena = std.heap.ArenaAllocator.init(gpa);
    defer startup_arena.deinit();
    const sa = startup_arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    for (init.minimal.args.vector[1..]) |raw| try argv.append(sa, std.mem.span(raw));
    const args = argv.items;

    var cfg = try config.Config.load(sa, env.*);

    if (args.len == 0) return runServe(io, sa, gpa, env, &cfg, args);

    const cmd = args[0];
    const rest = args[1..];

    if (isHelp(cmd)) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (std.mem.eql(u8, cmd, "serve")) return runServe(io, sa, gpa, env, &cfg, rest);
    if (std.mem.eql(u8, cmd, "yt-dlp") or std.mem.eql(u8, cmd, "ytdlp")) {
        return runPassthrough(io, sa, env, &cfg, rest, .ytdlp);
    }
    if (std.mem.eql(u8, cmd, "ffmpeg")) return runPassthrough(io, sa, env, &cfg, rest, .ffmpeg);
    if (std.mem.eql(u8, cmd, "ffprobe")) return runPassthrough(io, sa, env, &cfg, rest, .ffprobe);
    if (std.mem.eql(u8, cmd, "which")) return runWhich(io, sa, env, &cfg, rest);
    if (std.mem.eql(u8, cmd, "selftest")) return runSelftest(io, sa, env, &cfg);
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) return runVersion(io, sa, env, &cfg);
    if (std.mem.eql(u8, cmd, "update")) {
        std.debug.print("reclipz: `update` is not implemented in this build yet (see docs/PLAN.md M2)\n", .{});
        std.process.exit(2);
    }
    if (std.mem.startsWith(u8, cmd, "-")) return runServe(io, sa, gpa, env, &cfg, args);

    std.debug.print("reclipz: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    std.process.exit(2);
}

fn isHelp(s: []const u8) bool {
    return std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "help");
}

fn runServe(
    io: std.Io,
    scratch: std.mem.Allocator,
    runtime: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
    args: []const []const u8,
) !void {
    if (try parseServeFlags(scratch, args, cfg)) |msg| {
        std.debug.print("reclipz: {s}\n", .{msg});
        std.process.exit(2);
    }

    log.setLevel(cfg.log_level);
    printBanner(cfg);

    fsutil.ensureDir(io, cfg.download_dir) catch |e| {
        log.err("cannot create download dir '{s}': {s}", .{ cfg.download_dir, @errorName(e) });
        std.process.exit(1);
    };

    const paths = payload.resolve(scratch, io, cfg, env.*) catch |e| {
        log.err("engine unavailable: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    var mutable_paths = paths;
    var registry = try jobs.Registry.init(runtime, io, cfg, &mutable_paths);

    var app: server.App = .{
        .gpa = runtime,
        .io = io,
        .cfg = cfg,
        .paths = &mutable_paths,
        .registry = &registry,
    };
    try server.serve(&app);
}

fn parseServeFlags(gpa: std.mem.Allocator, args: []const []const u8, cfg: *config.Config) !?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--port")) {
            i += 1;
            if (i >= args.len) return "missing value for --port";
            cfg.port = std.fmt.parseInt(u16, args[i], 10) catch return "invalid --port";
        } else if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i >= args.len) return "missing value for --host";
            cfg.host = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--download-dir")) {
            i += 1;
            if (i >= args.len) return "missing value for --download-dir";
            cfg.download_dir = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--cache-dir")) {
            i += 1;
            if (i >= args.len) return "missing value for --cache-dir";
            cfg.cache_dir = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--cookies")) {
            i += 1;
            if (i >= args.len) return "missing value for --cookies";
            cfg.cookies = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--proxy")) {
            i += 1;
            if (i >= args.len) return "missing value for --proxy";
            cfg.proxy = try gpa.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, a, "--engine")) {
            i += 1;
            if (i >= args.len) return "missing value for --engine";
            cfg.engine = config.EngineMode.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--log")) {
            i += 1;
            if (i >= args.len) return "missing value for --log";
            cfg.log_level = log.Level.parse(args[i]);
        } else {
            return try std.fmt.allocPrint(gpa, "unknown option '{s}'", .{a});
        }
    }
    return null;
}

fn printBanner(cfg: *const config.Config) void {
    std.debug.print(
        \\
        \\  reclipz {s} — ReClip (Zig)
        \\  http://{s}:{d}
        \\
        \\
    , .{ version_string, cfg.host, cfg.port });
}

const Which = enum { ytdlp, ffmpeg, ffprobe };

fn runPassthrough(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
    rest: []const []const u8,
    which: Which,
) !void {
    log.setLevel(cfg.log_level);
    const paths = payload.resolve(gpa, io, cfg, env.*) catch |e| {
        log.err("engine unavailable: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    const bin = switch (which) {
        .ytdlp => paths.ytdlp,
        .ffmpeg => paths.ffmpeg orelse {
            std.debug.print("reclipz: no ffmpeg available (build with an ffmpeg payload or set RECLIPZ_FFMPEG)\n", .{});
            std.process.exit(1);
        },
        .ffprobe => paths.ffprobe orelse {
            std.debug.print("reclipz: no ffprobe available (build with an ffmpeg payload or set RECLIPZ_FFMPEG)\n", .{});
            std.process.exit(1);
        },
    };

    // Everything after the subcommand belongs to the engine, verbatim.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin);
    for (rest) |a| try argv.append(gpa, a);
    const code = try proc.passthrough(io, argv.items);
    std.process.exit(code);
}

fn runWhich(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map, cfg: *config.Config, rest: []const []const u8) !void {
    _ = rest;
    const paths = payload.resolve(gpa, io, cfg, env.*) catch |e| {
        std.debug.print("engine unavailable: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("reclipz  {s}\n", .{version_string});
    std.debug.print("target   {s}-{s}\n", .{ @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    std.debug.print("yt-dlp   {s} ({s}, {s})\n", .{ paths.ytdlp, paths.version, @tagName(paths.source) });
    if (paths.ffmpeg) |f| std.debug.print("ffmpeg   {s}\n", .{f});
    if (paths.ffprobe) |f| std.debug.print("ffprobe  {s}\n", .{f});
    std.debug.print("cache    {s}\n", .{cfg.cache_dir});
    std.debug.print("download {s}\n", .{cfg.download_dir});
}

fn runVersion(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map, cfg: *config.Config) !void {
    std.debug.print("reclipz {s}\n", .{version_string});
    if (manifest.has_ytdlp) {
        std.debug.print("embedded yt-dlp {s}\n", .{manifest.ytdlp_version});
    } else {
        std.debug.print("embedded yt-dlp: none\n", .{});
    }
    const paths = payload.resolve(gpa, io, cfg, env.*) catch return;
    const argv = [_][]const u8{ paths.ytdlp, "--version" };
    if (engine.run(io, gpa, cfg, &argv)) |res| {
        if (res.ok()) std.debug.print("engine yt-dlp {s}\n", .{std.mem.trim(u8, res.stdout, " \t\r\n")});
    } else |_| {}
}

fn runSelftest(io: std.Io, gpa: std.mem.Allocator, env: *std.process.Environ.Map, cfg: *config.Config) !void {
    log.setLevel(.info);
    std.debug.print("reclipz selftest\n", .{});
    std.debug.print("  host: {s}  port: {d}\n", .{ cfg.host, cfg.port });
    std.debug.print("  cache dir: {s}\n", .{cfg.cache_dir});

    const paths = payload.resolve(gpa, io, cfg, env.*) catch |e| {
        std.debug.print("  [FAIL] engine resolve: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("  [ ok ] engine resolved: {s} ({s})\n", .{ paths.ytdlp, @tagName(paths.source) });

    const tmp = try std.fmt.allocPrint(gpa, "{s}/tmp", .{cfg.cache_dir});
    fsutil.ensureDir(io, tmp) catch {};

    const yt = proc.run(io, gpa, &.{ paths.ytdlp, "--version" }, .{ .timeout_ms = 30_000, .tmp_dir = tmp }) catch |e| {
        std.debug.print("  [FAIL] yt-dlp did not run: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    if (yt.ok()) {
        std.debug.print("  [ ok ] yt-dlp {s}\n", .{std.mem.trim(u8, yt.stdout, " \t\r\n")});
    } else {
        std.debug.print("  [FAIL] yt-dlp exit {d}: {s}\n", .{ yt.exitCode(), yt.lastStderrLine() });
    }

    if (paths.ffmpeg) |ff| {
        const r = proc.run(io, gpa, &.{ ff, "-version" }, .{ .timeout_ms = 30_000, .tmp_dir = tmp }) catch |e| {
            std.debug.print("  [FAIL] ffmpeg did not run: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        if (r.ok()) {
            var it = std.mem.splitScalar(u8, r.stdout, '\n');
            std.debug.print("  [ ok ] {s}\n", .{it.first()});
        } else {
            std.debug.print("  [FAIL] ffmpeg exit {d}\n", .{r.exitCode()});
        }
    } else {
        std.debug.print("  [warn] no ffmpeg available (merging/MP3 conversion will fail)\n", .{});
    }
    std.debug.print("done\n", .{});
}
