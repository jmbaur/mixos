const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const kmod_dep = b.dependency("kmod", .{});

    var kmod_cflags: std.ArrayList([]const u8) = .{};
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
    libkmod.addCSourceFiles(.{
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

    const kmod = b.addExecutable(.{
        .name = "kmod",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .link_libc = true,
        }),
    });
    kmod.root_module.addCSourceFiles(.{
        .root = kmod_dep.path(""),
        .flags = kmod_cflags.items,
        .files = &.{
            "tools/depmod.c",
            "tools/insmod.c",
            "tools/kmod.c",
            "tools/log.c",
            "tools/lsmod.c",
            "tools/modinfo.c",
            "tools/modprobe.c",
            "tools/opt.c",
            "tools/rmmod.c",
            "tools/static-nodes.c",
        },
    });
    kmod.root_module.addIncludePath(kmod_dep.path(""));
    kmod.root_module.addIncludePath(kmod_dep.path("tools"));
    kmod.root_module.linkLibrary(libkmod_shared);
    kmod.root_module.linkLibrary(libkmod);
    const kmod_install_artifact = b.addInstallArtifact(kmod, .{});
    b.getInstallStep().dependOn(&kmod_install_artifact.step);

    const kmod_symlinks = b.step("kmod-symlinks", "Create kmod symlinks");
    kmod_symlinks.dependOn(&kmod_install_artifact.step);
    b.getInstallStep().dependOn(kmod_symlinks);

    kmod_symlinks.makeFn = struct {
        const tools = [_][]const u8{ "depmod", "insmod", "lsmod", "modinfo", "modprobe", "rmmod" };

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const builder = step.owner;

            var exe_dir = try std.fs.cwd().openDir(builder.exe_dir, .{});
            defer exe_dir.close();

            for (tools) |tool| {
                while (true) {
                    exe_dir.symLink("kmod", tool, .{}) catch |err| switch (err) {
                        error.PathAlreadyExists => {
                            try exe_dir.deleteFile(tool);
                            continue;
                        },
                        else => return err,
                    };
                    break;
                }
            }
        }
    }.make;

    const mixos_rdinit_module = b.createModule(.{
        .root_source_file = b.path("src/rdinit.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = false,
    });

    const mixos_module = b.createModule(.{
        .root_source_file = b.path("src/mixos.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = true,
    });
    mixos_module.linkLibrary(libkmod);

    const mixos_rdinit = b.addExecutable(.{
        .name = "mixos-rdinit",
        .root_module = mixos_rdinit_module,
    });

    const install_rdinit = b.addInstallArtifact(mixos_rdinit, .{
        .dest_dir = .{ .override = .{ .custom = "libexec" } },
    });
    b.default_step.dependOn(&install_rdinit.step);

    const mixos = b.addExecutable(.{
        .name = "mixos",
        .root_module = mixos_module,
    });
    b.installArtifact(mixos);

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

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_module,
    });

    const run_exe_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
