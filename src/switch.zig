const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("config.zig");
const fs = @import("fs.zig");

pub fn useVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    layout: cfg.RootLayout,
    version: []const u8,
) !void {
    const sdk_path = try layout.sdkDir(allocator, version);
    defer allocator.free(sdk_path);
    if (!fs.pathExists(io, sdk_path)) return error.VersionNotInstalled;

    try updateCurrentLink(io, layout.current_dir, sdk_path);

    const bin_path = try fs.join(allocator, &.{ layout.current_dir, "bin" });
    defer allocator.free(bin_path);

    try ensurePersistentGovmPath(allocator, io, env_map, bin_path);
    try syncPersistentGoroot(allocator, io, env_map, layout.current_dir);
}

pub fn currentSdkPath(allocator: std.mem.Allocator, io: std.Io, current_dir: []const u8) ![]u8 {
    if (!fs.pathExists(io, current_dir)) return error.CurrentVersionMissing;
    return std.Io.Dir.realPathFileAbsoluteAlloc(io, current_dir, allocator);
}

pub fn currentGoBinary(allocator: std.mem.Allocator, io: std.Io, current_dir: []const u8) ![]u8 {
    const sdk_path = try currentSdkPath(allocator, io, current_dir);
    defer allocator.free(sdk_path);
    return fs.join(allocator, &.{ sdk_path, "bin", fs.exeName() });
}

pub fn currentTargetsSdk(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_dir: []const u8,
    sdk_path: []const u8,
) !bool {
    if (!fs.pathExists(io, current_dir)) return false;
    if (!fs.pathExists(io, sdk_path)) return false;

    const current_real = std.Io.Dir.realPathFileAbsoluteAlloc(io, current_dir, allocator) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(current_real);

    const sdk_real = std.Io.Dir.realPathFileAbsoluteAlloc(io, sdk_path, allocator) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(sdk_real);

    return std.mem.eql(u8, current_real, sdk_real);
}

pub fn syncPersistentGoroot(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    current_dir: []const u8,
) !void {
    if (builtin.os.tag == .windows) {
        try setWindowsUserEnvVar(allocator, io, "GOROOT", current_dir);
        return;
    }

    const home = try fs.homeDir(allocator, env_map);
    defer allocator.free(home);

    const posix_line = try std.fmt.allocPrint(allocator, "export GOROOT=\"{s}\"", .{current_dir});
    defer allocator.free(posix_line);
    const fish_line = try std.fmt.allocPrint(allocator, "set -x GOROOT '{s}'", .{current_dir});
    defer allocator.free(fish_line);

    try ensureShellLines(allocator, io, home, posix_line, fish_line);
}

fn ensurePersistentGovmPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    bin_path: []const u8,
) !void {
    if (builtin.os.tag == .windows) {
        if (try windowsEnvVarContains(allocator, io, "Path", "User", bin_path)) return;
        if (try windowsEnvVarContains(allocator, io, "Path", "Machine", bin_path)) return;

        const existing = try windowsGetEnvVar(allocator, io, "Path", "User");
        defer allocator.free(existing);

        const updated = try fs.appendPathEntry(allocator, std.mem.trim(u8, existing, " \r\n\t"), bin_path);
        defer allocator.free(updated);

        try setWindowsUserEnvVar(allocator, io, "Path", updated);
        return;
    }

    const home = try fs.homeDir(allocator, env_map);
    defer allocator.free(home);

    const posix_line = try std.fmt.allocPrint(allocator, "export PATH=\"{s}:$PATH\"", .{bin_path});
    defer allocator.free(posix_line);

    const fish_line = try std.fmt.allocPrint(allocator, "fish_add_path '{s}'", .{bin_path});
    defer allocator.free(fish_line);

    try ensureShellLines(allocator, io, home, posix_line, fish_line);
}

const ShellKind = enum { posix, fish };

const CandidateShell = struct {
    suffix: []const u8,
    kind: ShellKind,
};

const candidate_shells = [_]CandidateShell{
    .{ .suffix = ".profile", .kind = .posix },
    .{ .suffix = ".bashrc", .kind = .posix },
    .{ .suffix = ".bash_profile", .kind = .posix },
    .{ .suffix = ".zshrc", .kind = .posix },
    .{ .suffix = ".zprofile", .kind = .posix },
    .{ .suffix = ".config/fish/config.fish", .kind = .fish },
};

fn ensureShellLines(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    posix_line: []const u8,
    fish_line: []const u8,
) !void {
    var any_found = false;

    for (candidate_shells) |shell| {
        const file_path = try fs.join(allocator, &.{ home, shell.suffix });
        defer allocator.free(file_path);
        if (!fs.pathExists(io, file_path)) continue;

        any_found = true;
        const line = switch (shell.kind) {
            .posix => posix_line,
            .fish => fish_line,
        };

        const existing = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, file_path, allocator, .unlimited);
        defer allocator.free(existing);
        if (std.mem.indexOf(u8, existing, line) != null) continue;

        // Ensure we start a new line before the comment.
        const sep: []const u8 = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
        const new_content = try std.fmt.allocPrint(
            allocator,
            "{s}{s}# Added by govm\n{s}\n",
            .{ existing, sep, line },
        );
        defer allocator.free(new_content);

        try writeFileAtomic(allocator, io, file_path, new_content);
    }

    if (any_found) return;

    const profile_path = try fs.join(allocator, &.{ home, ".profile" });
    defer allocator.free(profile_path);

    var existing: []u8 = &.{};
    if (fs.pathExists(io, profile_path)) {
        existing = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, profile_path, allocator, .unlimited);
        if (std.mem.indexOf(u8, existing, posix_line) != null) {
            allocator.free(existing);
            return;
        }
    }
    defer if (existing.len > 0) allocator.free(existing);

    const sep: []const u8 = if (existing.len == 0 or existing[existing.len - 1] == '\n') "" else "\n";
    const new_content = try std.fmt.allocPrint(
        allocator,
        "{s}{s}# Added by govm\n{s}\n",
        .{ existing, sep, posix_line },
    );
    defer allocator.free(new_content);

    try writeFileAtomic(allocator, io, profile_path, new_content);
}

