//! Graceful shutdown: SIGINT/SIGTERM marks a flag; a watcher thread kills engine process groups
//! and exits, so no yt-dlp/ffmpeg children are left behind.

const std = @import("std");
const log = @import("log.zig");
const proc = @import("proc.zig");

var requested = std.atomic.Value(bool).init(false);

fn handler(_: std.posix.SIG) callconv(.c) void {
    requested.store(true, .release);
}

pub fn install() void {
    if (@import("builtin").os.tag == .windows) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

pub fn startWatcher(io: std.Io) void {
    const thread = std.Thread.spawn(.{}, watch, .{io}) catch return;
    thread.detach();
}

fn watch(io: std.Io) void {
    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
        if (requested.load(.acquire)) {
            log.info("shutdown requested; stopping engine processes", .{});
            proc.killAll();
            std.process.exit(0);
        }
    }
}
