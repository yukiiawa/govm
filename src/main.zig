const std = @import("std");
const Io = std.Io;
const govm = @import("govm");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stdout = &stdout_file_writer.interface;
    const stderr = &stderr_file_writer.interface;

    const parsed = govm.cli.parse(args) catch |err| {
        try stderr.print("error: {s}\n\n{s}", .{ @errorName(err), govm.cli.usage() });
        try stderr.flush();
        return err;
    };

    switch (parsed.command) {
        .help => {
            try stdout.print("{s}", .{govm.cli.usage()});
            try stdout.flush();
            return;
        },
        else => {},
    }

    const root_path = govm.config.resolveRoot(allocator, init.environ_map, parsed.root) catch |err| {
        try stderr.print("error: {s}\nUse --root <path> or set GOVM_ROOT.\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };
    defer allocator.free(root_path);

    var layout = try govm.config.RootLayout.init(allocator, root_path);
    defer layout.deinit();

    switch (parsed.command) {
        .list => |cmd| try handleList(allocator, io, stdout, layout, cmd),
        .install => |version| try handleInstall(allocator, io, stdout, layout, version),
        .use => |version| try handleUse(allocator, io, stdout, stderr, init.environ_map, layout, version),
        .current => try handleCurrent(allocator, io, stdout, layout),
        .which => try handleWhich(allocator, stdout, layout),
        .remove => |version| try handleRemove(allocator, io, stdout, layout, version),
        .help => unreachable,
    }

    try stdout.flush();
}

fn handleList(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Io.Writer,
    layout: govm.RootLayout,
    options: govm.cli.ListOptions,
) !void {
    if (options.installed_only) {
        const installed = try govm.config.listInstalledVersions(allocator, io, layout);
        defer {
            for (installed) |item| allocator.free(item);
            allocator.free(installed);
        }
        const selected = selectInstalled(installed, options);
        const width = maxInstalledWidth(selected);

        if (options.reverse) {
            var idx = selected.len;
            while (idx > 0) {
                idx -= 1;
                try printTwoColumn(stdout, selected[idx], width, "");
            }
        } else for (selected) |version| {
            try printTwoColumn(stdout, version, width, "");
        }
        return;
    }

    const platform = try govm.platform.detect();
    const releases = try govm.official.fetchReleases(allocator, io);
    defer releases.deinit();
    std.mem.sort(govm.official.Release, releases.value, {}, lessThanReleaseVersion);

    var filtered: std.ArrayList(govm.official.Release) = .empty;
    defer filtered.deinit(allocator);

    for (releases.value) |release| {
        if (options.stable_only and !release.stable) continue;
        try filtered.append(allocator, release);
    }

    const selected = selectReleases(filtered.items, options);
    const width = maxReleaseWidth(selected);

    if (options.reverse) {
        var idx = selected.len;
        while (idx > 0) {
            idx -= 1;
            const release = selected[idx];
            const pkg = govm.official.selectPackage(release, platform);
            try printTwoColumn(
                stdout,
                release.version,
                width,
                if (pkg != null) "available" else "unavailable",
            );
        }
    } else for (selected) |release| {
        const pkg = govm.official.selectPackage(release, platform);
        try printTwoColumn(
            stdout,
            release.version,
            width,
            if (pkg != null) "available" else "unavailable",
        );
    }
}

fn selectInstalled(installed: [][]u8, options: govm.cli.ListOptions) [][]u8 {
    const total = installed.len;
    if (options.head) |count| {
        return installed[0..@min(total, count)];
    }
    const latest_count = options.latest orelse total;
    const slice_start = total -| @min(total, latest_count);
    return installed[slice_start..];
}

fn selectReleases(releases: []govm.official.Release, options: govm.cli.ListOptions) []govm.official.Release {
    const total = releases.len;
    if (options.head) |count| {
        return releases[0..@min(total, count)];
    }
    const latest_count = options.latest orelse total;
    const slice_start = total -| @min(total, latest_count);
    return releases[slice_start..];
}

fn printTwoColumn(stdout: *Io.Writer, left: []const u8, width: usize, right: []const u8) !void {
    try stdout.print("{s}", .{left});
    const padding = if (width > left.len) width - left.len else 0;
    if (padding > 0) try stdout.splatByteAll(' ', padding);
    if (right.len > 0) {
        try stdout.print("  {s}\n", .{right});
    } else {
        try stdout.print("\n", .{});
    }
}

fn maxInstalledWidth(installed: [][]u8) usize {
    var width: usize = 0;
    for (installed) |version| {
        width = @max(width, version.len);
    }
    return width;
}

fn maxReleaseWidth(releases: []const govm.official.Release) usize {
    var width: usize = 0;
    for (releases) |release| {
        width = @max(width, release.version.len);
    }
    return width;
}

fn lessThanReleaseVersion(_: void, lhs: govm.official.Release, rhs: govm.official.Release) bool {
    return compareGoVersion(lhs.version, rhs.version) == .lt;
}

const Order = enum { lt, eq, gt };
const PreKind = enum(u8) { beta = 0, rc = 1, none = 2 };

const GoVersion = struct {
    major: u32,
    minor: u32 = 0,
    patch: ?u32 = null,
    pre_kind: PreKind = .none,
    pre_num: u32 = 0,
};

fn compareGoVersion(lhs_text: []const u8, rhs_text: []const u8) Order {
    const lhs = parseGoVersion(lhs_text) orelse return compareLex(lhs_text, rhs_text);
    const rhs = parseGoVersion(rhs_text) orelse return compareLex(lhs_text, rhs_text);

    if (lhs.major != rhs.major) return orderFromInt(lhs.major, rhs.major);
    if (lhs.minor != rhs.minor) return orderFromInt(lhs.minor, rhs.minor);

    const lhs_patch = lhs.patch orelse 0;
    const rhs_patch = rhs.patch orelse 0;
    if (lhs_patch != rhs_patch) return orderFromInt(lhs_patch, rhs_patch);

    if (lhs.pre_kind != rhs.pre_kind) {
        return orderFromInt(@intFromEnum(lhs.pre_kind), @intFromEnum(rhs.pre_kind));
    }
    if (lhs.pre_num != rhs.pre_num) return orderFromInt(lhs.pre_num, rhs.pre_num);
    return .eq;
}

fn parseGoVersion(text: []const u8) ?GoVersion {
    if (!std.mem.startsWith(u8, text, "go")) return null;
    var rest = text[2..];
    var version = GoVersion{
        .major = parseLeadingNumber(&rest) orelse return null,
    };

    if (rest.len == 0) return version;
    if (rest[0] != '.') return parsePre(&version, rest);
    rest = rest[1..];
    version.minor = parseLeadingNumber(&rest) orelse return null;

    if (rest.len == 0) return version;
    if (rest[0] == '.') {
        rest = rest[1..];
        version.patch = parseLeadingNumber(&rest) orelse return null;
    }

    if (rest.len == 0) return version;
    return parsePre(&version, rest);
}

fn parsePre(version: *GoVersion, suffix: []const u8) ?GoVersion {
    if (std.mem.startsWith(u8, suffix, "beta")) {
        version.pre_kind = .beta;
        version.pre_num = parseUnsigned(suffix["beta".len..]) orelse return null;
        return version.*;
    }
    if (std.mem.startsWith(u8, suffix, "rc")) {
        version.pre_kind = .rc;
        version.pre_num = parseUnsigned(suffix["rc".len..]) orelse return null;
        return version.*;
    }
    return null;
}

fn parseLeadingNumber(rest: *[]const u8) ?u32 {
    var idx: usize = 0;
    while (idx < rest.*.len and std.ascii.isDigit(rest.*[idx])) : (idx += 1) {}
    if (idx == 0) return null;
    const value = parseUnsigned(rest.*[0..idx]) orelse return null;
    rest.* = rest.*[idx..];
    return value;
}

fn parseUnsigned(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 10) catch null;
}

