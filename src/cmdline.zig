const std = @import("std");

const C = @cImport({
    @cInclude("asm-generic/setup.h");
});

const log = std.log.scoped(.mixos);

pub const prefix = "mixos.";

pub const max_len = C.COMMAND_LINE_SIZE;

const kernel_cmdline_path = "/proc/cmdline";

fn find(contents: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;

    // NOTE: we do not handle quoting
    var entries = std.mem.tokenizeAny(u8, contents, &std.ascii.whitespace);
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, name)) {
            continue;
        }

        // Whatever follows the name decides whether this is the parameter at
        // all: an entry that merely starts with it ("mixos.debug_shell_x") is
        // a different parameter.
        const rest = entry[name.len..];
        if (rest.len == 0) {
            found = rest;
        } else if (rest[0] == '=') {
            found = rest[1..];
        }
    }

    return found;
}

test find {
    try std.testing.expectEqual(null, find("", "mixos.thing"));
    try std.testing.expectEqual(null, find("quiet ro", "mixos.thing"));
    try std.testing.expectEqual(null, find("mixos.thingy=1", "mixos.thing"));
    try std.testing.expectEqual(null, find("not.mixos.thing=1", "mixos.thing"));

    try std.testing.expectEqualStrings("", find("mixos.thing", "mixos.thing").?);
    try std.testing.expectEqualStrings("", find("quiet mixos.thing ro\n", "mixos.thing").?);
    try std.testing.expectEqualStrings("1", find("quiet mixos.thing=1 ro", "mixos.thing").?);
    try std.testing.expectEqualStrings("a=b", find("mixos.thing=a=b", "mixos.thing").?);

    // last one wins
    try std.testing.expectEqualStrings("2", find("mixos.thing=1 mixos.thing=2", "mixos.thing").?);
    try std.testing.expectEqualStrings("", find("mixos.thing=1 mixos.thing", "mixos.thing").?);
    try std.testing.expectEqualStrings("1", find("mixos.thing mixos.thing=1", "mixos.thing").?);
}

pub fn param(io: std.Io, name: []const u8, buf: []u8) ?[]const u8 {
    const contents = std.Io.Dir.cwd().readFile(io, kernel_cmdline_path, buf) catch |err| {
        log.warn("failed to read {s}: {}", .{ kernel_cmdline_path, err });
        return null;
    };

    return find(contents, name);
}
