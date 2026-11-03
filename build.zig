const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const payload_dir = b.option(
        []const u8,
        "payload-dir",
        "Directory containing optional engine payloads: yt-dlp, ffmpeg, ffprobe (default: payload)",
    ) orelse "payload";

    const manifest = readManifest(b.allocator, b.graph.io, payload_dir) catch |err| {
        std.debug.print("reclipz: could not inspect payload dir '{s}': {s}\n", .{ payload_dir, @errorName(err) });
        std.process.exit(1);
    };

    const opts = b.addOptions();
    opts.addOption(bool, "has_ytdlp", manifest.has_ytdlp);
    opts.addOption([]const u8, "ytdlp_version", manifest.ytdlp_version);
    opts.addOption([]const u8, "ytdlp_sha256", manifest.ytdlp_sha256);
    opts.addOption(bool, "has_ffmpeg", manifest.has_ffmpeg);
    opts.addOption([]const u8, "ffmpeg_sha256", manifest.ffmpeg_sha256);
    opts.addOption([]const u8, "ffprobe_sha256", manifest.ffprobe_sha256);

    const exe = b.addExecutable(.{
        .name = "reclipz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("payload_manifest", opts);
    exe.root_module.addAnonymousImport("payload-ytdlp", .{
        .root_source_file = payloadSource(b, payload_dir, "yt-dlp"),
    });
    exe.root_module.addAnonymousImport("payload-ffmpeg", .{
        .root_source_file = payloadSource(b, payload_dir, "ffmpeg"),
    });
    exe.root_module.addAnonymousImport("payload-ffprobe", .{
        .root_source_file = payloadSource(b, payload_dir, "ffprobe"),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run reclipz");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// If the payload file is missing, point at the committed empty stub so `@embedFile` still resolves.
fn payloadSource(b: *std.Build, payload_dir: []const u8, name: []const u8) std.Build.LazyPath {
    const joined = b.pathJoin(&.{ payload_dir, name });
    if (std.Io.Dir.cwd().access(b.graph.io, joined, .{})) |_| {
        return b.path(joined);
    } else |_| {}
    return b.path("src/assets/empty.bin");
}

fn readManifest(gpa: std.mem.Allocator, io: std.Io, payload_dir: []const u8) !struct {
    has_ytdlp: bool,
    ytdlp_version: []const u8,
    ytdlp_sha256: []const u8,
    has_ffmpeg: bool,
    ffmpeg_sha256: []const u8,
    ffprobe_sha256: []const u8,
} {
    var has_ytdlp = false;
    var has_ffmpeg = false;
    var version: []const u8 = "unknown";
    var yt_sum: []const u8 = "";
    var ff_sum: []const u8 = "";
    var fp_sum: []const u8 = "";

    const yt = try std.fs.path.join(gpa, &.{ payload_dir, "yt-dlp" });
    if (std.Io.Dir.cwd().access(io, yt, .{})) |_| {
        has_ytdlp = true;
        yt_sum = try hashFile(io, gpa, yt);
        const vpath = try std.fs.path.join(gpa, &.{ payload_dir, "yt-dlp.version" });
        if (std.Io.Dir.cwd().readFileAlloc(io, vpath, gpa, .limited(4096))) |v| {
            version = std.mem.trim(u8, v, " \t\r\n");
        } else |_| {}
    } else |_| {}

    const ff = try std.fs.path.join(gpa, &.{ payload_dir, "ffmpeg" });
    if (std.Io.Dir.cwd().access(io, ff, .{})) |_| {
        has_ffmpeg = true;
        ff_sum = try hashFile(io, gpa, ff);
    } else |_| {}
    const fp = try std.fs.path.join(gpa, &.{ payload_dir, "ffprobe" });
    if (std.Io.Dir.cwd().access(io, fp, .{})) |_| {
        fp_sum = try hashFile(io, gpa, fp);
    } else |_| {}

    return .{
        .has_ytdlp = has_ytdlp,
        .ytdlp_version = version,
        .ytdlp_sha256 = yt_sum,
        .has_ffmpeg = has_ffmpeg,
        .ffmpeg_sha256 = ff_sum,
        .ffprobe_sha256 = fp_sum,
    };
}

fn hashFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]const u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.allocPrint(gpa, "{x}", .{&digest});
}
