const std = @import("std");
const clap = @import("clap");
const Kmod = @import("kmod.zig");

const params = clap.parseParamsComptime(
    \\-h, --help   Display this help and exit.
    \\<root>       The modules tree to take the closure out of.
    \\<out>        The directory to copy the closure into.
    \\<module>...  Modules to copy, by name or alias.
    \\
);

const parsers = .{
    .root = clap.parsers.string,
    .out = clap.parsers.string,
    .module = clap.parsers.string,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    const module_root = res.positionals[0] orelse {
        try clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
        return error.InvalidArguments;
    };

    const out = res.positionals[1] orelse {
        try clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});
        return error.InvalidArguments;
    };

    var kmod = try Kmod.init(.{ .root = module_root });
    defer kmod.deinit();

    var module_root_dir = try std.Io.Dir.cwd().openDir(init.io, module_root, .{});
    defer module_root_dir.close(init.io);

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out, .{});
    defer out_dir.close(init.io);

    for (res.positionals[2]) |module_query| {
        var closure = try kmod.moduleClosure(allocator, module_query);
        defer closure.deinit(allocator);

        var iter = closure.iterator();
        while (iter.next()) |module| {
            defer allocator.free(module.key_ptr.*);

            if (std.mem.cutPrefix(u8, module.key_ptr.*, module_root)) |module_path| {
                const relative_module_path = std.mem.trimStart(u8, module_path, std.fs.path.sep_str);

                std.log.info("copying module {s}", .{relative_module_path});

                try module_root_dir.copyFile(relative_module_path, out_dir, relative_module_path, init.io, .{
                    .make_path = true,
                    .replace = true,
                });
            }
        }
    }
}