fn writeFileAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.govm.tmp", .{path});
    defer allocator.free(tmp_path);
    // Clean up the temp file if anything goes wrong after it is created.
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = tmp_path,
        .data = content,
        .flags = .{ .truncate = true },
    });
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

fn windowsEnvVarContains(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    target: []const u8,
    needle: []const u8,
) !bool {
    const value = try windowsGetEnvVar(allocator, io, name, target);
    defer allocator.free(value);
    return fs.pathContainsEntry(std.mem.trim(u8, value, " \r\n\t"), needle);
}

fn windowsGetEnvVar(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    target: []const u8,
) ![]u8 {
    const escaped_name = try windowsPsQuote(allocator, name);
    defer allocator.free(escaped_name);
    const escaped_target = try windowsPsQuote(allocator, target);
    defer allocator.free(escaped_target);
    const command = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference = 'Stop'; [Environment]::GetEnvironmentVariable('{s}', '{s}')",
        .{ escaped_name, escaped_target },
    );
    defer allocator.free(command);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "powershell",
            "-NoProfile",
            "-Command",
            command,
        },
        .stderr_limit = .unlimited,
        .stdout_limit = .unlimited,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return error.PathUpdateFailed,
        else => return error.PathUpdateFailed,
    }
    return allocator.dupe(u8, result.stdout);
}

fn updateCurrentLink(io: std.Io, current_dir: []const u8, sdk_path: []const u8) !void {
    try fs.deleteLink(io, current_dir);
    if (builtin.os.tag == .windows) {
        try createWindowsJunction(std.heap.page_allocator, io, current_dir, sdk_path);
    } else {
        try std.Io.Dir.symLinkAbsolute(io, sdk_path, current_dir, .{ .is_directory = true });
    }
}

fn createWindowsJunction(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_dir: []const u8,
    sdk_path: []const u8,
) !void {
    const escaped_link = try windowsPsQuote(allocator, current_dir);
    defer allocator.free(escaped_link);
    const escaped_target = try windowsPsQuote(allocator, sdk_path);
    defer allocator.free(escaped_target);

    const command = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path '{s}' -Target '{s}' | Out-Null",
        .{ escaped_link, escaped_target },
    );
    defer allocator.free(command);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "powershell", "-NoProfile", "-Command", command },
        .stderr_limit = .unlimited,
        .stdout_limit = .unlimited,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PathUpdateFailed,
        else => return error.PathUpdateFailed,
    }
}

fn setWindowsUserEnvVar(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    value: []const u8,
) !void {
    const escaped_name = try windowsPsQuote(allocator, name);
    defer allocator.free(escaped_name);
    const escaped_value = try windowsPsQuote(allocator, value);
    defer allocator.free(escaped_value);
    const command = try std.fmt.allocPrint(
        allocator,
        "$ErrorActionPreference = 'Stop'; [Environment]::SetEnvironmentVariable('{s}', '{s}', 'User')",
        .{ escaped_name, escaped_value },
    );
    defer allocator.free(command);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "powershell",
            "-NoProfile",
            "-Command",
            command,
        },
        .stderr_limit = .unlimited,
        .stdout_limit = .unlimited,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PathUpdateFailed,
        else => return error.PathUpdateFailed,
    }
}

fn windowsPsQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, value, "'", "''");
}

test "current go binary path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    const current_dir = try fs.join(std.testing.allocator, &.{ root_path, "current" });
    defer std.testing.allocator.free(current_dir);
    const sdk_path = try fs.join(std.testing.allocator, &.{ root_path, "sdks", "go1.26.1" });
    defer std.testing.allocator.free(sdk_path);
    const expected = try fs.join(std.testing.allocator, &.{ sdk_path, "bin", fs.exeName() });
    defer std.testing.allocator.free(expected);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, sdk_path);
    try updateCurrentLink(std.testing.io, current_dir, sdk_path);

    const path = try currentGoBinary(std.testing.allocator, std.testing.io, current_dir);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(expected, path);
}

test "current target sdk matches active link" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    const current_dir = try fs.join(std.testing.allocator, &.{ root_path, "current" });
    defer std.testing.allocator.free(current_dir);
    const sdk_a = try fs.join(std.testing.allocator, &.{ root_path, "sdks", "go1.26.1" });
    defer std.testing.allocator.free(sdk_a);
    const sdk_b = try fs.join(std.testing.allocator, &.{ root_path, "sdks", "go1.26.2" });
    defer std.testing.allocator.free(sdk_b);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, sdk_a);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, sdk_b);
    try updateCurrentLink(std.testing.io, current_dir, sdk_a);

    try std.testing.expect(try currentTargetsSdk(std.testing.allocator, std.testing.io, current_dir, sdk_a));
    try std.testing.expect(!try currentTargetsSdk(std.testing.allocator, std.testing.io, current_dir, sdk_b));
}
