const std = @import("std");

const KconfigSelection = union(enum) {
    unset,
    yes,
    no,
    module,
    // Anything that isn't a tristate, e.g. a string, number or hex value. The
    // value is stored exactly as it appeared in the kernel configuration.
    value: []const u8,

    pub fn dupe(self: KconfigSelection, allocator: std.mem.Allocator) !KconfigSelection {
        return switch (self) {
            .value => |value| .{ .value = try allocator.dupe(u8, value) },
            else => self,
        };
    }
};

const KconfigEntry = struct {
    name: []const u8,
    selection: KconfigSelection,

    pub fn format(self: *const KconfigEntry, writer: *std.Io.Writer) !void {
        switch (self.selection) {
            .unset => {
                try writer.print("# CONFIG_{s} is not set", .{self.name});
            },
            .yes => {
                try writer.print("CONFIG_{s}=y", .{self.name});
            },
            .no => {
                try writer.print("CONFIG_{s}=n", .{self.name});
            },
            .module => {
                try writer.print("CONFIG_{s}=m", .{self.name});
            },
            .value => |value| {
                try writer.print("CONFIG_{s}={s}", .{ self.name, value });
            },
        }
    }
};

// String values are quoted in the kernel configuration, however it is more
// ergonomic to make assertions using unquoted values, so quoting is ignored on
// both sides of a comparison.
fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }

    return value;
}

test unquote {
    try std.testing.expectEqualStrings("", unquote(""));
    try std.testing.expectEqualStrings("\"", unquote("\""));
    try std.testing.expectEqualStrings("", unquote("\"\""));
    try std.testing.expectEqualStrings("foo", unquote("foo"));
    try std.testing.expectEqualStrings("foo", unquote("\"foo\""));
    try std.testing.expectEqualStrings("\"foo", unquote("\"foo"));
}

fn parseKconfigLine(line: []const u8) !?KconfigEntry {
    var config_split = std.mem.splitSequence(u8, line, "CONFIG_");
    const first = config_split.next() orelse return null;
    if (std.mem.startsWith(u8, first, "#")) {
        // determine if the config entry is unset
        var whitespace_split = std.mem.splitSequence(u8, config_split.rest(), " ");
        const name = whitespace_split.next() orelse return null;
        if (!std.mem.eql(u8, whitespace_split.rest(), "is not set")) {
            return null;
        }
        return .{
            .name = name,
            .selection = .unset,
        };
    }

    // Only split on the first '=', since values may contain '=' themselves.
    const rest = config_split.rest();
    const eq_index = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const name = rest[0..eq_index];
    const val = rest[eq_index + 1 ..];
    if (name.len == 0) {
        return null;
    }

    if (std.mem.eql(u8, val, "y")) {
        return .{
            .name = name,
            .selection = .yes,
        };
    }

    if (std.mem.eql(u8, val, "n")) {
        return .{
            .name = name,
            .selection = .no,
        };
    }

    if (std.mem.eql(u8, val, "m")) {
        return .{
            .name = name,
            .selection = .module,
        };
    }

    return .{
        .name = name,
        .selection = .{ .value = val },
    };
}

test parseKconfigLine {
    try std.testing.expectEqual(null, try parseKconfigLine(""));
    try std.testing.expectEqual(null, try parseKconfigLine("# some comment"));
    try std.testing.expectEqual(null, try parseKconfigLine("CONFIG_FOO"));
    try std.testing.expectEqual(null, try parseKconfigLine("CONFIG_=y"));

    {
        const entry = (try parseKconfigLine("# CONFIG_FOO is not set")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqual(.unset, entry.selection);
    }

    {
        const entry = (try parseKconfigLine("CONFIG_FOO=y")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqual(.yes, entry.selection);
    }

    {
        const entry = (try parseKconfigLine("CONFIG_FOO=m")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqual(.module, entry.selection);
    }

    {
        const entry = (try parseKconfigLine("CONFIG_FOO=n")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqual(.no, entry.selection);
    }

    {
        const entry = (try parseKconfigLine("CONFIG_FOO=1234")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqualStrings("1234", entry.selection.value);
    }

    {
        const entry = (try parseKconfigLine("CONFIG_FOO=0xdeadbeef")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqualStrings("0xdeadbeef", entry.selection.value);
    }

    {
        // values are allowed to contain '=' and the "CONFIG_" prefix
        const entry = (try parseKconfigLine("CONFIG_FOO=\"console=ttyS0 CONFIG_BAR\"")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqualStrings("\"console=ttyS0 CONFIG_BAR\"", entry.selection.value);
    }

    {
        const entry = (try parseKconfigLine("CONFIG_FOO=\"\"")) orelse unreachable;
        try std.testing.expectEqualStrings("FOO", entry.name);
        try std.testing.expectEqualStrings("\"\"", entry.selection.value);
    }
}

const Kconfig = std.StringHashMapUnmanaged(KconfigSelection);

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args = init.minimal.args.iterate();
    defer args.deinit();

    if (!args.skip()) {
        return error.InvalidArguments;
    }

    const kconfig_filepath = args.next() orelse return error.InvalidArguments;

    var kconfig_file = try std.Io.Dir.cwd().openFile(init.io, kconfig_filepath, .{});
    defer kconfig_file.close(init.io);

    var buf: [1024]u8 = undefined;
    var kconfig_file_reader = kconfig_file.reader(init.io, &buf);
    var reader = &kconfig_file_reader.interface;

    var kconfig: Kconfig = .empty;

    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        reader.toss(1);
        if (std.mem.eql(u8, line, "")) {
            continue;
        }
        if (try parseKconfigLine(line)) |entry| {
            // the entry points into the reader's buffer, so it needs to be
            // copied before the next line is read
            try kconfig.put(
                allocator,
                try allocator.dupe(u8, entry.name),
                try entry.selection.dupe(allocator),
            );
        }
    }

    var assertion_failed = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--assert-yes")) {
            const name = args.next() orelse return error.InvalidArguments;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            if (selection != .yes) {
                std.log.err("CONFIG_{s} is not yes", .{name});
                assertion_failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--assert-yes-or-module")) {
            const name = args.next() orelse return error.InvalidArguments;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            if (selection != .yes and selection != .module) {
                std.log.err("CONFIG_{s} is not yes or module", .{name});
                assertion_failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--assert-no")) {
            const name = args.next() orelse return error.InvalidArguments;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            if (selection != .no) {
                std.log.err("CONFIG_{s} is not no", .{name});
                assertion_failed = true;
            }
        } else if (std.mem.eql(u8, arg, "--assert-value")) {
            const name = args.next() orelse return error.InvalidArguments;
            const expected = args.next() orelse return error.InvalidArguments;
            const selection = kconfig.get(name) orelse return error.MissingKconfigEntry;
            switch (selection) {
                .value => |actual| if (!std.mem.eql(u8, unquote(actual), unquote(expected))) {
                    std.log.err("CONFIG_{s} is {s}, not {s}", .{ name, actual, expected });
                    assertion_failed = true;
                },
                else => {
                    std.log.err("CONFIG_{s} is not {s}", .{ name, expected });
                    assertion_failed = true;
                },
            }
        } else if (std.mem.eql(u8, arg, "--assert-unset")) {
            const name = args.next() orelse return error.InvalidArguments;
            const selection = kconfig.get(name) orelse continue; // consider entries not present to be unset
            if (selection != .unset) {
                std.log.err("CONFIG_{s} is not unset", .{name});
                assertion_failed = true;
            }
        } else {
            return error.InvalidArguments;
        }
    }

    if (assertion_failed) {
        return error.KconfigAssertionFailed;
    }
}
