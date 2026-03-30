const std = @import("std");
const builtin = @import("builtin");

pub const ArchiveKind = enum {
    tar_gz,
    zip,
};

pub const Platform = struct {
    goos: []const u8,
    goarch: []const u8,
    archive_kind: ArchiveKind,
    exe_name: []const u8,
};

pub fn detect() !Platform {
    return fromTarget(builtin.target) orelse error.UnsupportedPlatform;
}

pub fn fromTarget(target: std.Target) ?Platform {
    const goos = switch (target.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "darwin",
        .freebsd => "freebsd",
        else => return null,
    };

    const goarch = switch (target.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .x86 => "386",
        else => return null,
    };

    return .{
        .goos = goos,
        .goarch = goarch,
        .archive_kind = if (target.os.tag == .windows) .zip else .tar_gz,
        .exe_name = if (target.os.tag == .windows) "go.exe" else "go",
    };
}

test "map windows amd64" {
    const query = std.Target.Query{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    };
    const resolved = std.zig.system.resolveTargetQuery(query) catch unreachable;
    const mapped = fromTarget(resolved.result) orelse unreachable;
    try std.testing.expectEqualStrings("windows", mapped.goos);
    try std.testing.expectEqualStrings("amd64", mapped.goarch);
    try std.testing.expectEqual(.zip, mapped.archive_kind);
}
