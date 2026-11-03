const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();

    const url = std.mem.span(init.minimal.args.vector[1]);
    std.debug.print("fetching {s}\n", .{url});
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &out.writer });
    std.debug.print("status={d} bytes={d}\n", .{ @backingInt(res.status), out.written().len });
}
