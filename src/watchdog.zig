const std = @import("std");
const system = std.os.linux;
const posix = std.posix;
const C = @cImport({
    @cInclude("linux/watchdog.h");
});

const log = std.log.scoped(.mixos);

const Watchdog = @This();

inner: std.Io.File,
epoll: posix.fd_t,
timer: posix.fd_t,
event: posix.fd_t,
thread: std.Thread,

const Outcome = enum { done, keep_going };

fn handleEvent(watchdog: posix.fd_t, timer: posix.fd_t, event: posix.fd_t) Outcome {
    _ = watchdog;
    _ = timer;

    var value: u64 = 0;
    _ = posix.read(event, std.mem.asBytes(&value)) catch {}; // consume event

    return .done;
}

fn handleTimer(watchdog: posix.fd_t, timer: posix.fd_t, event: posix.fd_t) Outcome {
    _ = event;

    _ = system.ioctl(watchdog, C.WDIOC_KEEPALIVE, 0);
    log.debug("watchdog ping", .{});

    var expirations: u64 = 0;
    _ = posix.read(timer, std.mem.asBytes(&expirations)) catch {}; // consume timer

    return .keep_going;
}

fn run(
    watchdog: posix.fd_t,
    epoll: posix.fd_t,
    timer: posix.fd_t,
    event: posix.fd_t,
) void {
    _ = system.ioctl(watchdog, C.WDIOC_SETOPTIONS, @intFromPtr(&C.WDIOS_ENABLECARD));

    var watchdog_timeout: u32 = 0;
    _ = system.ioctl(watchdog, C.WDIOC_GETTIMEOUT, @intFromPtr(&watchdog_timeout));

    const timer_timeout: isize = @intCast(std.math.clamp(watchdog_timeout, 10, 60) / 2);

    _ = system.timerfd_settime(
        timer,
        .{},
        &.{ .it_value = .{ .sec = timer_timeout, .nsec = 0 }, .it_interval = .{ .sec = timer_timeout, .nsec = 0 } },
        null,
    );

    _ = system.epoll_ctl(
        epoll,
        system.EPOLL.CTL_ADD,
        timer,
        @constCast(&system.epoll_event{
            .events = system.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(&handleTimer) },
        }),
    );

    _ = system.epoll_ctl(
        epoll,
        system.EPOLL.CTL_ADD,
        event,
        @constCast(&system.epoll_event{
            .events = system.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(&handleEvent) },
        }),
    );

    var events: [1]system.epoll_event = undefined;

    outer: while (true) {
        const num_events = system.epoll_wait(epoll, &events, events.len, -1);
        for (events[0..num_events]) |e| {
            const func: *const fn (posix.fd_t, posix.fd_t, posix.fd_t) Outcome = @ptrFromInt(e.data.ptr);
            switch (func(watchdog, timer, event)) {
                .keep_going => continue,
                .done => break :outer,
            }
        }
    }
}

pub fn init(io: std.Io) !Watchdog {
    const inner = try std.Io.Dir.cwd().openFile(io, "/dev/watchdog", .{ .mode = .read_write });
    errdefer inner.close(io);

    const epoll: posix.fd_t = @intCast(system.epoll_create1(system.EPOLL.CLOEXEC));
    errdefer _ = system.close(epoll);

    const timer: posix.fd_t = @intCast(system.timerfd_create(.BOOTTIME, .{ .CLOEXEC = true }));
    errdefer _ = system.close(timer);

    const event: posix.fd_t = @intCast(system.eventfd(0, system.EFD.CLOEXEC));
    errdefer _ = system.close(event);

    const thread = try std.Thread.spawn(.{}, run, .{
        inner.handle,
        epoll,
        timer,
        event,
    });

    return .{
        .inner = inner,
        .epoll = epoll,
        .timer = timer,
        .event = event,
        .thread = thread,
    };
}

pub fn disarm(self: *Watchdog, io: std.Io) void {
    _ = system.ioctl(self.inner.handle, C.WDIOC_SETOPTIONS, @intFromPtr(&C.WDIOS_DISABLECARD));
    self.inner.close(io);
    self.deinit();
}

/// Will trigger the watchdog since we stop pinging to it. To disarm the
/// watchdog, call disarm() instead.
pub fn deinit(self: *Watchdog) void {
    var value: u64 = 1;
    _ = system.write(self.event, std.mem.asBytes(&value), @sizeOf(@TypeOf(value)));
    self.thread.join();
    _ = system.close(self.epoll);
    _ = system.close(self.timer);
    _ = system.close(self.event);
    self.* = undefined;
}
