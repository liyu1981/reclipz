//! `reclipz update` — refresh the embedded-engine payload from the official yt-dlp release.
//!
//! Mirrors upstream ReClip's "keep yt-dlp fresh" behaviour (its entrypoint ran `pip install -U
//! yt-dlp`), but without pip: download the platform asset, verify it against the release's
//! SHA2-256SUMS (and optionally its GPG signature), install into the cache, repoint engine.json.

const std = @import("std");
const config = @import("config.zig");
const fsutil = @import("fsutil.zig");
const log = @import("log.zig");
const manifest = @import("payload_manifest");
const payload = @import("payload.zig");
const proc = @import("proc.zig");
const version_mod = @import("version.zig");

const api_base = "https://api.github.com/repos/yt-dlp/yt-dlp/releases";

pub const Options = struct {
    check_only: bool = false,
    version: ?[]const u8 = null,
    force: bool = false,
    allow_unverified: bool = false,
    gpg: bool = false,
};

const Release = struct {
    tag: []const u8,
    asset_url: []const u8,
    asset_size: u64,
    sums_url: []const u8,
    sig_url: ?[]const u8,
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const config.Config,
    opts: Options,
) !void {
    const current = payload.readActiveVersion(gpa, io, cfg) orelse manifest.ytdlp_version;
    const asset = payload.assetName();

    log.info("current engine: yt-dlp {s}", .{current});
    log.info("target asset:   {s}", .{asset});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const now = std.Io.Timestamp.now(io, .real);
    client.now = now;
    client.ca_bundle.rescan(gpa, io, now) catch |e| {
        log.debug("system CA scan failed: {s}", .{@errorName(e)});
    };
    if (payload.cacertPath(gpa, io, cfg) catch null) |ca| {
        client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now, ca) catch |e| {
            log.debug("embedded CA load failed: {s}", .{@errorName(e)});
        };
    }

    const api_url = if (opts.version) |v|
        try std.fmt.allocPrint(gpa, "{s}/tags/{s}", .{ api_base, v })
    else
        try std.fmt.allocPrint(gpa, "{s}/latest", .{api_base});

    const json = fetchAlloc(io, gpa, &client, api_url) catch |e| {
        log.err("could not query GitHub releases: {s}", .{@errorName(e)});
        log.err("check network access, or set RECLIPZ_YTDLP to a local build", .{});
        return e;
    };
    const release = parseRelease(gpa, json, asset) catch |e| {
        log.err("could not find asset '{s}' in the release metadata: {s}", .{ asset, @errorName(e) });
        return e;
    };

    if (std.mem.eql(u8, release.tag, current)) {
        log.info("already up to date: yt-dlp {s}", .{current});
        if (opts.check_only) return;
        if (!opts.force) return;
        log.info("--force given; reinstalling {s}", .{release.tag});
    } else {
        log.info("update available: {s} -> {s} ({d} bytes)", .{ current, release.tag, release.asset_size });
    }
    if (opts.check_only) return;

    // Download into the cache tmp dir.
    const tmp_dir = try payload.tmpPath(gpa, io, cfg);
    const download_path = try std.fmt.allocPrint(gpa, "{s}/yt-dlp-{s}.download", .{ tmp_dir, release.tag });
    defer std.Io.Dir.cwd().deleteFile(io, download_path) catch {};

    log.info("downloading {s} …", .{asset});
    {
        var file = try std.Io.Dir.cwd().createFile(io, download_path, .{ .truncate = true });
        defer file.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        try fetchTo(io, gpa, &client, release.asset_url, &writer.interface);
        try writer.interface.flush();
    }

    const actual = try sha256File(gpa, io, download_path);
    log.info("downloaded {d} bytes (sha256 {s})", .{ try fileSize(io, download_path), actual });

    if (!opts.allow_unverified) {
        const sums = fetchAlloc(io, gpa, &client, release.sums_url) catch |e| {
            log.err("could not download SHA2-256SUMS: {s}", .{@errorName(e)});
            return e;
        };
        const expected = findChecksum(sums, asset) orelse {
            log.err("no checksum for {s} in SHA2-256SUMS", .{asset});
            return error.ChecksumMissing;
        };
        if (!std.mem.eql(u8, expected, actual)) {
            log.err("checksum mismatch for {s}", .{asset});
            log.err("  expected {s}", .{expected});
            log.err("  actual   {s}", .{actual});
            return error.ChecksumMismatch;
        }
        log.info("checksum verified", .{});

        if (opts.gpg) {
            const sums_path = try std.fmt.allocPrint(gpa, "{s}/SHA2-256SUMS-{s}", .{ tmp_dir, release.tag });
            defer std.Io.Dir.cwd().deleteFile(io, sums_path) catch {};
            {
                var f = try std.Io.Dir.cwd().createFile(io, sums_path, .{ .truncate = true });
                defer f.close(io);
                var b: [4096]u8 = undefined;
                var w = f.writer(io, &b);
                try w.interface.writeAll(sums);
                try w.interface.flush();
            }
            if (release.sig_url) |sig_url| {
                const sig_path = try std.fmt.allocPrint(gpa, "{s}.sig", .{sums_path});
                defer std.Io.Dir.cwd().deleteFile(io, sig_path) catch {};
                {
                    var f = try std.Io.Dir.cwd().createFile(io, sig_path, .{ .truncate = true });
                    defer f.close(io);
                    var b: [4096]u8 = undefined;
                    var w = f.writer(io, &b);
                    try fetchTo(io, gpa, &client, sig_url, &w.interface);
                    try w.interface.flush();
                }
                const res = proc.run(io, gpa, &.{ "gpg", "--verify", sig_path, sums_path }, .{
                    .timeout_ms = 30_000,
                    .tmp_dir = tmp_dir,
                }) catch |e| {
                    log.err("gpg not available: {s}", .{@errorName(e)});
                    return e;
                };
                if (!res.ok()) {
                    log.err("GPG signature verification failed: {s}", .{res.lastStderrLine()});
                    return error.BadSignature;
                }
                log.info("GPG signature verified", .{});
            } else {
                log.warn("release has no SHA2-256SUMS.sig; skipping GPG verification", .{});
            }
        }
    } else {
        log.warn("checksum verification skipped (--allow-unverified)", .{});
    }

    try payload.installYtdlp(gpa, io, cfg, release.tag, download_path);
    payload.prune(gpa, io, cfg, release.tag);
    log.info("installed yt-dlp {s}; restart `reclipz serve` to use it", .{release.tag});
}

