//! yt-dlp invocation and JSON mapping.
//!
//! The command lines intentionally mirror reclip's `app.py` (see docs/PLAN.md §5.1), with a few
//! behaviour-preserving additions (`--ffmpeg-location`, `--cache-dir`, ...).

const std = @import("std");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const payload = @import("payload.zig");
const proc = @import("proc.zig");

pub const progress_template = "download:reclipz|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(progress.fragment_index)s|%(progress.fragment_count)s";

pub const Progress = struct {
    downloaded_bytes: ?u64 = null,
    total_bytes: ?u64 = null,
    speed: ?f64 = null,
    eta: ?u64 = null,
    fragment_index: ?u64 = null,
    fragment_count: ?u64 = null,

    pub fn percent(self: Progress) ?f64 {
        const total = self.total_bytes orelse return null;
        if (total == 0) return null;
        const done: f64 = @floatFromInt(self.downloaded_bytes orelse 0);
        return done / @as(f64, @floatFromInt(total)) * 100.0;
    }

    pub fn isEmpty(self: Progress) bool {
        return self.downloaded_bytes == null and self.total_bytes == null and self.speed == null;
    }
};

fn num(v: []const u8) ?u64 {
    if (v.len == 0 or std.mem.eql(u8, v, "NA") or std.mem.eql(u8, v, "None")) return null;
    const f = std.fmt.parseFloat(f64, v) catch return null;
    if (f < 0) return null;
    return @intFromFloat(f);
}

fn fnum(v: []const u8) ?f64 {
    if (v.len == 0 or std.mem.eql(u8, v, "NA") or std.mem.eql(u8, v, "None")) return null;
    const f = std.fmt.parseFloat(f64, v) catch return null;
    if (f < 0) return null;
    return f;
}

pub fn parseProgressLine(line: []const u8) ?Progress {
    if (!std.mem.startsWith(u8, line, "reclipz|")) return null;
    var it = std.mem.splitScalar(u8, line, '|');
    _ = it.next(); // prefix
    const downloaded = it.next() orelse return null;
    const total = it.next() orelse "NA";
    const total_est = it.next() orelse "NA";
    const speed = it.next() orelse "NA";
    const eta = it.next() orelse "NA";
    const frag_i = it.next() orelse "NA";
    const frag_n = it.next() orelse "NA";
    return .{
        .downloaded_bytes = num(downloaded),
        .total_bytes = num(total) orelse num(total_est),
        .speed = fnum(speed),
        .eta = num(eta),
        .fragment_index = num(frag_i),
        .fragment_count = num(frag_n),
    };
}

pub const FormatChoice = enum {
    video,
    audio,

    pub fn parse(s: []const u8) FormatChoice {
        return if (std.mem.eql(u8, s, "audio")) .audio else .video;
    }
};

pub const Format = struct {
    id: []const u8,
    label: []const u8,
    height: u32,
};

pub const Info = struct {
    title: []const u8 = "",
    thumbnail: []const u8 = "",
    duration: ?f64 = null,
    uploader: []const u8 = "",
    formats: []const Format = &.{},
};

pub const InfoResponse = struct {
    title: []const u8,
    thumbnail: []const u8,
    duration: ?f64,
    uploader: []const u8,
    formats: []const Format,
};

pub const PlaylistResponse = struct {
    urls: []const []const u8,
};

// ---------------------------------------------------------------------------------------------
// argv builders
// ---------------------------------------------------------------------------------------------

const ArgList = std.ArrayList([]const u8);

