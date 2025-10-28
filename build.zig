const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const mixos_init_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/rdinit.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    const mixos_exe = b.createModule(.{
        .root_source_file = b.path("src/mixos.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mixos_rdinit = b.addExecutable(.{
        .name = "mixos-rdinit",
        .root_module = mixos_init_exe_mod,
    });

    const install_rdinit = b.addInstallArtifact(mixos_rdinit, .{
        .dest_dir = .{ .override = .{ .custom = "libexec" } },
    });
    b.default_step.dependOn(&install_rdinit.step);

    const mixos = b.addExecutable(.{
        .name = "mixos",
        .root_module = mixos_exe,
    });
    mixos.linkLibC(); // for syslog() and friends

    b.installArtifact(mixos);

    const run_cmd = b.addRunArtifact(mixos);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addArg("test-backdoor");
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the mixos test backdoor");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
