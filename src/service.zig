//! `reclipz install-service` — install reclipz as a user-space systemd service.

const std = @import("std");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const payload = @import("payload.zig");
const proc = @import("proc.zig");

pub const service_name = "reclipz.service";

pub const Options = struct {
    dry_run: bool = false,
    force: bool = false,
    enable: bool = true,
    linger: bool = false,
    /// Emit the sandboxing directives. Disable on systems whose user manager cannot apply them
    /// (e.g. some containers: "Failed to drop capabilities").
    hardening: bool = true,
};

pub const UnitSpec = struct {
    exe: []const u8,
    home: []const u8,
    host: []const u8,
    port: u16,
    download_dir: []const u8,
    cache_dir: []const u8,
    log_level: []const u8,
    cookies: ?[]const u8 = null,
    proxy: ?[]const u8 = null,
    hardening: bool = true,
};

pub fn renderUnit(gpa: std.mem.Allocator, spec: UnitSpec) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    const w = &out.writer;

    try w.print(
        \\[Unit]
        \\Description=reclipz — ReClip media downloader (Zig host, embedded yt-dlp engine)
        \\Documentation=https://github.com/averygan/reclip
        \\After=network-online.target
        \\Wants=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} serve --host {s} --port {d} --download-dir {s} --cache-dir {s} --log {s}
        \\WorkingDirectory={s}
        \\Restart=on-failure
        \\RestartSec=3
        \\TimeoutStopSec=20
        \\Environment=RECLIPZ_NO_UPDATE=1
        \\
    , .{ spec.exe, spec.host, spec.port, spec.download_dir, spec.cache_dir, spec.log_level, spec.home });

    if (spec.cookies) |c| try w.print("Environment=RECLIPZ_COOKIES={s}\n", .{c});
    if (spec.proxy) |p| try w.print("Environment=RECLIPZ_PROXY={s}\n", .{p});

    if (spec.hardening) {
        try w.writeAll(
            \\
            \\# Hardening (the engine only needs network + its cache/download dirs).
            \\# ProtectKernelModules is deliberately omitted: it needs CAP_SYS_MODULE, which an
            \\# unprivileged user manager may not have (install with --no-hardening if a container
            \\# still refuses these).
            \\NoNewPrivileges=yes
            \\PrivateTmp=yes
            \\ProtectSystem=full
            \\ProtectControlGroups=yes
            \\ProtectKernelTunables=yes
            \\RestrictSUIDSGID=yes
            \\LockPersonality=yes
            \\
        );
    }
    try w.writeAll(
        \\[Install]
        \\WantedBy=default.target
        \\
    );
    return out.toOwnedSlice();
}

pub fn install(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    env: std.process.Environ.Map,
    opts: Options,
) !void {
    const exe = std.process.executablePathAlloc(io, gpa) catch |e| {
        log.err("cannot determine the reclipz executable path: {s}", .{@errorName(e)});
        return e;
    };
    const home = env.get("HOME") orelse {
        log.err("HOME is not set; cannot install a user service", .{});
        return error.NoHome;
    };
    const cwd = try std.process.currentPathAlloc(io, gpa);
    const unit_dir = try unitDir(gpa, env);
    const unit_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ unit_dir, service_name });

    const download_dir = try absolute(gpa, cwd, cfg.download_dir);
    const cache_dir = try absolute(gpa, cwd, cfg.cache_dir);

    const unit = try renderUnit(gpa, .{
        .exe = exe,
        .home = home,
        .host = cfg.host,
        .port = cfg.port,
        .download_dir = download_dir,
        .cache_dir = cache_dir,
        .log_level = @tagName(cfg.log_level),
        .cookies = cfg.cookies,
        .proxy = cfg.proxy,
        .hardening = opts.hardening,
    });

    if (opts.dry_run) {
        std.debug.print("{s}", .{unit});
        return;
    }

    if (std.mem.indexOfScalar(u8, exe, ' ') != null) {
        log.warn("the executable path contains a space; systemd ExecStart may misparse it", .{});
    }

    try fsutil.ensureDir(io, unit_dir);
    try fsutil.ensureDir(io, download_dir);
    try fsutil.ensureDir(io, cache_dir);

    if (fsutil.exists(io, unit_path) and !opts.force) {
        log.err("service unit already exists: {s} (use --force to overwrite)", .{unit_path});
        return error.AlreadyInstalled;
    }
    try fsutil.writeFileAtomic(io, gpa, unit_path, unit, 0o644);
    log.info("wrote {s}", .{unit_path});

    if (!try systemctl(io, gpa, &.{"daemon-reload"})) {
        log.err("`systemctl --user daemon-reload` failed", .{});
        log.err("make sure a user systemd instance is available (log in normally, or set XDG_RUNTIME_DIR)", .{});
        return error.SystemdUnavailable;
    }

    if (opts.enable) {
        if (try systemctl(io, gpa, &.{ "enable", "--now", service_name })) {
            if (waitActive(io, gpa, cfg)) {
                log.info("service enabled and active", .{});
            } else {
                log.err("the unit was installed and enabled, but did not become active", .{});
                log.err("inspect: journalctl --user -u {s} -n 20 --no-pager", .{service_name});
                log.err("if it failed with capabilities/sandbox errors, re-run with --no-hardening", .{});
                return error.ServiceNotActive;
            }
        } else {
            log.err("could not enable/start {s}", .{service_name});
            log.err("inspect with: systemctl --user status {s}", .{service_name});
            return error.ServiceNotActive;
        }
    } else {
        log.info("unit installed (not enabled); start it with: systemctl --user enable --now {s}", .{service_name});
    }

    if (opts.linger) enableLinger(io, env);

    std.debug.print(
        \\
        \\  reclipz service installed
        \\    unit:     {s}
        \\    web UI:   http://{s}:{d}
        \\    logs:     journalctl --user -u {s} -f
        \\    status:   systemctl --user status {s}
        \\
    , .{ unit_path, cfg.host, cfg.port, service_name, service_name });

    if (!opts.linger) {
        std.debug.print(
            \\  note: user services stop at logout unless lingering is enabled:
            \\    loginctl enable-linger $USER     (or re-run with --linger)
            \\
            \\
        , .{});
    }
}

