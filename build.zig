const std = @import("std");
const varlink = @import("varlink");

const buildtools_dir: std.Build.InstallDir = .{ .custom = "buildtools" };

fn addLibkmod(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
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

    return libkmod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .musl,
            .cpu_model = .baseline,
            .os_tag = .linux,
        },
    });

    // Build tools are only ever run as part of building a system, so they are
    // always built for the build platform. They are statically linked against
    // musl so that they don't pick up a dependency on the build platform's
    // libc.
    const buildtools_target = b.resolveTargetQuery(.{
        .abi = .musl,
        .cpu_arch = b.graph.host.result.cpu.arch,
        .cpu_model = .baseline,
        .os_tag = b.graph.host.result.os.tag,
    });

    const optimize = b.standardOptimizeOption(.{});

    // used by nixpkgs' separateDebugInfo
    b.build_id = .sha1;

    const cpio_dep = b.dependency("cpio", .{});

    const clap_dep = b.dependency("clap", .{});

    const libmnl_dep = b.dependency("libmnl", .{});
    const libmnl = b.addLibrary(.{
        .name = "mnl",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    libmnl.root_module.addCSourceFiles(.{
        .root = libmnl_dep.path(""),
        .files = &.{ "src/socket.c", "src/callback.c", "src/nlmsg.c", "src/attr.c" },
    });
    libmnl.root_module.addConfigHeader(b.addConfigHeader(.{}, .{}));
    libmnl.root_module.addIncludePath(libmnl_dep.path("include"));
    libmnl.installHeadersDirectory(libmnl_dep.path("include"), "", .{});

    const libkmod = addLibkmod(b, target, optimize);

    const kconfig = b.addExecutable(.{
        .name = "kconfig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kconfig.zig"),
            .target = buildtools_target,
            .optimize = optimize,
        }),
    });
    kconfig.root_module.addImport("clap", clap_dep.module("clap"));
    b.getInstallStep().dependOn(&b.addInstallArtifact(kconfig, .{
        .dest_dir = .{ .override = buildtools_dir },
    }).step);

    const copy_modules_closure = b.addExecutable(.{
        .name = "copy-modules-closure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/copy-modules-closure.zig"),
            .target = buildtools_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    copy_modules_closure.root_module.addImport("clap", clap_dep.module("clap"));
    copy_modules_closure.root_module.linkLibrary(addLibkmod(b, buildtools_target, optimize));
    b.getInstallStep().dependOn(&b.addInstallArtifact(copy_modules_closure, .{
        .dest_dir = .{ .override = buildtools_dir },
    }).step);

    const varlink_dep = b.dependency("varlink", .{});

    const mixos_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false, // let stdenv strip hook do this for us, giving us debug info integration
        .link_libc = true,
    });
    mixos_module.addImport("clap", clap_dep.module("clap"));
    mixos_module.linkLibrary(libmnl);
    mixos_module.linkLibrary(libkmod);
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
    b.installArtifact(mixos);

    const mixos_runner = b.addExecutable(.{
        .name = "mixos-runner",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .root_source_file = b.path("src/runner.zig"),
        }),
    });
    mixos_runner.root_module.addImport("cpio", cpio_dep.module("cpio"));
    mixos_runner.root_module.addImport("clap", clap_dep.module("clap"));

    const runner_tool = b.addRunArtifact(mixos_runner);
    runner_tool.addArtifactArg(mixos);
    if (b.args) |args| {
        runner_tool.addArgs(args);
    }

    const run_step = b.step("run", "Run in qemu");
    run_step.dependOn(&runner_tool.step);

    const unit_tests_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_tests_module.addImport("clap", clap_dep.module("clap"));
    unit_tests_module.linkLibrary(libkmod);

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
