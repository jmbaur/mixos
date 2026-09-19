const std = @import("std");
const clap = @import("clap");
const syslog = @import("syslog.zig");
const Kmod = @import("kmod.zig");

const log = std.log.scoped(.mixos);

const params = clap.parseParamsComptime(
    \\-h, --help   Display this help and exit.
    \\-q, --quiet  Accepted and ignored. The kernel passes this when it asks
    \\             for a module itself.
    \\<module>...  Modules to load, by name or alias.
    \\
);

const parsers = .{ .module = clap.parsers.string };

pub fn main(init: std.process.Init, name: []const u8, args: *std.process.Args.Iterator) anyerror!void {
    syslog.init(name);
    defer syslog.deinit();

    // The kernel calls this as `modprobe -q -- <alias>`, see
    // https://github.com/torvalds/linux/blob/4ae12d8bd9a830799db335ee661d6cbc6597f838/kernel/module/kmod.c#L92
    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, parsers, args, .{
        .diagnostic = &diag,
        .allocator = init.arena.allocator(),
    }) catch |err| {
        diag.reportToFile(init.io, .stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});
    }

    var kmod = try Kmod.init(init.io, .{});
    defer kmod.deinit();

    for (res.positionals[0]) |module| {
        kmod.modprobe(module) catch |err| {
            log.err("module load for '{s}' failed: {}", .{ module, err });
        };
    }
}
