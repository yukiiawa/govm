const std = @import("std");
const fs = @import("fs.zig");

pub const RootLayout = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    downloads_dir: []u8,
    sdks_dir: []u8,
    current_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !RootLayout {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root_path),
            .downloads_dir = try fs.join(allocator, &.{ root_path, "downloads" }),
            .sdks_dir = try fs.join(allocator, &.{ root_path, "sdks" }),
            .current_dir = try fs.join(allocator, &.{ root_path, "current" }),
        };
    }

    pub fn deinit(self: *RootLayout) void {
        self.allocator.free(self.root);
        self.allocator.free(self.downloads_dir);
        self.allocator.free(self.sdks_dir);
        self.allocator.free(self.current_dir);
        self.* = undefined;
    }

    pub fn ensureBaseDirs(self: RootLayout, io: std.Io) !void {
        try std.Io.Dir.cwd().createDirPath(io, self.root);
        try std.Io.Dir.cwd().createDirPath(io, self.downloads_dir);
        try std.Io.Dir.cwd().createDirPath(io, self.sdks_dir);
    }

    pub fn sdkDir(self: RootLayout, allocator: std.mem.Allocator, version: []const u8) ![]u8 {
        return fs.join(allocator, &.{ self.sdks_dir, version });
    }

    pub fn archivePath(self: RootLayout, allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
        return fs.join(allocator, &.{ self.downloads_dir, filename });
    }
};

pub fn resolveRoot(
    allocator: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    cli_root: ?[]const u8,
) ![]u8 {
    if (cli_root) |root_path| return allocator.dupe(u8, root_path);
    if (env_map.get("GOVM_ROOT")) |root_path| return allocator.dupe(u8, root_path);
    return error.MissingRoot;
}

pub fn listInstalledVersions(allocator: std.mem.Allocator, io: std.Io, layout: RootLayout) ![][]u8 {
    if (!fs.pathExists(io, layout.sdks_dir)) return allocator.alloc([]u8, 0);
    var dir = try std.Io.Dir.openDirAbsolute(io, layout.sdks_dir, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    var results: std.ArrayList([]u8) = .empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try results.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, results.items, {}, lessThanString);
    return try results.toOwnedSlice(allocator);
}

fn lessThanString(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
