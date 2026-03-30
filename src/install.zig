const std = @import("std");
const fs = @import("fs.zig");
const cfg = @import("config.zig");
const official = @import("official.zig");
const platform_mod = @import("platform.zig");

pub fn installVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout: cfg.RootLayout,
    platform: platform_mod.Platform,
    package: official.File,
) !void {
    try layout.ensureBaseDirs(io);

    const archive_path = try layout.archivePath(allocator, package.filename);
    defer allocator.free(archive_path);

    const sdk_path = try layout.sdkDir(allocator, package.version);
    defer allocator.free(sdk_path);

    if (fs.pathExists(io, sdk_path)) return;

    try ensureArchive(allocator, io, archive_path, package);

    if (platform.archive_kind == .tar_gz) {
        try extractTarGz(io, archive_path, sdk_path);
    } else {
        try extractZip(allocator, io, archive_path, sdk_path);
    }
}

pub fn removeVersion(io: std.Io, layout: cfg.RootLayout, version: []const u8) !void {
    const sdk_path = try layout.sdkDir(layout.allocator, version);
    defer layout.allocator.free(sdk_path);
    if (!fs.pathExists(io, sdk_path)) return error.VersionNotInstalled;
    try fs.deleteTreeIfExists(io, sdk_path);
}

test "remove version deletes installed sdk directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    var layout = try cfg.RootLayout.init(std.testing.allocator, root_path);
    defer layout.deinit();
    try layout.ensureBaseDirs(std.testing.io);

    const sdk_path = try layout.sdkDir(std.testing.allocator, "go1.26.1");
    defer std.testing.allocator.free(sdk_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sdk_path);

    try removeVersion(std.testing.io, layout, "go1.26.1");
    try std.testing.expect(!fs.pathExists(std.testing.io, sdk_path));
}

test "remove version errors when sdk is not installed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    var layout = try cfg.RootLayout.init(std.testing.allocator, root_path);
    defer layout.deinit();
    try layout.ensureBaseDirs(std.testing.io);

    try std.testing.expectError(error.VersionNotInstalled, removeVersion(std.testing.io, layout, "go1.26.1"));
}

fn ensureArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    package: official.File,
) !void {
    if (fs.pathExists(io, archive_path)) {
        try verifyArchive(io, archive_path, package.sha256);
        return;
    }
    try downloadArchive(allocator, io, archive_path, package.filename);
    try verifyArchive(io, archive_path, package.sha256);
}

fn downloadArchive(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, filename: []const u8) !void {
    const url = try std.fmt.allocPrint(allocator, "https://go.dev/dl/{s}", .{filename});
    defer allocator.free(url);

    if (std.fs.path.dirname(archive_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    var file = try std.Io.Dir.createFileAbsolute(io, archive_path, .{ .truncate = true });
    defer file.close(io);

    var file_buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &file_buffer);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    });
    try writer.flush();
    if (result.status != .ok) return error.BadServerResponse;
}

fn verifyArchive(io: std.Io, archive_path: []const u8, expected_sha256: []const u8) !void {
    const actual = try sha256HexFile(io, archive_path);
    defer std.heap.page_allocator.free(actual);
    if (!std.ascii.eqlIgnoreCase(actual, expected_sha256)) return error.ChecksumMismatch;
}

fn sha256HexFile(io: std.Io, archive_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer file.close(io);

    var reader = file.reader(io, &.{});
    var buf: [8192]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const encoded = std.fmt.bytesToHex(digest, .lower);
    const out = try std.heap.page_allocator.alloc(u8, encoded.len);
    @memcpy(out, &encoded);
    return out;
}

fn extractTarGz(io: std.Io, archive_path: []const u8, sdk_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, sdk_path);
    errdefer fs.deleteTreeIfExists(io, sdk_path) catch {};

    var archive_file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer archive_file.close(io);

    var read_buffer: [16 * 1024]u8 = undefined;
    var file_reader = archive_file.reader(io, &read_buffer);
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &flate_buffer);
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, sdk_path, .{});
    defer dest_dir.close(io);

    try std.tar.pipeToFileSystem(io, dest_dir, &gzip.reader, .{
        .strip_components = 1,
    });
}

fn extractZip(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, sdk_path: []const u8) !void {
    const tmp_base = try std.fmt.allocPrint(allocator, "{s}.tmp", .{sdk_path});
    defer allocator.free(tmp_base);

    try fs.deleteTreeIfExists(io, tmp_base);
    try std.Io.Dir.cwd().createDirPath(io, tmp_base);
    errdefer fs.deleteTreeIfExists(io, tmp_base) catch {};

    var archive_file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer archive_file.close(io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var file_reader = archive_file.reader(io, &read_buffer);

    var tmp_dir = try std.Io.Dir.openDirAbsolute(io, tmp_base, .{});
    defer tmp_dir.close(io);

    var diagnostics = std.zip.Diagnostics{ .allocator = allocator };
    defer diagnostics.deinit();
    try std.zip.extract(tmp_dir, &file_reader, .{ .diagnostics = &diagnostics });

    const extracted_root = diagnostics.root_dir;
    if (extracted_root.len == 0) return error.InvalidArchiveLayout;

    const extracted_path = try fs.join(allocator, &.{ tmp_base, extracted_root });
    defer allocator.free(extracted_path);

    try fs.ensureDeleted(io, sdk_path);
    try std.Io.Dir.renameAbsolute(extracted_path, sdk_path, io);
    try fs.deleteTreeIfExists(io, tmp_base);
}