// ---------------------------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------------------------

fn fetchAlloc(io: std.Io, gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(gpa);
    errdefer out.deinit();
    try fetchTo(io, gpa, client, url, &out.writer);
    return out.toOwnedSlice();
}

fn fetchTo(
    io: std.Io,
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    writer: *std.Io.Writer,
) !void {
    _ = io;
    const ua = "reclipz/" ++ version_mod.string ++ " (+https://github.com/averygan/reclip)";
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = writer,
        .headers = .{
            .user_agent = .{ .override = ua },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
    });
    if (@backingInt(res.status) < 200 or @backingInt(res.status) > 299) {
        log.err("HTTP {d} for {s}", .{ @backingInt(res.status), url });
        return error.HttpStatus;
    }
    _ = gpa;
}

// ---------------------------------------------------------------------------------------------
// metadata / checksums
// ---------------------------------------------------------------------------------------------

fn parseRelease(gpa: std.mem.Allocator, json: []const u8, asset: []const u8) !Release {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    // Leaked into gpa intentionally: used for the process lifetime of this command.
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadJson,
    };
    const tag = switch (root.get("tag_name") orelse return error.BadJson) {
        .string => |s| s,
        else => return error.BadJson,
    };
    const assets = switch (root.get("assets") orelse return error.BadJson) {
        .array => |a| a,
        else => return error.BadJson,
    };

    var asset_url: ?[]const u8 = null;
    var asset_size: u64 = 0;
    var sums_url: ?[]const u8 = null;
    var sig_url: ?[]const u8 = null;

    for (assets.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = switch (obj.get("name") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const url = switch (obj.get("browser_download_url") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name, asset)) {
            asset_url = url;
            if (obj.get("size")) |sz| {
                if (sz == .integer) asset_size = @intCast(sz.integer);
            }
        } else if (std.mem.eql(u8, name, "SHA2-256SUMS")) {
            sums_url = url;
        } else if (std.mem.eql(u8, name, "SHA2-256SUMS.sig")) {
            sig_url = url;
        }
    }

    return .{
        .tag = tag,
        .asset_url = asset_url orelse return error.AssetNotFound,
        .asset_size = asset_size,
        .sums_url = sums_url orelse return error.ChecksumMissing,
        .sig_url = sig_url,
    };
}

pub fn findChecksum(sums: []const u8, asset: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, sums, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, trimmed, " \t*");
        const hash = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        if (std.mem.eql(u8, name, asset) and hash.len == 64) return hash;
    }
    return null;
}

fn sha256File(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var rbuf: [64 * 1024]u8 = undefined;
    var reader = f.reader(io, &rbuf);
    var chunk: [1 << 20]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(gpa, "{x}", .{&digest});
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    return st.size;
}

test "find checksum" {
    const sums =
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  yt-dlp_linux
        \\bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *yt-dlp_musllinux
        \\
    ;
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        findChecksum(sums, "yt-dlp_linux").?,
    );
    try std.testing.expectEqualStrings(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        findChecksum(sums, "yt-dlp_musllinux").?,
    );
    try std.testing.expect(findChecksum(sums, "nope") == null);
}

test "parse release" {
    const json =
        \\{"tag_name":"2026.10.26","assets":[
        \\ {"name":"yt-dlp_linux","size":41166968,"browser_download_url":"https://x/yt-dlp_linux"},
        \\ {"name":"SHA2-256SUMS","browser_download_url":"https://x/SHA2-256SUMS"},
        \\ {"name":"SHA2-256SUMS.sig","browser_download_url":"https://x/SHA2-256SUMS.sig"}]}
    ;
    const rel = try parseRelease(std.testing.allocator, json, "yt-dlp_linux");
    try std.testing.expectEqualStrings("2026.10.26", rel.tag);
    try std.testing.expectEqual(@as(u64, 41166968), rel.asset_size);
    try std.testing.expectEqualStrings("https://x/SHA2-256SUMS", rel.sums_url);
    try std.testing.expect(rel.sig_url != null);
}
