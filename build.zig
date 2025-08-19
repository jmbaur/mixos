const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const mixos_init_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/rdinit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mixos_test_backdoor_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/test-backdoor.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mixos_init = b.addExecutable(.{
        .name = "mixos-rdinit",
        .root_module = mixos_init_exe_mod,
    });

    const mixos_test_backdoor = b.addExecutable(.{
        .name = "mixos-test-backdoor",
        .root_module = mixos_test_backdoor_exe_mod,
    });

    b.installArtifact(mixos_init);
    b.installArtifact(mixos_test_backdoor);

    const run_cmd = b.addRunArtifact(mixos_test_backdoor);

    run_cmd.step.dependOn(b.getInstallStep());

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