pub fn uninstall(io: std.Io, gpa: std.mem.Allocator, env: std.process.Environ.Map) !void {
    _ = try systemctl(io, gpa, &.{ "disable", "--now", service_name });
    const unit_dir = try unitDir(gpa, env);
    const unit_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ unit_dir, service_name });
    if (fsutil.exists(io, unit_path)) {
        try std.Io.Dir.cwd().deleteFile(io, unit_path);
        log.info("removed {s}", .{unit_path});
    } else {
        log.warn("no unit at {s}", .{unit_path});
    }
    _ = try systemctl(io, gpa, &.{"daemon-reload"});
    log.info("service uninstalled (downloads and cache were left in place)", .{});
}

pub fn status(io: std.Io) !void {
    const argv = [_][]const u8{ "systemctl", "--user", "status", service_name, "--no-pager" };
    const code = proc.passthrough(io, &argv, null) catch |e| {
        log.err("could not run systemctl: {s}", .{@errorName(e)});
        return e;
    };
    if (code != 0) std.process.exit(code);
}

// ---------------------------------------------------------------------------------------------

fn waitActive(io: std.Io, gpa: std.mem.Allocator, cfg: *const config.Config) bool {
    const tmp = payload.tmpPath(gpa, io, cfg) catch "/tmp";
    var attempts: usize = 0;
    while (attempts < 12) : (attempts += 1) {
        const res = proc.run(io, gpa, &.{ "systemctl", "--user", "is-active", service_name }, .{
            .timeout_ms = 5000,
            .tmp_dir = tmp,
        }) catch return false;
        if (res.ok() and std.mem.indexOf(u8, res.stdout, "active") != null) return true;
        io.sleep(.fromMilliseconds(500), .awake) catch {};
    }
    return false;
}

fn systemctl(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, "systemctl");
    try argv.append(gpa, "--user");
    for (args) |a| try argv.append(gpa, a);
    const code = proc.passthrough(io, argv.items, null) catch |e| {
        log.debug("systemctl not available: {s}", .{@errorName(e)});
        return false;
    };
    return code == 0;
}

fn enableLinger(io: std.Io, env: std.process.Environ.Map) void {
    const user = env.get("USER") orelse env.get("LOGNAME") orelse {
        log.warn("--linger: USER/LOGNAME not set; run `loginctl enable-linger $USER` manually", .{});
        return;
    };
    const argv = [_][]const u8{ "loginctl", "enable-linger", user };
    const code = proc.passthrough(io, &argv, null) catch |e| {
        log.warn("could not run loginctl: {s}", .{@errorName(e)});
        return;
    };
    if (code == 0) {
        log.info("lingering enabled for {s} (service keeps running after logout)", .{user});
    } else {
        log.warn("loginctl enable-linger failed; run it manually with sudo if needed", .{});
    }
}

fn unitDir(gpa: std.mem.Allocator, env: std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| return std.fmt.allocPrint(gpa, "{s}/systemd/user", .{x});
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.config/systemd/user", .{home});
}

fn absolute(gpa: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return gpa.dupe(u8, path);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ cwd, path });
}

test "render unit" {
    const unit = try renderUnit(std.testing.allocator, .{
        .exe = "/opt/reclipz",
        .home = "/home/u",
        .host = "127.0.0.1",
        .port = 8899,
        .download_dir = "/home/u/Downloads/reclipz",
        .cache_dir = "/home/u/.cache/reclipz",
        .log_level = "info",
    });
    defer std.testing.allocator.free(unit);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=/opt/reclipz serve --host 127.0.0.1 --port 8899") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "WantedBy=default.target") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Restart=on-failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "NoNewPrivileges=yes") != null);
}
