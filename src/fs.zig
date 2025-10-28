const std = @import("std");
const system = std.posix.system;

const log = std.log.scoped(.mixos);

fn mountOptionsToFlagsAndData() std.meta.Tuple(.{ u32, []const u8 }) {
    return .{};
}

pub fn mount(
    special: [*:0]const u8,
    dir: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: u32,
    data: usize,
    //options: []const []const u8,
) !void {
    switch (system.E.init(std.os.linux.mount(special, dir, fstype, flags, data))) {
        .SUCCESS => {},
        else => |err| {
            log.err("failed to mount \"{s}\" on \"{s}\": {s}", .{ special, dir, @tagName(err) });
            return std.posix.unexpectedErrno(err);
        },
    }
}
