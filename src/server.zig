//! HTTP server: serves the (byte-identical) reclip UI and the API endpoints.

const std = @import("std");
const assets = @import("assets.zig");
const config = @import("config.zig");
const engine = @import("engine.zig");
const fsutil = @import("fsutil.zig");
const jobs = @import("jobs.zig");
const log = @import("log.zig");
const payload = @import("payload.zig");

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    paths: *const payload.Paths,
    registry: *jobs.Registry,
};

const max_body = 1 << 20; // 1 MiB is plenty for a URL list payload

pub fn serve(app: *App) !void {
    const address = try std.Io.net.IpAddress.parse(app.cfg.host, app.cfg.port);
    var server = try address.listen(app.io, .{ .reuse_address = true });
    defer server.deinit(app.io);

    log.info("listening on http://{s}:{d}", .{ app.cfg.host, app.cfg.port });
    log.info("engine: yt-dlp {s} ({s}) at {s}", .{ app.paths.version, @tagName(app.paths.source), app.paths.ytdlp });

    const sweeper = std.Thread.spawn(.{}, sweepLoop, .{app}) catch |e| blk: {
        log.warn("could not start TTL sweeper: {s}", .{@errorName(e)});
        break :blk null;
    };
    _ = sweeper;

    while (true) {
        const stream = server.accept(app.io) catch |e| {
            log.debug("accept failed: {s}", .{@errorName(e)});
            continue;
        };
        const ctx = app.gpa.create(ConnCtx) catch {
            stream.close(app.io);
            continue;
        };
        ctx.* = .{ .app = app, .stream = stream };
        const thread = std.Thread.spawn(.{}, connMain, .{ctx}) catch |e| {
            log.warn("could not spawn connection thread: {s}", .{@errorName(e)});
            stream.close(app.io);
            app.gpa.destroy(ctx);
            continue;
        };
        thread.detach();
    }
}

const ConnCtx = struct {
    app: *App,
    stream: std.Io.net.Stream,
};

fn connMain(ctx: *ConnCtx) void {
    const app = ctx.app;
    defer app.gpa.destroy(ctx);
    defer ctx.stream.close(app.io);
    handleConnection(app, ctx.stream) catch |e| {
        log.debug("connection closed: {s}", .{@errorName(e)});
    };
}

fn handleConnection(app: *App, stream: std.Io.net.Stream) !void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(app.io, &read_buf);
    var writer = stream.writer(app.io, &write_buf);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    while (true) {
        var req = server.receiveHead() catch |e| switch (e) {
            error.HttpHeadersInvalid, error.HttpHeadersOversize => return,
            else => return e,
        };
        const keep_alive = req.head.keep_alive;
        route(app, &req) catch |e| {
            log.debug("request failed: {s}", .{@errorName(e)});
            return;
        };
        if (!keep_alive) return;
    }
}

fn route(app: *App, req: *std.http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const target = req.head.target;
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
    const method = req.head.method;

    // Always consume the request body before responding: std's server asserts that a request with
    // a body has been read/discarded before the connection can be reused.
    var body: []const u8 = "";
    if (method.requestHasBody()) {
        body = readRequestBody(a, req) catch |e| switch (e) {
            error.BodyTooLarge => return jsonError(a, req, .payload_too_large, "Request too large"),
            else => return jsonError(a, req, .bad_request, "Invalid request body"),
        };
    }

    if (method == .GET or method == .HEAD) {
        if (std.mem.eql(u8, path, "/")) {
            return respondStatic(req, "text/html; charset=utf-8", assets.index_html);
        }
        if (std.mem.eql(u8, path, "/static/favicon.svg")) {
            return respondStatic(req, "image/svg+xml", assets.favicon_svg);
        }
        if (std.mem.startsWith(u8, path, "/api/status/")) {
            return statusRoute(app, a, req, path["/api/status/".len..]);
        }
        if (std.mem.startsWith(u8, path, "/api/file/")) {
            return fileRoute(app, a, req, path["/api/file/".len..]);
        }
        if (std.mem.startsWith(u8, path, "/api/cancel/")) {
            return cancelRoute(app, a, req, path["/api/cancel/".len..]);
        }
    } else if (method == .POST) {
        if (std.mem.eql(u8, path, "/api/info")) return infoRoute(app, a, req, body);
        if (std.mem.eql(u8, path, "/api/playlist")) return playlistRoute(app, a, req, body);
        if (std.mem.eql(u8, path, "/api/download")) return downloadRoute(app, a, req, body);
        if (std.mem.startsWith(u8, path, "/api/cancel/")) {
            return cancelRoute(app, a, req, path["/api/cancel/".len..]);
        }
    }

    return jsonError(a, req, .not_found, "Not found");
}

// ---------------------------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------------------------

