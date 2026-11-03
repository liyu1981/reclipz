const std = @import("std");

const index_html = @embedFile("index.html");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 8899);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("listening\n", .{});
    while (true) {
        var stream = try server.accept(io);
        handle(io, &stream) catch {};
        stream.close(io);
    }
}

fn handle(io: std.Io, stream: *std.Io.net.Stream) !void {
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    var w = stream.writer(io, &write_buf);
    var srv: std.http.Server = .init(&r.interface, &w.interface);
    var req = try srv.receiveHead();
    const target = req.head.target;
    if (std.mem.eql(u8, target, "/")) {
        try req.respond(index_html, .{ .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
    } else if (std.mem.eql(u8, target, "/api/ping")) {
        try req.respond("{\"ok\":true}", .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    } else {
        try req.respond("not found", .{ .status = .not_found });
    }
}