fn orderFromInt(lhs: anytype, rhs: @TypeOf(lhs)) Order {
    if (lhs < rhs) return .lt;
    if (lhs > rhs) return .gt;
    return .eq;
}

fn compareLex(lhs: []const u8, rhs: []const u8) Order {
    if (std.mem.lessThan(u8, lhs, rhs)) return .lt;
    if (std.mem.eql(u8, lhs, rhs)) return .eq;
    return .gt;
}

test "compare go versions ascending" {
    try std.testing.expect(compareGoVersion("go1.9", "go1.10") == .lt);
    try std.testing.expect(compareGoVersion("go1.10rc1", "go1.10") == .lt);
    try std.testing.expect(compareGoVersion("go1.10beta1", "go1.10rc1") == .lt);
    try std.testing.expect(compareGoVersion("go1.10", "go1.10.1") == .lt);
    try std.testing.expect(compareGoVersion("go1.26rc3", "go1.26.0") == .lt);
}

fn handleInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Io.Writer,
    layout: govm.RootLayout,
    version: []const u8,
) !void {
    const normalized_version = try normalizeVersionArg(allocator, version);
    defer allocator.free(normalized_version);

    const platform = try govm.platform.detect();
    const releases = try govm.official.fetchReleases(allocator, io);
    defer releases.deinit();

    const release = govm.official.findRelease(releases.value, normalized_version) orelse return error.VersionNotFound;
    const package = govm.official.selectPackage(release, platform) orelse return error.PackageNotFound;
    try govm.installer.installVersion(allocator, io, layout, platform, package);
    try stdout.print("installed {s}\n", .{normalized_version});
}

