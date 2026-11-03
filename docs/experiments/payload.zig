// Proof of the v2 payload architecture: embed the official yt-dlp release binary + ffmpeg/ffprobe,
// extract them once into a cache dir, then exec with pass-through arguments.
//
// Build (payloads are downloaded, not committed):
//   curl -L -o payload-ytdlp   https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux
//   ffmpeg/ffprobe: any static build, e.g. the minimal LGPL build from experiments/README.md §3
//   chmod +x payload-ytdlp payload-ffmpeg payload-ffprobe
//   zig build-exe payload.zig -O ReleaseSafe -femit-bin=reclipz-demo
//
// Measured on Linux x86_64: binary 51.2 MB; cold `--version` 874 ms, warm 830 ms
// (the remaining cost is PyInstaller re-extracting its own 41 MB archive on every run).
// Cache after first run: yt-dlp 40 MB + ffmpeg 3.0 MB + ffprobe 2.9 MB.
const std = @import("std");

const ytdlp = @embedFile("payload-ytdlp");
const ffmpeg = @embedFile("payload-ffmpeg");
const ffprobe = @embedFile("payload-ffprobe");

/// In production this comes from `build.zig` (read from the release asset's SHA2-256SUMS).
const ytdlp_version = "2026.10.26";

fn ensureDir(io: std.Io, path: []const u8) !void {
    var sub = path;
    var dir = std.Io.Dir.cwd();
    if (std.mem.startsWith(u8, path, "/")) {
        sub = path[1..];
        dir = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    }
    defer dir.close(io);
    try dir.createDirPath(io, sub);
}

/// Write `bytes` to `<dir>/<name>` atomically (tmp + rename) and make it executable.
/// Returns the path. Skips the write if the file already exists.
fn ensureExecutable(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, name: []const u8, bytes: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, name });

    if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
        f.close(io);
        return path;
    } else |_| {}

    const tmp = try std.fmt.allocPrint(gpa, "{s}/.tmp-{s}", .{ dir_path, name });
    {
        var f = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
        defer f.close(io);
        var buf: [1 << 16]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(bytes);
    }
    try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
    {
        var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        try f.setPermissions(io, .fromMode(0o755));
    }
    return path;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = init.minimal.args.vector;

    const cache_root = init.environ_map.get("XDG_CACHE_HOME") orelse
        std.fmt.allocPrint(gpa, "{s}/.cache", .{init.environ_map.get("HOME") orelse "/tmp"}) catch "/tmp";
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/reclipz-demo/{s}", .{ cache_root, ytdlp_version });
    try ensureDir(io, dir_path);

    const yt = try ensureExecutable(io, gpa, dir_path, "yt-dlp", ytdlp);
    _ = try ensureExecutable(io, gpa, dir_path, "ffmpeg", ffmpeg);
    _ = try ensureExecutable(io, gpa, dir_path, "ffprobe", ffprobe);

    var argv = std.ArrayList([]const u8).empty;
    try argv.append(gpa, yt);
    for (args[1..]) |a| try argv.append(gpa, std.mem.span(a));

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}
