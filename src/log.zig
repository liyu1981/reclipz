const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,

    pub fn parse(s: []const u8) Level {
        if (std.mem.eql(u8, s, "error") or std.mem.eql(u8, s, "err")) return .err;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "debug") or std.mem.eql(u8, s, "trace")) return .debug;
        return .info;
    }
};

var current: std.atomic.Value(u8) = .init(@backingInt(Level.info));

pub fn setLevel(level: Level) void {
    current.store(@backingInt(level), .release);
}

pub fn enabled(level: Level) bool {
    return @backingInt(level) <= current.load(.acquire);
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    var buf: [4096]u8 = undefined;
    const prefix = switch (level) {
        .err => "error: ",
        .warn => "warn:  ",
        .info => "info:  ",
        .debug => "debug: ",
    };
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    std.debug.print("reclipz {s}{s}\n", .{ prefix, msg });
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
