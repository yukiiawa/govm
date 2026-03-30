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

/// Removes a symlink (Unix) or junction reparse point (Windows) at `path`
/// without following it into the target. Safe when `path` does not exist,
/// including dangling junctions whose target has already been removed.
///
/// Returns an error if `path` is a real non-empty directory; use
/// `deleteTreeIfExists` for that case instead.
pub fn deleteLink(io: std.Io, path: []const u8) !void {
    if (@import("builtin").os.tag == .windows) {
        // RemoveDirectory on a junction removes only the reparse point itself,
        // never the target directory or its contents. This also works for
        // dangling junctions where the target path no longer exists.
        std.Io.Dir.deleteDirAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            // DirNotEmpty means this is a real directory, not a junction.
            // Propagate the error rather than silently deleting real data.
            error.DirNotEmpty => return err,
            else => {
                // Could be a file symlink; try unlink as a fallback.
                std.Io.Dir.deleteFileAbsolute(io, path) catch |e| switch (e) {
                    error.FileNotFound => {},
                    else => return err,
                };
            },
        };
    } else {
        // unlink(2) removes the directory entry for the symlink without
        // following it, so the target directory and its contents are untouched.
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

test "path contains entry" {
    try std.testing.expect(pathContainsEntry("a:b:c", "b"));
    try std.testing.expect(!pathContainsEntry("a:b:c", "d"));
}
