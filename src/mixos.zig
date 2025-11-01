const std = @import("std");
const sysinit = @import("./sysinit.zig");
const modprobe = @import("./modprobe.zig");
const test_backdoor = @import("./test-backdoor.zig");

pub fn main() !void {
    var args = std.process.args();
    const argv0 = args.next() orelse std.debug.panic("missing argv[0]", .{});

    var name = std.fs.path.basename(argv0);

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        if (std.mem.eql(u8, name, "mixos")) {
            name = args.next() orelse return error.MissingArgs;
            continue;
        } else if (std.mem.eql(u8, name, "sysinit")) {
            return sysinit.mixosMain(&args);
        } else if (std.mem.eql(u8, name, "modprobe")) {
            return modprobe.mixosMain(&args);
        } else if (std.mem.eql(u8, name, "test-backdoor")) {
            return test_backdoor.mixosMain(&args);
        } else {
            return error.InvalidArgs;
        }
    }
}
