const std = @import("std");

pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn ensureDeleted(io: std.Io, path: []const u8) !void {
    if (!pathExists(io, path)) return;
    std.Io.Dir.deleteDirAbsolute(io, path) catch |dir_err| switch (dir_err) {
        error.NotDir => try std.Io.Dir.deleteFileAbsolute(io, path),
        error.DirNotEmpty => try std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, path),
        error.FileNotFound => {},
        else => |err| {
            std.Io.Dir.deleteFileAbsolute(io, path) catch |file_err| switch (file_err) {
                error.FileNotFound => {},
                else => return err,
            };
        },
    };
}

pub fn deleteLink(io: std.Io, path: []const u8) !void {
    if (@import("builtin").os.tag == .windows) {
        std.Io.Dir.deleteDirAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            error.DirNotEmpty => return err,
            else => {
                std.Io.Dir.deleteFileAbsolute(io, path) catch |e| switch (e) {
                    error.FileNotFound => {},
                    else => return err,
                };
            },
        };
    } else {
        std.Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

pub fn deleteTreeIfExists(io: std.Io, path: []const u8) !void {
    if (!pathExists(io, path)) return;
    try std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, path);
}

pub fn homeDir(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) ![]u8 {
    if (env_map.get("HOME")) |value| return allocator.dupe(u8, value);
    if (env_map.get("USERPROFILE")) |value| return allocator.dupe(u8, value);
    return error.EnvironmentVariableNotFound;
}

pub fn exeName() []const u8 {
    return if (@import("builtin").os.tag == .windows) "go.exe" else "go";
}

pub fn pathContainsEntry(path_value: []const u8, needle: []const u8) bool {
    const delimiter: u8 = if (@import("builtin").os.tag == .windows) ';' else ':';
    var iter = std.mem.splitScalar(u8, path_value, delimiter);
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, std.mem.trim(u8, segment, " "), needle)) return true;
    }
    return false;
}

pub fn appendPathEntry(allocator: std.mem.Allocator, path_value: []const u8, needle: []const u8) ![]u8 {
    if (pathContainsEntry(path_value, needle)) return allocator.dupe(u8, path_value);
    const delimiter: []const u8 = if (@import("builtin").os.tag == .windows) ";" else ":";
    if (path_value.len == 0) return allocator.dupe(u8, needle);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ path_value, delimiter, needle });
}

// 测试：验证路径字符串是否包含特定的条目（支持 Windows ';' 和 POSIX ':' 分隔符）
test "path contains entry" {
    try std.testing.expect(pathContainsEntry("a:b:c", "b"));
    try std.testing.expect(!pathContainsEntry("a:b:c", "d"));
}
