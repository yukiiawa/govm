const std = @import("std");

pub const Parsed = struct {
    root: ?[]const u8 = null,
    command: Command,
};

pub const ListOptions = struct {
    installed_only: bool = false,
    stable_only: bool = false,
    reverse: bool = false,
    head: ?usize = null,
    tail: ?usize = null,
};

pub const Command = union(enum) {
    list: ListOptions,
    install: []const u8,
    use: []const u8,
    current,
    which,
    remove: []const u8,
    help,
};

pub fn parse(args: []const []const u8) !Parsed {
    if (args.len <= 1) return .{ .command = .help };

    var index: usize = 1;
    var root_path: ?[]const u8 = null;
    while (index < args.len and std.mem.startsWith(u8, args[index], "--")) {
        if (std.mem.eql(u8, args[index], "--root")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            root_path = args[index];
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, args[index], "--help")) {
            return .{ .root = root_path, .command = .help };
        }
        return error.InvalidArguments;
    }

    if (index >= args.len) return .{ .root = root_path, .command = .help };

    const name = args[index];
    index += 1;

    if (std.mem.eql(u8, name, "list")) {
        var installed_only = false;
        var stable_only = false;
        var reverse = false;
        var head: ?usize = null;
        var tail: ?usize = null;
        while (index < args.len) {
            if (std.mem.eql(u8, args[index], "--installed")) {
                installed_only = true;
            } else if (std.mem.eql(u8, args[index], "--stable-only")) {
                stable_only = true;
            } else if (std.mem.eql(u8, args[index], "--reverse")) {
                reverse = true;
            } else if (std.mem.eql(u8, args[index], "--tail")) {
                index += 1;
                if (index >= args.len) return error.InvalidArguments;
                tail = std.fmt.parseInt(usize, args[index], 10) catch return error.InvalidArguments;
            } else if (std.mem.eql(u8, args[index], "--head")) {
                index += 1;
                if (index >= args.len) return error.InvalidArguments;
                head = std.fmt.parseInt(usize, args[index], 10) catch return error.InvalidArguments;
            } else return error.InvalidArguments;
            index += 1;
        }
        if (head != null and tail != null) return error.InvalidArguments;
        return .{ .root = root_path, .command = .{ .list = .{
            .installed_only = installed_only,
            .stable_only = stable_only,
            .reverse = reverse,
            .head = head,
            .tail = tail,
        } } };
    }

    if (std.mem.eql(u8, name, "install")) {
        if (index + 1 != args.len) return error.InvalidArguments;
        return .{ .root = root_path, .command = .{ .install = args[index] } };
    }
    if (std.mem.eql(u8, name, "use")) {
        if (index + 1 != args.len) return error.InvalidArguments;
        return .{ .root = root_path, .command = .{ .use = args[index] } };
    }
    if (std.mem.eql(u8, name, "remove")) {
        if (index + 1 != args.len) return error.InvalidArguments;
        return .{ .root = root_path, .command = .{ .remove = args[index] } };
    }
    if (std.mem.eql(u8, name, "current")) {
        if (index != args.len) return error.InvalidArguments;
        return .{ .root = root_path, .command = .current };
    }
    if (std.mem.eql(u8, name, "which")) {
        if (index != args.len) return error.InvalidArguments;
        return .{ .root = root_path, .command = .which };
    }
    if (std.mem.eql(u8, name, "help")) {
        return .{ .root = root_path, .command = .help };
    }

    return error.UnknownCommand;
}

pub fn usage() []const u8 {
    return
        \\govm - Go version manager built with Zig
        \\
        \\Usage:
        \\  govm [--root <path>] list [--installed] [--stable-only] [--head N|--tail N] [--reverse]
        \\  govm [--root <path>] install <version>
        \\  govm [--root <path>] use <version>
        \\  govm [--root <path>] current
        \\  govm [--root <path>] which
        \\  govm [--root <path>] remove <version>
        \\
        \\Root Resolution:
        \\  1. --root <path>   Uses and saves the root for future runs.
        \\  2. GOVM_ROOT       Overrides the saved root when set.
        \\  3. ~/.govm/config.json
        \\
    ;
}

// 测试：解析 install 命令及其 --root 参数
test "parse install" {
    const parsed = try parse(&.{ "govm", "--root", "/tmp/govm", "install", "go1.23.0" });
    try std.testing.expectEqualStrings("/tmp/govm", parsed.root.?);
    try std.testing.expectEqualStrings("go1.23.0", parsed.command.install);
}

// 测试：解析 list 命令的各种标志位（--stable-only, --tail, --reverse）
test "parse list flags" {
    const parsed = try parse(&.{ "govm", "list", "--stable-only", "--tail", "20", "--reverse" });
    try std.testing.expect(parsed.command.list.stable_only);
    try std.testing.expect(parsed.command.list.reverse);
    try std.testing.expectEqual(@as(?usize, 20), parsed.command.list.tail);
}

// 测试：list 命令拒绝同时使用 --head 和 --tail 参数
test "parse list rejects head tail combination" {
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "govm", "list", "--tail", "5", "--head", "2" }));
}