fn handleUse(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
    env_map: *std.process.Environ.Map,
    layout: govm.RootLayout,
    version: []const u8,
) !void {
    const normalized_version = try normalizeVersionArg(allocator, version);
    defer allocator.free(normalized_version);

    govm.switcher.useVersion(allocator, io, env_map, layout, normalized_version) catch |err| switch (err) {
        error.PathUpdateFailed => {
            try stderr.print("warning: switched govm current version, but failed to sync PATH/GOROOT.\n", .{});
        },
        else => return err,
    };
    try stdout.print("using {s}\n", .{normalized_version});
    if (@import("builtin").os.tag == .windows) {
        try stdout.print("note: newly opened terminals will see the updated PATH; the current shell process will not be changed in-place.\n", .{});
    }
}

fn handleCurrent(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Io.Writer,
    layout: govm.RootLayout,
) !void {
    const state = try govm.config.loadState(allocator, io, layout);
    defer if (state.current_version) |value| allocator.free(value);
    const version = state.current_version orelse return error.CurrentVersionMissing;
    const sdk_path = try layout.sdkDir(allocator, version);
    defer allocator.free(sdk_path);
    try stdout.print("{s}\t{s}\n", .{ version, sdk_path });
}

fn handleWhich(
    allocator: std.mem.Allocator,
    stdout: *Io.Writer,
    layout: govm.RootLayout,
) !void {
    const go_binary = try govm.switcher.currentGoBinary(allocator, layout.current_dir);
    defer allocator.free(go_binary);
    try stdout.print("{s}\n", .{go_binary});
}

fn handleRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *Io.Writer,
    layout: govm.RootLayout,
    version: []const u8,
) !void {
    const normalized_version = try normalizeVersionArg(allocator, version);
    defer allocator.free(normalized_version);
    const sdk_path = try layout.sdkDir(allocator, normalized_version);
    defer allocator.free(sdk_path);

    const state = try govm.config.loadState(allocator, io, layout);
    defer if (state.current_version) |value| allocator.free(value);
    if (state.current_version) |current| {
        if (std.mem.eql(u8, current, normalized_version)) return error.CannotRemoveCurrentVersion;
    }
    if (try govm.switcher.currentTargetsSdk(allocator, io, layout.current_dir, sdk_path)) {
        return error.CannotRemoveCurrentVersion;
    }
    try govm.installer.removeVersion(io, layout, normalized_version);
    try stdout.print("removed {s}\n", .{normalized_version});
}

fn normalizeVersionArg(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const normalized = if (std.mem.startsWith(u8, version, "go"))
        try allocator.dupe(u8, version)
    else
        try std.fmt.allocPrint(allocator, "go{s}", .{version});
    errdefer allocator.free(normalized);

    if (parseGoVersion(normalized) == null) return error.InvalidArguments;
    if (std.mem.indexOfScalar(u8, normalized, std.fs.path.sep) != null) return error.InvalidArguments;
    if (std.fs.path.sep != std.fs.path.sep_posix and std.mem.indexOfScalar(u8, normalized, std.fs.path.sep_posix) != null) {
        return error.InvalidArguments;
    }
    if (std.mem.indexOf(u8, normalized, "..") != null) return error.InvalidArguments;
    return normalized;
}

test "normalize version arg" {
    const with_prefix = try normalizeVersionArg(std.testing.allocator, "go1.26.1");
    defer std.testing.allocator.free(with_prefix);
    try std.testing.expectEqualStrings("go1.26.1", with_prefix);

    const without_prefix = try normalizeVersionArg(std.testing.allocator, "1.26.1");
    defer std.testing.allocator.free(without_prefix);
    try std.testing.expectEqualStrings("go1.26.1", without_prefix);
}

test "normalize version arg rejects invalid input" {
    try std.testing.expectError(error.InvalidArguments, normalizeVersionArg(std.testing.allocator, "..\\evil"));
    try std.testing.expectError(error.InvalidArguments, normalizeVersionArg(std.testing.allocator, "1.26.1/../../oops"));
    try std.testing.expectError(error.InvalidArguments, normalizeVersionArg(std.testing.allocator, "not-a-go-version"));
}
