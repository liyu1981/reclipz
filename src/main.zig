const std = @import("std");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const jobs = @import("jobs.zig");
const log = @import("log.zig");
const manifest = @import("payload_manifest");
const payload = @import("payload.zig");
const proc = @import("proc.zig");
const server = @import("server.zig");
const service = @import("service.zig");
const shutdown = @import("shutdown.zig");
const update = @import("update.zig");
const version_mod = @import("version.zig");

const version_string = version_mod.string;

const usage =
    \\reclipz — ReClip, a self-hosted video/audio downloader (Zig host, embedded yt-dlp engine)
    \\
    \\Usage:
    \\  reclipz [serve] [options]      Start the web UI (default command)
    \\  reclipz yt-dlp <args...>       Run the embedded yt-dlp
    \\  reclipz ffmpeg <args...>       Run the embedded ffmpeg
    \\  reclipz ffprobe <args...>      Run the embedded ffprobe
    \\  reclipz update [--check]       Update the embedded yt-dlp payload (no rebuild)
    \\  reclipz install-service        Install as a user-space systemd service
    \\  reclipz uninstall-service      Remove the systemd service
    \\  reclipz service-status         Show the systemd service status
    \\  reclipz which [--json]         Show resolved engine paths and versions
    \\  reclipz selftest               Check that the embedded engine runs
    \\  reclipz version                Show versions
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
    \\install-service options: --dry-run, --force, --no-enable, --linger
    \\update options:          --check, --version <tag>, --force, --gpg, --allow-unverified
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
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        return runVersion(io, sa, env, &cfg);
    }
    if (std.mem.eql(u8, cmd, "update")) return runUpdate(io, sa, env, &cfg, rest);
    if (std.mem.eql(u8, cmd, "install-service")) return runInstallService(io, sa, gpa, env, &cfg, rest);
    if (std.mem.eql(u8, cmd, "uninstall-service")) return service.uninstall(io, sa, env.*);
    if (std.mem.eql(u8, cmd, "service-status")) return service.status(io);
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
        const name = @errorName(e);
        log.err("engine unavailable: {s}", .{name});
        // Compare by name: with `-Dpayload-dir=none` the inferred error set does not contain
        // AccessDenied, so `switch (e) { error.AccessDenied => ... }` would not compile.
        if (std.mem.eql(u8, name, "AccessDenied")) {
            log.err("hint: the cache dir '{s}' is not writable by this user; fix its ownership or set RECLIPZ_CACHE_DIR", .{cfg.cache_dir});
        } else {
            log.err("hint: run `reclipz update`, `tools/fetch_payloads.sh`, or set RECLIPZ_YTDLP", .{});
        }
        std.process.exit(1);
    };
    var mutable_paths = paths;
    cfg.child_env = try buildChildEnv(runtime, io, env.*, cfg, &mutable_paths);
    try verifyEngine(io, runtime, env.*, cfg, &mutable_paths);

    var registry = try jobs.Registry.init(runtime, io, cfg, &mutable_paths);

    shutdown.install();
    shutdown.startWatcher(io);

    var app: server.App = .{
        .gpa = runtime,
        .io = io,
        .cfg = cfg,
        .paths = &mutable_paths,
        .registry = &registry,
    };
    try server.serve(&app);
}

/// Fail fast with an actionable message when the embedded engine cannot actually execute
/// (the classic case: the musl release on a glibc host, or a noexec cache dir).
fn verifyEngine(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: std.process.Environ.Map,
    cfg: *const config.Config,
    paths: *const payload.Paths,
) !void {
    if (env.get("RECLIPZ_SKIP_ENGINE_CHECK")) |v| {
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) return;
    }
    const tmp = try payload.tmpPath(gpa, io, cfg);
    const res = proc.run(io, gpa, &.{ paths.ytdlp, "--version" }, .{
        .timeout_ms = 60_000,
        .tmp_dir = tmp,
        .env_map = cfg.child_env,
    }) catch |e| {
        const name = @errorName(e);
        log.err("the embedded engine cannot be started: {s}", .{name});
        engineHint(name, cfg);
        std.process.exit(1);
    };
    if (!res.ok()) {
        log.err("the embedded engine failed its startup check: {s}", .{res.lastStderrLine()});
        engineHint(@errorName(error.EngineFailed), cfg);
        std.process.exit(1);
    }
    log.info("engine ok: yt-dlp {s}", .{std.mem.trim(u8, res.stdout, " \t\r\n")});
}

