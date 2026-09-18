const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const cpio = @import("cpio");

const params = clap.parseParamsComptime(
    \\-h, --help    Display this help and exit.
    \\<executable>  The mixos executable to boot as init. Anything after it is
    \\              handed to qemu as it stands.
    \\
);

const parsers = .{ .executable = clap.parsers.string };

pub fn main(init: std.process.Init) !void {
    const arena_alloc = init.arena.allocator();

    var args = init.minimal.args.iterate();
    if (!args.skip()) {
        return error.InvalidArguments;
    }

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, parsers, &args, .{
        .diagnostic = &diag,
        .allocator = arena_alloc,
        // Stop at the executable, so that everything after it is left in the
        // iterator to be handed to qemu with its own flags intact.
        .terminating_positional = 0,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    const mixos_executable = res.positionals[0] orelse {
        try clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
        return error.InvalidArguments;
    };

    const kernel = init.environ_map.get("MIXOS_KERNEL") orelse return error.InvalidArguments;
    const initial_initrd = init.environ_map.get("MIXOS_INITRD") orelse return error.InvalidArguments;

    var tmpdir = try std.Io.Dir.cwd().openDir(init.io, "/tmp", .{});
    defer tmpdir.close(init.io);

    {
        try std.Io.Dir.cwd().copyFile(initial_initrd, tmpdir, "mixos.initrd", init.io, .{
            .permissions = .fromMode(0o644),
            .make_path = true,
            .replace = true,
        });

        var initrd_file = try tmpdir.openFile(init.io, "mixos.initrd", .{ .mode = .write_only });
        defer initrd_file.close(init.io);

        var init_file = try std.Io.Dir.cwd().openFile(init.io, mixos_executable, .{});
        defer init_file.close(init.io);

        const init_file_stat = try init_file.stat(init.io);
        if (init_file_stat.size > std.math.maxInt(u32)) {
            return error.FileTooLarge;
        }

        var buf: [1024]u8 = undefined;
        var initrd_writer = initrd_file.writer(init.io, &buf);
        const stat = try initrd_file.stat(init.io);
        try initrd_writer.seekTo(stat.size);
        var concat_archive = try cpio.init(&initrd_writer.interface);
        try concat_archive.addFile(
            init.io,
            "init",
            init_file,
            @intCast(init_file_stat.size),
            .fromMode(0o755),
        );

        try concat_archive.finalize();
    }

    var qemu_args: std.ArrayList([]const u8) = .empty;

    try qemu_args.append(arena_alloc, switch (builtin.target.cpu.arch) {
        .aarch64 => "qemu-system-aarch64",
        .arm => "qemu-system-arm",
        .x86_64 => "qemu-system-x86_64",
        else => return error.UnknownArchitecture,
    });

    const dev_kvm_exists = if (std.Io.Dir.cwd().access(
        init.io,
        "/dev/kvm",
        .{},
    )) true else |_| false;

    if (builtin.target.os.tag == .linux and dev_kvm_exists) {
        try qemu_args.append(arena_alloc, "-enable-kvm");
    }

    try qemu_args.appendSlice(arena_alloc, &.{ "-machine", switch (builtin.target.cpu.arch) {
        .aarch64, .arm => "virt",
        .x86_64 => "q35",
        else => return error.UnknownArchitecture,
    } });

    try qemu_args.appendSlice(arena_alloc, &.{
        "-display", "none",
        "-serial",  "mon:stdio",
        "-cpu",     "max",
        "-smp",     "1",
        "-m",       "1G",
        "-device",  "i6300esb",
        "-initrd",  try tmpdir.realPathFileAlloc(init.io, "mixos.initrd", arena_alloc),
        "-kernel",  kernel,
    });

    var cmdline: std.ArrayList(u8) = .empty;
    try cmdline.appendSlice(arena_alloc, "debug");
    if (builtin.target.cpu.arch == .x86_64) {
        try cmdline.appendSlice(arena_alloc, " console=ttyS0,115200");
    }

    try qemu_args.appendSlice(arena_alloc, &.{ "-append", cmdline.items });

    while (args.next()) |arg| {
        try qemu_args.append(arena_alloc, arg);
    }

    var qemu_child = try init.io.vtable.processSpawn(init.io.userdata, .{
        .argv = try qemu_args.toOwnedSlice(arena_alloc),
    });
    _ = try qemu_child.wait(init.io);
}
