//! The hardware watchdog, armed for the length of boot. It is pinged between
//! the steps of boot, so a step that hangs, or fails, gets the machine reset.

const linux = @import("linux.zig");
const std = @import("std");

const log = std.log.scoped(.mixos);

const Watchdog = @This();

inner: linux.Watchdog,

/// Arms the watchdog to go off after `timeout` seconds without a ping.
pub fn init(io: std.Io, timeout: u32) !Watchdog {
    var inner = try linux.Watchdog.init(io);
    errdefer inner.deinit(io);

    try inner.setOptions(.{ .enable_card = true });

    // Not fatal: the watchdog still goes off, just after however long the
    // driver was already set to.
    if (inner.setTimeout(timeout)) |actual| {
        if (actual != timeout) {
            log.warn("watchdog timeout set to {d}s rather than {d}s", .{ actual, timeout });
        }
    } else |err| {
        log.warn("failed to set the watchdog timeout to {d}s: {}", .{ timeout, err });
    }

    return .{ .inner = inner };
}

pub fn ping(self: *Watchdog) void {
    self.inner.keepAlive() catch |err| {
        log.warn("failed to ping the watchdog: {}", .{err});
        return;
    };
    log.debug("watchdog ping", .{});
}

/// Without `disarm`, the watchdog is left running with nothing to ping it, so
/// it goes off.
pub fn deinit(self: *Watchdog, io: std.Io, opts: struct { disarm: bool = true }) void {
    if (opts.disarm) {
        self.inner.deinit(io);
    }

    self.* = undefined;
}