fn engineHint(err_name: []const u8, cfg: *const config.Config) void {
    const builtin = @import("builtin");
    if (std.mem.eql(u8, err_name, "FileNotFound")) {
        if (builtin.abi.isMusl()) {
            log.err("this is the MUSL build: its engine needs /lib/ld-musl-{s}.so.1, which this host does not provide", .{@tagName(builtin.cpu.arch)});
            log.err("on glibc systems (Ubuntu/Debian/Fedora/Arch/...) use the -gnu release instead;", .{});
            log.err("the -musl release is for Alpine and other musl distributions", .{});
        } else {
            log.err("the engine binary is missing or its ELF interpreter is unavailable", .{});
            log.err("try `reclipz selftest`, or set RECLIPZ_ENGINE=system / RECLIPZ_YTDLP=<path>", .{});
        }
    } else if (std.mem.eql(u8, err_name, "AccessDenied")) {
        log.err("the cache dir '{s}' is not executable (noexec mount or file permissions)", .{cfg.cache_dir});
        log.err("set RECLIPZ_CACHE_DIR to a directory on an exec-capable filesystem", .{});
    } else {
        log.err("try `reclipz selftest` for details, or set RECLIPZ_ENGINE=system / RECLIPZ_YTDLP=<path>", .{});
    }
}

