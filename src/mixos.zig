const std = @import("std");
const sysinit = @import("./sysinit.zig");
const insmod = @import("./insmod.zig");
const modprobe = @import("./modprobe.zig");
const test_backdoor = @import("./test-backdoor.zig");

pub fn main() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse std.debug.panic("missing argv[0]", .{});

    var name = std.fs.path.basename(argv0);

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        if (i == 0 and std.mem.eql(u8, name, "mixos")) {
            name = args.next() orelse return error.MissingCommand;
            continue;
        } else if (std.mem.eql(u8, name, "sysinit")) {
            return sysinit.mixosMain(&args);
        } else if (std.mem.eql(u8, name, "insmod")) {
            return insmod.mixosMain(&args);
        } else if (std.mem.eql(u8, name, "modprobe")) {
            return modprobe.mixosMain(&args);
        } else if (std.mem.eql(u8, name, "test-backdoor")) {
            return test_backdoor.mixosMain(&args);
        } else {
            break;
        }
    }

    return error.UnknownCommand;
}
