const std = @import("std");
const fs = @import("fs.zig");
const root = @import("root.zig");

pub const RootLayout = struct {
    allocator: std.mem.Allocator,
    root: []u8,
    downloads_dir: []u8,
    sdks_dir: []u8,
    current_dir: []u8,
    state_path: []u8,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !RootLayout {
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root_path),
            .downloads_dir = try fs.join(allocator, &.{ root_path, "downloads" }),
            .sdks_dir = try fs.join(allocator, &.{ root_path, "sdks" }),
            .current_dir = try fs.join(allocator, &.{ root_path, "current" }),
            .state_path = try fs.join(allocator, &.{ root_path, "state.json" }),
        };
    }

    pub fn deinit(self: *RootLayout) void {
        self.allocator.free(self.root);
        self.allocator.free(self.downloads_dir);
        self.allocator.free(self.sdks_dir);
        self.allocator.free(self.current_dir);
        self.allocator.free(self.state_path);
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

pub fn loadState(allocator: std.mem.Allocator, io: std.Io, layout: RootLayout) !root.State {
    if (!fs.pathExists(io, layout.state_path)) return .{};
    const data = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, layout.state_path, allocator, .unlimited);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(root.State, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var state: root.State = .{};
    if (parsed.value.current_version) |version| {
        state.current_version = try allocator.dupe(u8, version);
    }
    return state;
}

pub fn saveState(allocator: std.mem.Allocator, io: std.Io, layout: RootLayout, state: root.State) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(state, .{}, &out.writer);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = layout.state_path,
        .data = out.written(),
        .flags = .{ .truncate = true },
    });
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

test "state round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    var layout = try RootLayout.init(std.testing.allocator, root_path);
    defer layout.deinit();
    try layout.ensureBaseDirs(std.testing.io);
    try saveState(std.testing.allocator, std.testing.io, layout, .{ .current_version = "go1.22.0" });
    const loaded = try loadState(std.testing.allocator, std.testing.io, layout);
    defer if (loaded.current_version) |v| std.testing.allocator.free(v);
    try std.testing.expectEqualStrings("go1.22.0", loaded.current_version.?);
}