fn readRequestBody(a: std.mem.Allocator, req: *std.http.Server.Request) ![]const u8 {
    const content_length = req.head.content_length;
    const chunked = req.head.transfer_encoding != .none;
    const has_body = chunked or (content_length orelse 0) > 0;
    if (content_length) |len| {
        if (len > max_body) return error.BodyTooLarge;
    }

    var transfer_buf: [8 * 1024]u8 = undefined;
    const reader = if (req.head.expect != null)
        try req.readerExpectContinue(&transfer_buf)
    else
        req.readerExpectNone(&transfer_buf);

    if (!has_body) return "";

    const limit: std.Io.Limit = if (content_length) |len| .limited(len) else .limited(max_body);
    return reader.allocRemaining(a, limit);
}

fn respondStatic(req: *std.http.Server.Request, content_type: []const u8, body: []const u8) !void {
    try req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

fn respondJson(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn jsonError(allocator: std.mem.Allocator, req: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(struct { @"error": []const u8 }{ .@"error" = message }, .{}, &out.writer);
    return respondJson(req, status, out.written());
}

const UrlBody = struct { url: []const u8 = "" };

const DownloadBody = struct {
    url: []const u8 = "",
    format: []const u8 = "video",
    format_id: ?[]const u8 = null,
    title: []const u8 = "",
};

fn parseBody(comptime T: type, a: std.mem.Allocator, body: []const u8) !T {
    if (body.len == 0) return .{};
    const parsed = try std.json.parseFromSlice(T, a, body, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

// ---------------------------------------------------------------------------------------------
// /api/info
// ---------------------------------------------------------------------------------------------

fn infoRoute(app: *App, a: std.mem.Allocator, req: *std.http.Server.Request, body: []const u8) !void {
    const parsed = parseBody(UrlBody, a, body) catch {
        return jsonError(a, req, .bad_request, "Invalid JSON body");
    };
    const url = std.mem.trim(u8, parsed.url, " \t\r\n");
    if (url.len == 0) return jsonError(a, req, .bad_request, "No URL provided");

    const argv = try engine.infoArgv(a, app.cfg, app.paths, url);
    const res = engine.run(app.io, a, app.cfg, argv) catch |e| {
        const msg = try std.fmt.allocPrint(a, "Engine failed to start ({s}) — run `reclipz selftest`", .{@errorName(e)});
        return jsonError(a, req, .bad_request, msg);
    };
    if (res.timed_out) return jsonError(a, req, .bad_request, "Timed out fetching video info");
    if (!res.ok()) return jsonError(a, req, .bad_request, res.lastStderrLine());

    const info = engine.parseInfo(a, res.stdout) catch |e| {
        const msg = try std.fmt.allocPrint(a, "Could not parse engine output: {s}", .{@errorName(e)});
        return jsonError(a, req, .bad_request, msg);
    };

    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try engine.writeInfoJson(&out.writer, &info);
    try respondJson(req, .ok, out.written());
}

// ---------------------------------------------------------------------------------------------
// /api/playlist
// ---------------------------------------------------------------------------------------------

fn playlistRoute(app: *App, a: std.mem.Allocator, req: *std.http.Server.Request, body: []const u8) !void {
    const parsed = parseBody(UrlBody, a, body) catch {
        return jsonError(a, req, .bad_request, "Invalid JSON body");
    };
    const url = std.mem.trim(u8, parsed.url, " \t\r\n");
    if (url.len == 0) return jsonError(a, req, .bad_request, "No URL provided");

    const argv = try engine.playlistArgv(a, app.cfg, app.paths, url);
    const res = engine.run(app.io, a, app.cfg, argv) catch |e| {
        const msg = try std.fmt.allocPrint(a, "Engine failed to start ({s}) — run `reclipz selftest`", .{@errorName(e)});
        return jsonError(a, req, .bad_request, msg);
    };
    if (res.timed_out) return jsonError(a, req, .bad_request, "Timed out fetching playlist info");
    if (!res.ok()) return jsonError(a, req, .bad_request, res.lastStderrLine());

    const urls = engine.parsePlaylistUrls(a, res.stdout) catch |e| {
        const msg = try std.fmt.allocPrint(a, "Could not parse engine output: {s}", .{@errorName(e)});
        return jsonError(a, req, .bad_request, msg);
    };

    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try engine.writePlaylistJson(&out.writer, urls);
    try respondJson(req, .ok, out.written());
}

// ---------------------------------------------------------------------------------------------
// /api/download
// ---------------------------------------------------------------------------------------------

fn downloadRoute(app: *App, a: std.mem.Allocator, req: *std.http.Server.Request, body: []const u8) !void {
    const parsed = parseBody(DownloadBody, a, body) catch {
        return jsonError(a, req, .bad_request, "Invalid JSON body");
    };

    const url = std.mem.trim(u8, parsed.url, " \t\r\n");
    if (url.len == 0) return jsonError(a, req, .bad_request, "No URL provided");
    if (parsed.format_id) |fid| {
        if (fid.len > 128 or std.mem.startsWith(u8, fid, "-") or std.mem.indexOfAny(u8, fid, " \t\r\n") != null) {
            return jsonError(a, req, .bad_request, "Invalid format_id");
        }
    }

    const job_id = app.registry.start(
        url,
        engine.FormatChoice.parse(parsed.format),
        parsed.format_id,
        parsed.title,
    ) catch |e| {
        const msg = try std.fmt.allocPrint(a, "Could not start download: {s}", .{@errorName(e)});
        return jsonError(a, req, .bad_request, msg);
    };

    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try std.json.Stringify.value(struct { job_id: []const u8 }{ .job_id = job_id }, .{}, &out.writer);
    try respondJson(req, .ok, out.written());
}

// ---------------------------------------------------------------------------------------------
// /api/status/<id>, /api/cancel/<id>, /api/file/<id>
// ---------------------------------------------------------------------------------------------

const ProgressResponse = struct {
    downloaded_bytes: ?u64 = null,
    total_bytes: ?u64 = null,
    speed: ?f64 = null,
    eta: ?u64 = null,
    percent: ?f64 = null,
    fragment_index: ?u64 = null,
    fragment_count: ?u64 = null,
};

const StatusResponse = struct {
    status: []const u8,
    @"error": ?[]const u8,
    filename: ?[]const u8,
    progress: ?ProgressResponse = null,
};

fn statusRoute(app: *App, a: std.mem.Allocator, req: *std.http.Server.Request, job_id: []const u8) !void {
    if (!validJobId(job_id)) return jsonError(a, req, .not_found, "Job not found");
    const job = (try app.registry.snapshot(a, job_id)) orelse
        return jsonError(a, req, .not_found, "Job not found");

    const progress: ?ProgressResponse = if (job.progress.isEmpty()) null else .{
        .downloaded_bytes = job.progress.downloaded_bytes,
        .total_bytes = job.progress.total_bytes,
        .speed = job.progress.speed,
        .eta = job.progress.eta,
        .percent = job.progress.percent(),
        .fragment_index = job.progress.fragment_index,
        .fragment_count = job.progress.fragment_count,
    };

    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try std.json.Stringify.value(StatusResponse{
        .status = job.status.asApiString(),
        .@"error" = job.err,
        .filename = job.filename,
        .progress = progress,
    }, .{}, &out.writer);
    try respondJson(req, .ok, out.written());
}

fn cancelRoute(app: *App, a: std.mem.Allocator, req: *std.http.Server.Request, job_id: []const u8) !void {
    if (!validJobId(job_id)) return jsonError(a, req, .not_found, "Job not found");
    if (!app.registry.cancel(job_id)) return jsonError(a, req, .not_found, "Job not found");
    try respondJson(req, .ok, "{\"status\":\"cancelling\"}");
}

fn fileRoute(app: *App, a: std.mem.Allocator, req: *std.http.Server.Request, job_id: []const u8) !void {
    if (!validJobId(job_id)) return jsonError(a, req, .not_found, "File not ready");
    const job = (try app.registry.snapshot(a, job_id)) orelse
        return jsonError(a, req, .not_found, "File not ready");
    if (job.status != .done) return jsonError(a, req, .not_found, "File not ready");

    const path = job.file orelse return jsonError(a, req, .not_found, "File not ready");
    const name = job.filename orelse fsutil.baseName(path);

    var file = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch {
        return jsonError(a, req, .not_found, "File not ready");
    };
    defer file.close(app.io);
    const stat = try file.stat(app.io);

    const ascii_name = try asciiFallback(a, name);
    const encoded = try fsutil.percentEncode(a, name);
    const disposition = try std.fmt.allocPrint(
        a,
        "attachment; filename=\"{s}\"; filename*=UTF-8''{s}",
        .{ ascii_name, encoded },
    );

    var body_buf: [16 * 1024]u8 = undefined;
    var bw = try req.respondStreaming(&body_buf, .{
        .content_length = stat.size,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "content-disposition", .value = disposition },
            .{ .name = "cache-control", .value = "no-store" },
        } },
    });

    var file_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(app.io, &file_buf);
    _ = try fr.interface.streamRemaining(&bw.writer);
    try bw.end();
}

fn validJobId(job_id: []const u8) bool {
    if (job_id.len != 10) return false;
    for (job_id) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn asciiFallback(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (c >= 0x20 and c < 0x7f and c != '"' and c != '\\') c else '_';
    }
    return out;
}

fn sweepLoop(app: *App) void {
    while (true) {
        app.io.sleep(.fromSeconds(300), .awake) catch {};
        app.registry.sweep();
    }
}

test "job id validation" {
    try std.testing.expect(validJobId("a1b2c3d4e5"));
    try std.testing.expect(!validJobId("../etc"));
    try std.testing.expect(!validJobId("a1b2c3d4e5f"));
}
