const std = @import("std");

/// Create a directory and all its parents. Accepts absolute and relative paths.
pub fn ensureDir(io: std.Io, path: []const u8) !void {
    var sub = path;
    var dir: std.Io.Dir = undefined;
    if (std.mem.startsWith(u8, path, "/")) {
        sub = path[1..];
        dir = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    } else {
        dir = std.Io.Dir.cwd();
    }
    defer dir.close(io);
    if (sub.len == 0) return;
    try dir.createDirPath(io, sub);
}

pub fn exists(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        return true;
    } else |_| return false;
}

pub fn readFileAlloc(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit));
}

/// Write `bytes` to `path` atomically (tmp file + rename) and set the mode.
pub fn writeFileAtomic(io: std.Io, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: u32) !void {
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ path, std.mem.readInt(u32, &rnd, .little) });
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
        try f.setPermissions(io, .fromMode(@intCast(mode)));
    }
}

pub fn dirName(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

pub fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Search PATH for an executable. Returns an allocated absolute-ish path.
pub fn findInPath(io: std.Io, gpa: std.mem.Allocator, env: std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const path_env = env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {}
    }
    return null;
}

pub fn sha256Hex(bytes: []const u8, out: *[64]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

/// Percent-encode a filename for RFC 5987 `filename*=UTF-8''...`.
pub fn percentEncode(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out = std.ArrayList(u8).empty;
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hex[(c >> 4) & 0xf]);
            try out.append(gpa, hex[c & 0xf]);
        }
    }
    return out.toOwnedSlice(gpa);
}

test "percent encode" {
    const got = try percentEncode(std.testing.allocator, "a b.mp3");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a%20b.mp3", got);
}

test "sha256 hex" {
    var buf: [64]u8 = undefined;
    const hex = sha256Hex("abc", &buf);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex);
}