/// The engine gets its own environment: TMPDIR in our cache (PyInstaller unpacks there) and a PATH
/// that contains the embedded ffmpeg, so yt-dlp never depends on the host installation.
fn buildChildEnv(
    gpa: std.mem.Allocator,
    io: std.Io,
    parent: std.process.Environ.Map,
    cfg: *const config.Config,
    paths: *const payload.Paths,
) !*std.process.Environ.Map {
    const map = try gpa.create(std.process.Environ.Map);
    map.* = try parent.clone(gpa);
    const tmp = try payload.tmpPath(gpa, io, cfg);
    try map.put("TMPDIR", tmp);
    try map.put("TMP", tmp);
    if (paths.ffmpeg_dir) |dir| {
        const cur = map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        try map.put("PATH", try std.fmt.allocPrint(gpa, "{s}:{s}", .{ dir, cur }));
    }
    return map;
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
            cfg.host = try gpa.dupe(u8, config.normalizeHost(args[i]) orelse return "invalid --host");
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
    scratch: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
    rest: []const []const u8,
    which: Which,
) !void {
    log.setLevel(cfg.log_level);
    const paths = payload.resolve(scratch, io, cfg, env.*) catch |e| {
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
    try argv.append(scratch, bin);
    for (rest) |a| try argv.append(scratch, a);

    const child_env = try buildChildEnv(scratch, io, env.*, cfg, &paths);
    const code = proc.passthrough(io, argv.items, child_env) catch |e| {
        const name = @errorName(e);
        log.err("cannot execute {s}: {s}", .{ bin, name });
        engineHint(name, cfg);
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn runWhich(
    io: std.Io,
    scratch: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
    rest: []const []const u8,
) !void {
    const paths = payload.resolve(scratch, io, cfg, env.*) catch |e| {
        std.debug.print("engine unavailable: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };

    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--json")) {
        const builtin = @import("builtin");
        const WhichJson = struct {
            reclipz: []const u8,
            target: []const u8,
            arch: []const u8,
            abi: []const u8,
            ytdlp: []const u8,
            ytdlp_version: []const u8,
            ytdlp_source: []const u8,
            ffmpeg: ?[]const u8,
            ffprobe: ?[]const u8,
            cache: []const u8,
            downloads: []const u8,
        };
        var out = std.Io.Writer.Allocating.init(scratch);
        defer out.deinit();
        try std.json.Stringify.value(WhichJson{
            .reclipz = version_string,
            .target = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .abi = @tagName(builtin.abi),
            .ytdlp = paths.ytdlp,
            .ytdlp_version = paths.version,
            .ytdlp_source = @tagName(paths.source),
            .ffmpeg = paths.ffmpeg,
            .ffprobe = paths.ffprobe,
            .cache = cfg.cache_dir,
            .downloads = cfg.download_dir,
        }, .{}, &out.writer);
        try out.writer.writeByte('\n');
        // Machine-readable output goes to stdout (the rest of the CLI logs to stderr).
        try std.Io.File.stdout().writeStreamingAll(io, out.written());
        return;
    }

    std.debug.print("reclipz    {s}\n", .{version_string});
    std.debug.print("target     {s}-{s}\n", .{ @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").abi) });
    std.debug.print("yt-dlp     {s}\n", .{paths.ytdlp});
    std.debug.print("  version  {s} ({s})\n", .{ paths.version, @tagName(paths.source) });
    if (paths.ffmpeg) |f| std.debug.print("ffmpeg     {s}\n", .{f});
    if (paths.ffprobe) |f| std.debug.print("ffprobe    {s}\n", .{f});
    std.debug.print("cache      {s}\n", .{cfg.cache_dir});
    std.debug.print("downloads  {s}\n", .{cfg.download_dir});
}

fn runVersion(
    io: std.Io,
    scratch: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
) !void {
    std.debug.print("reclipz {s}\n", .{version_string});
    if (manifest.has_ytdlp) {
        std.debug.print("embedded yt-dlp {s}\n", .{manifest.ytdlp_version});
    } else {
        std.debug.print("embedded yt-dlp: none\n", .{});
    }
    const paths = payload.resolve(scratch, io, cfg, env.*) catch return;
    const argv = [_][]const u8{ paths.ytdlp, "--version" };
    if (engineRun(io, scratch, cfg, &argv)) |res| {
        if (res.ok()) std.debug.print("engine yt-dlp {s}\n", .{std.mem.trim(u8, res.stdout, " \t\r\n")});
    } else |_| {}
}

fn engineRun(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config, argv: []const []const u8) !proc.Result {
    const dir = try payload.tmpPath(gpa, io, cfg);
    return proc.run(io, gpa, argv, .{ .timeout_ms = 30_000, .tmp_dir = dir, .env_map = cfg.child_env });
}

fn runSelftest(
    io: std.Io,
    scratch: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
) !void {
    log.setLevel(.info);
    std.debug.print("reclipz selftest\n", .{});
    std.debug.print("  host: {s}  port: {d}\n", .{ cfg.host, cfg.port });
    std.debug.print("  cache dir: {s}\n", .{cfg.cache_dir});

    const paths = payload.resolve(scratch, io, cfg, env.*) catch |e| {
        std.debug.print("  [FAIL] engine resolve: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.debug.print("  [ ok ] engine resolved: {s} ({s} {s})\n", .{ paths.ytdlp, paths.version, @tagName(paths.source) });
    cfg.child_env = try buildChildEnv(scratch, io, env.*, cfg, &paths);

    const yt = engineRun(io, scratch, cfg, &.{ paths.ytdlp, "--version" }) catch |e| {
        std.debug.print("  [FAIL] yt-dlp did not run: {s}\n", .{@errorName(e)});
        engineHint(@errorName(e), cfg);
        std.process.exit(1);
    };
    if (yt.ok()) {
        std.debug.print("  [ ok ] yt-dlp {s}\n", .{std.mem.trim(u8, yt.stdout, " \t\r\n")});
    } else {
        std.debug.print("  [FAIL] yt-dlp exit {d}: {s}\n", .{ yt.exitCode(), yt.lastStderrLine() });
    }

    if (paths.ffmpeg) |ff| {
        const r = engineRun(io, scratch, cfg, &.{ ff, "-version" }) catch |e| {
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

fn runUpdate(
    io: std.Io,
    scratch: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
    rest: []const []const u8,
) !void {
    var opts: update.Options = .{};
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--check")) {
            opts.check_only = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            i += 1;
            if (i >= rest.len) {
                std.debug.print("reclipz: missing value for --version\n", .{});
                std.process.exit(2);
            }
            opts.version = rest[i];
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--gpg")) {
            opts.gpg = true;
        } else if (std.mem.eql(u8, a, "--allow-unverified")) {
            opts.allow_unverified = true;
        } else if (isHelp(a)) {
            std.debug.print("usage: reclipz update [--check] [--version <tag>] [--force] [--gpg] [--allow-unverified]\n", .{});
            return;
        } else {
            std.debug.print("reclipz: unknown option '{s}'\n", .{a});
            std.process.exit(2);
        }
    }
    log.setLevel(cfg.log_level);
    _ = env;
    update.run(io, scratch, cfg, opts) catch |e| {
        log.err("update failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
}

fn runInstallService(
    io: std.Io,
    scratch: std.mem.Allocator,
    runtime: std.mem.Allocator,
    env: *std.process.Environ.Map,
    cfg: *config.Config,
    rest: []const []const u8,
) !void {
    _ = runtime;
    var svc: service.Options = .{};
    var serve_args: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            svc.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            svc.force = true;
        } else if (std.mem.eql(u8, a, "--no-enable")) {
            svc.enable = false;
        } else if (std.mem.eql(u8, a, "--linger")) {
            svc.linger = true;
        } else if (std.mem.eql(u8, a, "--no-hardening")) {
            svc.hardening = false;
        } else if (isHelp(a)) {
            std.debug.print("usage: reclipz install-service [--dry-run] [--force] [--no-enable] [--linger] [--no-hardening] [serve options]\n", .{});
            return;
        } else {
            try serve_args.append(scratch, a);
        }
    }

    if (try parseServeFlags(scratch, serve_args.items, cfg)) |msg| {
        std.debug.print("reclipz: {s}\n", .{msg});
        std.process.exit(2);
    }

    service.install(io, scratch, cfg, env.*, svc) catch |e| {
        log.err("install-service failed: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
}
