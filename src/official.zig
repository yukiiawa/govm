const std = @import("std");
const platform_mod = @import("platform.zig");

pub const index_url = "https://go.dev/dl/?mode=json&include=all";

pub const File = struct {
    filename: []const u8,
    os: []const u8,
    arch: []const u8,
    version: []const u8,
    sha256: []const u8,
    kind: []const u8,
    size: u64,
};

pub const Release = struct {
    version: []const u8,
    stable: bool = false,
    files: []File,
};

pub fn fetchReleases(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed([]Release) {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = index_url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return error.BadServerResponse;

    return std.json.parseFromSlice([]Release, allocator, body.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn findRelease(releases: []const Release, version: []const u8) ?Release {
    for (releases) |release| {
        if (std.mem.eql(u8, release.version, version)) return release;
    }
    return null;
}

pub fn selectPackage(release: Release, platform: platform_mod.Platform) ?File {
    var fallback: ?File = null;
    for (release.files) |file| {
        if (!std.mem.eql(u8, file.os, platform.goos)) continue;
        if (!std.mem.eql(u8, file.arch, platform.goarch)) continue;

        if (platform.archive_kind == .zip and std.mem.eql(u8, file.kind, "archive") and std.mem.endsWith(u8, file.filename, ".zip")) {
            return file;
        }
        if (platform.archive_kind == .tar_gz and std.mem.eql(u8, file.kind, "archive") and std.mem.endsWith(u8, file.filename, ".tar.gz")) {
            return file;
        }
        if (std.mem.eql(u8, file.kind, "archive")) fallback = file;
    }
    return fallback;
}

pub fn parseReleasesFromSlice(allocator: std.mem.Allocator, data: []const u8) !std.json.Parsed([]Release) {
    return std.json.parseFromSlice([]Release, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "parse and select package" {
    const fixture =
        \\[
        \\  {
        \\    "version": "go1.23.0",
        \\    "stable": true,
        \\    "files": [
        \\      {"filename":"go1.23.0.windows-amd64.zip","os":"windows","arch":"amd64","version":"go1.23.0","sha256":"abc","kind":"archive","size":1},
        \\      {"filename":"go1.23.0.linux-amd64.tar.gz","os":"linux","arch":"amd64","version":"go1.23.0","sha256":"def","kind":"archive","size":1}
        \\    ]
        \\  }
        \\]
    ;
    const parsed = try parseReleasesFromSlice(std.testing.allocator, fixture);
    defer parsed.deinit();
    const release = findRelease(parsed.value, "go1.23.0") orelse unreachable;
    const pkg = selectPackage(release, .{
        .goos = "windows",
        .goarch = "amd64",
        .archive_kind = .zip,
        .exe_name = "go.exe",
    }) orelse unreachable;
    try std.testing.expectEqualStrings("go1.23.0.windows-amd64.zip", pkg.filename);
}
