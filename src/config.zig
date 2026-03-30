const std = @import("std");
const fs = @import("fs.zig");

pub const UserConfig = struct {
    root: []const u8,
};

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
    io: std.Io,
    env_map: *std.process.Environ.Map,
    cli_root: ?[]const u8,
) ![]u8 {
    if (cli_root) |root_path| return allocator.dupe(u8, root_path);
    if (env_map.get("GOVM_ROOT")) |root_path| return allocator.dupe(u8, root_path);
    if (try loadUserRoot(allocator, io, env_map)) |root_path| return root_path;
    return error.MissingRoot;
}

pub fn persistUserRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    root_path: []const u8,
) !void {
    const config_path = try userConfigPath(allocator, env_map);
    defer allocator.free(config_path);

    if (std.fs.path.dirname(config_path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(UserConfig{ .root = root_path }, .{}, &out.writer);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = config_path,
        .data = out.written(),
        .flags = .{ .truncate = true },
    });
}

fn loadUserRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
) !?[]u8 {
    const config_path = try userConfigPath(allocator, env_map);
    defer allocator.free(config_path);
    if (!fs.pathExists(io, config_path)) return null;

    const data = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, config_path, allocator, .unlimited);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(UserConfig, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return try allocator.dupe(u8, parsed.value.root);
}

fn userConfigPath(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]u8 {
    const home = try fs.homeDir(allocator, env_map);
    defer allocator.free(home);
    return fs.join(allocator, &.{ home, ".govm", "config.json" });
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

// 测试：当 CLI 参数和环境变量都缺失时，应加载已持久化的根目录
test "persisted root is loaded when cli and env are absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);

    try persistUserRoot(std.testing.allocator, std.testing.io, &env_map, "/tmp/govm-root");
    const resolved = try resolveRoot(std.testing.allocator, std.testing.io, &env_map, null);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/tmp/govm-root", resolved);
}

// 测试：CLI 指定的根目录优先级高于已持久化的根目录
test "cli root takes precedence over persisted root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);

    try persistUserRoot(std.testing.allocator, std.testing.io, &env_map, "/tmp/govm-root");
    const resolved = try resolveRoot(std.testing.allocator, std.testing.io, &env_map, "/tmp/cli-root");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/tmp/cli-root", resolved);
}

// 测试：环境变量指定的根目录优先级高于已持久化的根目录
test "env root takes precedence over persisted root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var env_map = std.process.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);
    try env_map.put("GOVM_ROOT", "/tmp/env-root");

    try persistUserRoot(std.testing.allocator, std.testing.io, &env_map, "/tmp/govm-root");
    const resolved = try resolveRoot(std.testing.allocator, std.testing.io, &env_map, null);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("/tmp/env-root", resolved);
}