fn addCommon(gpa: std.mem.Allocator, args: *ArgList, cfg: *const config.Config, paths: *const payload.Paths) !void {
    try args.append(gpa, "--no-colors");
    if (paths.ffmpeg_dir) |dir| {
        try args.append(gpa, "--ffmpeg-location");
        try args.append(gpa, dir);
    }
    if (cfg.cookies) |cookies| {
        try args.append(gpa, "--cookies");
        try args.append(gpa, cookies);
    }
    if (cfg.proxy) |proxy| {
        try args.append(gpa, "--proxy");
        try args.append(gpa, proxy);
    }
    try args.append(gpa, "--cache-dir");
    try args.append(gpa, try std.fmt.allocPrint(gpa, "{s}/yt-dlp", .{cfg.cache_dir}));
    try args.append(gpa, "--socket-timeout");
    try args.append(gpa, "20");
    try args.append(gpa, "--retries");
    try args.append(gpa, "3");
}

fn addExtraArgs(gpa: std.mem.Allocator, args: *ArgList, cfg: *const config.Config) !void {
    const extra = cfg.extra_args orelse return;
    var it = std.mem.tokenizeScalar(u8, extra, ' ');
    while (it.next()) |tok| try args.append(gpa, tok);
}

pub fn infoArgv(gpa: std.mem.Allocator, cfg: *const config.Config, paths: *const payload.Paths, url: []const u8) ![]const []const u8 {
    var args: ArgList = .empty;
    try args.append(gpa, paths.ytdlp);
    try args.append(gpa, "--no-playlist");
    try args.append(gpa, "-j");
    try args.append(gpa, "--no-progress");
    try addCommon(gpa, &args, cfg, paths);
    try addExtraArgs(gpa, &args, cfg);
    try args.append(gpa, url);
    return args.toOwnedSlice(gpa);
}

pub fn playlistArgv(gpa: std.mem.Allocator, cfg: *const config.Config, paths: *const payload.Paths, url: []const u8) ![]const []const u8 {
    var args: ArgList = .empty;
    try args.append(gpa, paths.ytdlp);
    try args.append(gpa, "--flat-playlist");
    try args.append(gpa, "-J");
    try args.append(gpa, "--no-progress");
    try addCommon(gpa, &args, cfg, paths);
    try addExtraArgs(gpa, &args, cfg);
    try args.append(gpa, url);
    return args.toOwnedSlice(gpa);
}

pub fn downloadArgv(
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    paths: *const payload.Paths,
    url: []const u8,
    choice: FormatChoice,
    format_id: ?[]const u8,
    out_template: []const u8,
) ![]const []const u8 {
    var args: ArgList = .empty;
    try args.append(gpa, paths.ytdlp);
    try args.append(gpa, "--no-playlist");
    try args.append(gpa, "-o");
    try args.append(gpa, out_template);
    switch (choice) {
        .audio => {
            try args.append(gpa, "-x");
            try args.append(gpa, "--audio-format");
            try args.append(gpa, "mp3");
        },
        .video => {
            const selector = if (format_id) |fid|
                try std.fmt.allocPrint(gpa, "{s}+bestaudio/best", .{fid})
            else
                "bestvideo+bestaudio/best";
            try args.append(gpa, "-f");
            try args.append(gpa, selector);
            try args.append(gpa, "--merge-output-format");
            try args.append(gpa, "mp4");
        },
    }
    try args.append(gpa, "--newline");
    try args.append(gpa, "--progress-template");
    try args.append(gpa, progress_template);
    try addCommon(gpa, &args, cfg, paths);
    try addExtraArgs(gpa, &args, cfg);
    try args.append(gpa, url);
    return args.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------------------------
// invocation
// ---------------------------------------------------------------------------------------------

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    argv: []const []const u8,
) !proc.Result {
    return runFull(io, gpa, cfg, argv, null, null);
}

pub fn runWithProgress(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    argv: []const []const u8,
    progress: ?proc.ProgressSink,
) !proc.Result {
    return runFull(io, gpa, cfg, argv, progress, null);
}

pub fn runFull(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    argv: []const []const u8,
    progress: ?proc.ProgressSink,
    cancel: ?*const std.atomic.Value(bool),
) !proc.Result {
    const dir = try std.fmt.allocPrint(gpa, "{s}/tmp", .{cfg.cache_dir});
    fsutil.ensureDir(io, dir) catch {};
    return proc.run(io, gpa, argv, .{
        .timeout_ms = cfg.job_timeout_ms,
        .tmp_dir = dir,
        .env_map = cfg.child_env,
        .progress = progress,
        .cancel = cancel,
    });
}

