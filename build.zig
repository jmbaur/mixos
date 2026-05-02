const std = @import("std");
const varlink = @import("varlink");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .musl,
            .cpu_model = .baseline,
        },
    });

    const optimize = b.standardOptimizeOption(.{});

    const kmod_dep = b.dependency("kmod", .{});

    var kmod_cflags: std.ArrayList([]const u8) = .empty;
    defer kmod_cflags.deinit(b.allocator);
    kmod_cflags.appendSlice(b.allocator, &.{
        "-DENABLE_LOGGING",
        "-DENABLE_DEBUG=0",
        "-DENABLE_ELFDBG=0",
        "-DMODULE_DIRECTORY=\"/lib/modules\"",
        "-DSYSCONFDIR=\"/etc\"",
        "-DDISTCONFDIR=\"/etc\"",
        "-DKMOD_FEATURES=\"\"",
        "-DPACKAGE=\"kmod\"",
        "-DVERSION=\"34.2\"",
        "-D_GNU_SOURCE",
        "-DHAVE_DECL_STRNDUPA",
        "-DHAVE_DECL_BE32TOH",
        "-DHAVE_OPEN64",
        "-DHAVE_STAT64",
        "-DHAVE_FOPEN64",
        "-DHAVE___STAT64_TIME64",
        "-DHAVE_SECURE_GETENV",
        "-DHAVE___BUILTIN_CLZ",
        "-DHAVE___BUILTIN_TYPES_COMPATIBLE_P",
        "-DHAVE___BUILTIN_UADD_OVERFLOW",
        "-DHAVE___BUILTIN_UADDL_OVERFLOW",
        "-DHAVE___BUILTBIN_UADDLL_OVERFLOW",
        "-DHAVE___BUILTIN_UMUL_OVERFLOW",
        "-DHAVE___BUILTIN_UMULL_OVERFLOW",
        "-DHAVE___BUILTIN_UMULLL_OVERFLOW",
    }) catch @panic("OOM");

    if (target.result.isMuslLibC()) {
        kmod_cflags.appendSlice(b.allocator, &.{"-DHAVE_DECL_BASENAME=0"}) catch @panic("OOM");
    } else {
        kmod_cflags.appendSlice(b.allocator, &.{"-DHAVE_DECL_BASENAME=1"}) catch @panic("OOM");
    }

    const libkmod_shared = b.addLibrary(.{
        .name = "kmod-shared",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    libkmod_shared.root_module.addIncludePath(kmod_dep.path(""));
    libkmod_shared.installHeadersDirectory(kmod_dep.path("shared"), "shared", .{});
    libkmod_shared.root_module.addCSourceFiles(.{
        .root = kmod_dep.path(""),
        .flags = kmod_cflags.items,
        .files = &.{
            "shared/array.c",
            "shared/hash.c",
            "shared/strbuf.c",
            "shared/util.c",
        },
    });

    const libkmod = b.addLibrary(.{
        .name = "kmod",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    libkmod.root_module.addCSourceFiles(.{
        .root = kmod_dep.path(""),
        .flags = kmod_cflags.items,
        .files = &.{
            "libkmod/libkmod-builtin.c",
            "libkmod/libkmod-config.c",
            "libkmod/libkmod-elf.c",
            "libkmod/libkmod-file.c",
            "libkmod/libkmod-index.c",
            "libkmod/libkmod-list.c",
            "libkmod/libkmod-module.c",
            "libkmod/libkmod-signature.c",
            "libkmod/libkmod.c",
        },
    });
    libkmod.root_module.addIncludePath(kmod_dep.path(""));
    libkmod.root_module.linkLibrary(libkmod_shared);
    libkmod.root_module.addIncludePath(kmod_dep.path("libkmod"));
    libkmod.installHeader(kmod_dep.path("libkmod/libkmod.h"), "libkmod/libkmod.h");

    const kmod_log_wrapper = b.addLibrary(.{
        .name = "kmod-log-wrapper",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .link_libc = true,
        }),
    });
    kmod_log_wrapper.root_module.addCSourceFile(.{
        .file = b.path("src/kmod-log-wrapper.c"),
    });
    kmod_log_wrapper.installHeader(b.path("src/kmod-log-wrapper.h"), "kmod-log-wrapper.h");

    const varlink_dep = b.dependency("varlink", .{});

    const mixos_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = true,
    });
    mixos_module.linkLibrary(libkmod);
    mixos_module.linkLibrary(kmod_log_wrapper);
    mixos_module.addImport("varlink", varlink_dep.module("varlink"));
    mixos_module.addImport(
        "mixos_varlink",
        varlink.scanFile(
            b,
            varlink_dep,
            b.path("com.jmbaur.mixos.varlink"),
            "com-jmbaur-mixos.zig",
        ),
    );

    const mixos = b.addExecutable(.{
        .name = "mixos",
        .root_module = mixos_module,
    });

    const mixos_install_artifact = b.addInstallArtifact(mixos, .{});
    b.getInstallStep().dependOn(&mixos_install_artifact.step);

    const run_cmd = b.addRunArtifact(mixos);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addArg("test-backdoor");
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the mixos test backdoor");
    run_step.dependOn(&run_cmd.step);

    const unit_tests_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests_module.linkLibrary(libkmod);
    unit_tests_module.linkLibrary(kmod_log_wrapper);

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
