const std = @import("std");

pub const cli = @import("cli.zig");
pub const config = @import("config.zig");
pub const fs = @import("fs.zig");
pub const installer = @import("install.zig");
pub const official = @import("official.zig");
pub const platform = @import("platform.zig");
pub const switcher = @import("switch.zig");

pub const AppError = error{
    InvalidArguments,
    MissingRoot,
    UnsupportedPlatform,
    UnknownCommand,
    VersionNotFound,
    PackageNotFound,
    VersionNotInstalled,
    CurrentVersionMissing,
    CannotRemoveCurrentVersion,
    PathUpdateFailed,
};

pub const RootLayout = config.RootLayout;
pub const Platform = platform.Platform;

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