// ---------------------------------------------------------------------------------------------
// JSON mapping
// ---------------------------------------------------------------------------------------------

fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonFloat(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonInt(v: ?std.json.Value) ?u32 {
    const f = jsonFloat(v) orelse return null;
    if (f < 0) return null;
    return @intFromFloat(f);
}

/// reclip parses the first non-empty stdout line (some extractors emit several JSON objects).
pub fn firstJsonLine(stdout: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        return t;
    }
    return null;
}

const BestFormat = struct { id: []const u8, tbr: f64 };

pub fn parseInfo(gpa: std.mem.Allocator, stdout: []const u8) !Info {
    const line = firstJsonLine(stdout) orelse return error.NoJson;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadJson,
    };

    var best = std.AutoHashMap(u32, BestFormat).init(gpa);
    defer best.deinit();

    if (root.get("formats")) |formats_val| {
        switch (formats_val) {
            .array => |arr| {
                for (arr.items) |entry| {
                    const f = switch (entry) {
                        .object => |o| o,
                        else => continue,
                    };
                    const vcodec = jsonStr(f.get("vcodec")) orelse "none";
                    if (std.mem.eql(u8, vcodec, "none")) continue;
                    const height = jsonInt(f.get("height")) orelse continue;
                    if (height == 0) continue;
                    const id = jsonStr(f.get("format_id")) orelse continue;
                    const tbr = jsonFloat(f.get("tbr")) orelse 0;

                    if (best.get(height)) |prev| {
                        if (tbr <= prev.tbr) continue;
                    }
                    try best.put(height, .{ .id = try gpa.dupe(u8, id), .tbr = tbr });
                }
            },
            else => {},
        }
    }

    var formats = std.ArrayList(Format).empty;
    var it = best.iterator();
    while (it.next()) |kv| {
        try formats.append(gpa, .{
            .id = kv.value_ptr.id,
            .label = try std.fmt.allocPrint(gpa, "{d}p", .{kv.key_ptr.*}),
            .height = kv.key_ptr.*,
        });
    }
    std.mem.sort(Format, formats.items, {}, struct {
        fn lessThan(_: void, a: Format, b: Format) bool {
            return a.height > b.height;
        }
    }.lessThan);

    return .{
        .title = try gpa.dupe(u8, jsonStr(root.get("title")) orelse ""),
        .thumbnail = try gpa.dupe(u8, jsonStr(root.get("thumbnail")) orelse ""),
        .duration = jsonFloat(root.get("duration")),
        .uploader = try gpa.dupe(u8, jsonStr(root.get("uploader")) orelse ""),
        .formats = try formats.toOwnedSlice(gpa),
    };
}

pub fn writeInfoJson(writer: *std.Io.Writer, info: *const Info) !void {
    try std.json.Stringify.value(InfoResponse{
        .title = info.title,
        .thumbnail = info.thumbnail,
        .duration = info.duration,
        .uploader = info.uploader,
        .formats = info.formats,
    }, .{}, writer);
}

pub fn parsePlaylistUrls(gpa: std.mem.Allocator, stdout: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stdout, .{});
    defer parsed.deinit();

    var urls = std.ArrayList([]const u8).empty;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadJson,
    };
    const entries = root.get("entries") orelse return urls.toOwnedSlice(gpa);
    switch (entries) {
        .array => |arr| for (arr.items) |entry| {
            const obj = switch (entry) {
                .object => |o| o,
                else => continue,
            };
            if (jsonStr(obj.get("url"))) |u| {
                if (u.len != 0) try urls.append(gpa, try gpa.dupe(u8, u));
            }
        },
        else => {},
    }
    return urls.toOwnedSlice(gpa);
}

