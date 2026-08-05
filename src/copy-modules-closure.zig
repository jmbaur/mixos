const std = @import("std");
const Kmod = @import("kmod.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args = init.minimal.args.iterate();
    if (!args.skip()) {
        return error.InvalidArguments;
    }

    const module_root = args.next() orelse return error.InvalidArguments;

    const out = args.next() orelse return error.InvalidArguments;

    var kmod = try Kmod.init(.{ .root = module_root });
    defer kmod.deinit();

    var module_root_dir = try std.Io.Dir.cwd().openDir(init.io, module_root, .{});
    defer module_root_dir.close(init.io);

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, out, .{});
    defer out_dir.close(init.io);

    while (args.next()) |module_query| {
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
