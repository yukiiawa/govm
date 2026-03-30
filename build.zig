const std = @import("std");

const release_targets = [_]struct {
    name: []const u8,
    query: std.Target.Query,
}{
    .{ .name = "windows-amd64", .query = .{ .os_tag = .windows, .cpu_arch = .x86_64 } },
    .{ .name = "windows-arm64", .query = .{ .os_tag = .windows, .cpu_arch = .aarch64 } },
    .{ .name = "linux-amd64", .query = .{ .os_tag = .linux, .cpu_arch = .x86_64 } },
    .{ .name = "linux-arm64", .query = .{ .os_tag = .linux, .cpu_arch = .aarch64 } },
    .{ .name = "linux-386", .query = .{ .os_tag = .linux, .cpu_arch = .x86 } },
    .{ .name = "darwin-amd64", .query = .{ .os_tag = .macos, .cpu_arch = .x86_64 } },
    .{ .name = "darwin-arm64", .query = .{ .os_tag = .macos, .cpu_arch = .aarch64 } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("govm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "govm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "govm", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run govm");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const release_step = b.step("release", "Build release binaries for the main target matrix");
    for (release_targets) |item| {
        const resolved = b.resolveTargetQuery(item.query);
        const rel_mod = b.addModule(b.fmt("govm-release-{s}", .{item.name}), .{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
        });
        const rel_exe = b.addExecutable(.{
            .name = "govm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "govm", .module = rel_mod },
                },
            }),
        });
        const install = b.addInstallArtifact(rel_exe, .{
            .dest_sub_path = b.fmt("release/{s}/{s}", .{ item.name, rel_exe.out_filename }),
        });
        release_step.dependOn(&install.step);
    }
}