pub fn writePlaylistJson(writer: *std.Io.Writer, urls: []const []const u8) !void {
    try std.json.Stringify.value(PlaylistResponse{ .urls = urls }, .{}, writer);
}

/// reclip: strip `\/:*?"<>|`, trim, cap at 100 chars.
pub fn sanitizeFilename(gpa: std.mem.Allocator, title: []const u8) ![]const u8 {
    const forbidden = "\\/:*?\"<>|";
    var out = std.ArrayList(u8).empty;
    for (title) |c| {
        if (std.mem.indexOfScalar(u8, forbidden, c) != null) continue;
        if (out.items.len >= 100) break;
        try out.append(gpa, c);
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return gpa.dupe(u8, trimmed);
}

/// Find the produced file in `dir` for `job_id`, preferring `want_ext`.
pub fn findOutputFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    job_id: []const u8,
    want_ext: []const u8,
) !?[]const u8 {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer d.close(io);

    var fallback: ?[]const u8 = null;
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, job_id)) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, entry.name });
        if (std.mem.endsWith(u8, entry.name, want_ext)) return path;
        if (fallback == null) fallback = path;
    }
    return fallback;
}

test "sanitize filename" {
    const got = try sanitizeFilename(std.testing.allocator, " a/b:c*d?e\"f<g>h|i\\j ");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("abcdefghij", got);
}

test "parse info picks best per height" {
    const json =
        \\{"title":"T","thumbnail":"http://x/t.jpg","duration":12,"uploader":"U","formats":[
        \\ {"format_id":"137","height":1080,"tbr":4000,"vcodec":"avc1"},
        \\ {"format_id":"137x","height":1080,"tbr":5000,"vcodec":"avc1"},
        \\ {"format_id":"140","height":null,"tbr":128,"vcodec":"none","acodec":"mp4a"},
        \\ {"format_id":"18","height":360,"tbr":600,"vcodec":"avc1"}]}
    ;
    const info = try parseInfo(std.testing.allocator, json);
    defer {
        std.testing.allocator.free(info.title);
        std.testing.allocator.free(info.thumbnail);
        std.testing.allocator.free(info.uploader);
        for (info.formats) |f| {
            std.testing.allocator.free(f.id);
            std.testing.allocator.free(f.label);
        }
        std.testing.allocator.free(info.formats);
    }
    try std.testing.expectEqual(@as(usize, 2), info.formats.len);
    try std.testing.expectEqualStrings("137x", info.formats[0].id);
    try std.testing.expectEqualStrings("1080p", info.formats[0].label);
    try std.testing.expectEqual(@as(u32, 360), info.formats[1].height);
}

test "parse playlist urls" {
    const json =
        \\{"entries":[{"url":"https://a"},{"title":"no url"},{"url":"https://b"}]}
    ;
    const urls = try parsePlaylistUrls(std.testing.allocator, json);
    defer {
        for (urls) |u| std.testing.allocator.free(u);
        std.testing.allocator.free(urls);
    }
    try std.testing.expectEqual(@as(usize, 2), urls.len);
}

test "parse progress line" {
    const p = parseProgressLine("reclipz|1048576|10485760|NA|2097152.5|3.5|NA|5") orelse unreachable;
    try std.testing.expectEqual(@as(?u64, 1048576), p.downloaded_bytes);
    try std.testing.expectEqual(@as(?u64, 10485760), p.total_bytes);
    try std.testing.expectEqual(@as(?f64, 2097152.5), p.speed);
    try std.testing.expectEqual(@as(?u64, 3), p.eta);
    try std.testing.expectEqual(@as(?u64, 5), p.fragment_count);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), p.percent().?, 0.001);
}

test "progress line ignores other output" {
    try std.testing.expect(parseProgressLine("[download]  10% of 1MiB") == null);
    const p = parseProgressLine("reclipz|NA|NA|NA|NA|NA|NA|NA").?;
    try std.testing.expect(p.isEmpty());
}
