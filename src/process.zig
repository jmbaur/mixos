const posix = std.posix;
const std = @import("std");
const system = std.os.linux;

const log = std.log.scoped(.mixos);

pub fn statusToTerm(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .Exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .Signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .Stopped = posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

fn pidfd_open(pid: posix.pid_t, flags: u32) !posix.fd_t {
    const ret = system.pidfd_open(pid, flags);
    if (ret < 0) {
        return switch (system.E.init(ret)) {
            .INVAL => error.UnsupportedFlags,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOMEM => error.OutOfMemory,
            .SRCH => error.ProcessNotFound,
            else => |err| posix.unexpectedErrno(err),
        };
    } else {
        return @intCast(ret);
    }
}

fn runChild(
    initZ: [:0]const u8,
    envp: [:null]?[*:0]u8,
    errfd: posix.fd_t,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
    stderr: posix.fd_t,
) noreturn {
    const err = child: {
        posix.dup2(stdin, posix.STDIN_FILENO) catch |err| break :child err;
        posix.dup2(stdout, posix.STDOUT_FILENO) catch |err| break :child err;
        posix.dup2(stderr, posix.STDERR_FILENO) catch |err| break :child err;

        break :child std.posix.execvpeZ(initZ, &.{initZ}, envp);
    };

    const err_int = @intFromError(err);
    var err_buf: [@sizeOf(@TypeOf(err_int))]u8 = undefined;
    std.mem.writeInt(@TypeOf(err_int), &err_buf, err_int, .little);
    _ = std.posix.write(errfd, &err_buf) catch {};
    std.posix.exit(1);
}

// TODO(jared): remove with zig 0.16.0
const CLD = enum(i32) {
    EXITED = 1,
    KILLED = 2,
    DUMPED = 3,
    TRAPPED = 4,
    STOPPED = 5,
    CONTINUED = 6,
    _,
};

fn handlePid(
    pidfd: posix.fd_t,
    timerfd: posix.fd_t,
    errfd: posix.fd_t,
    outputfd: posix.fd_t,
    output_buffer: []u8,
    output_writer: *std.Io.Writer,
) anyerror!?std.process.Child.Term {
    _ = errfd;
    _ = timerfd;
    _ = outputfd;
    _ = output_buffer;
    _ = output_writer;

    var siginfo: system.siginfo_t = undefined;

    switch (system.E.init(system.waitid(.PIDFD, pidfd, &siginfo, system.W.EXITED))) {
        .SUCCESS => {},
        .CHILD => return error.NoChildProcess,
        .INTR => return null,
        .INVAL => return error.InvalidArguments,
        else => |err| return posix.unexpectedErrno(err),
    }

    const status: u32 = @bitCast(siginfo.fields.common.second.sigchld.status);
    const code: CLD = @enumFromInt(siginfo.code);
    return switch (code) {
        .EXITED => .{ .Exited = @truncate(status) },
        .KILLED, .DUMPED => .{ .Signal = status },
        .TRAPPED, .STOPPED => .{ .Stopped = status },
        _, .CONTINUED => .{ .Unknown = status },
    };
}

fn handleError(
    pidfd: posix.fd_t,
    timerfd: posix.fd_t,
    errfd: posix.fd_t,
    outputfd: posix.fd_t,
    output_buffer: []u8,
    output_writer: *std.Io.Writer,
) anyerror!?std.process.Child.Term {
    _ = pidfd;
    _ = timerfd;
    _ = outputfd;
    _ = output_buffer;
    _ = output_writer;

    const T = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

    var err_buf: [@sizeOf(T)]u8 = undefined;
    _ = try posix.read(errfd, &err_buf);

    const err_int = std.mem.readInt(T, &err_buf, .little);
    const err = @errorFromInt(err_int);
    return err;
}

fn handleOutput(
    pidfd: posix.fd_t,
    timerfd: posix.fd_t,
    errfd: posix.fd_t,
    outputfd: posix.fd_t,
    output_buffer: []u8,
    output_writer: *std.Io.Writer,
) anyerror!?std.process.Child.Term {
    _ = pidfd;
    _ = timerfd;
    _ = errfd;

    const n = try posix.read(outputfd, output_buffer[0..]);
    if (n == 0) {
        return error.EndOfStream;
    }

    try output_writer.writeAll(output_buffer[0..n]);
    try output_writer.flush();

    return null;
}

fn handleTimeout(
    pidfd: posix.fd_t,
    timerfd: posix.fd_t,
    errfd: posix.fd_t,
    outputfd: posix.fd_t,
    output_buffer: []u8,
    output_writer: *std.Io.Writer,
) anyerror!?std.process.Child.Term {
    _ = pidfd;
    _ = errfd;
    _ = outputfd;
    _ = output_buffer;
    _ = output_writer;

    var elapsed: u64 = 0;
    _ = try posix.read(timerfd, std.mem.asBytes(&elapsed));

    return error.Timeout;
}

pub fn run(
    allocator: std.mem.Allocator,
    executable: []const u8,
    output_writer: *std.Io.Writer,
    timeout: ?isize,
) !std.process.Child.Term {
    const epoll = try posix.epoll_create1(0);
    defer posix.close(epoll);

    const initZ = try allocator.dupeZ(u8, executable);
    defer allocator.free(initZ);

    const envp = try std.process.createEnvironFromExisting(
        allocator,
        @ptrCast(std.os.environ.ptr),
        .{},
    );

    const dev_null = try std.fs.cwd().openFile("/dev/null", .{});
    defer dev_null.close();

    const output_pipe = try std.posix.pipe();
    defer {
        std.posix.close(output_pipe[0]);
    }
    const err_pipe = try std.posix.pipe();
    defer {
        std.posix.close(err_pipe[0]);
        std.posix.close(err_pipe[1]);
    }

    const timerfd = try posix.timerfd_create(.BOOTTIME, .{ .CLOEXEC = true });
    defer posix.close(timerfd);

    switch (try std.posix.fork()) {
        0 => runChild(
            initZ,
            envp,
            err_pipe[1],
            dev_null.handle,
            output_pipe[1],
            output_pipe[1],
        ),
        else => |pid| {
            const pidfd = try pidfd_open(pid, 0);

            try posix.epoll_ctl(
                epoll,
                system.EPOLL.CTL_ADD,
                pidfd,
                @constCast(&system.epoll_event{ .events = system.EPOLL.IN, .data = .{ .ptr = @intFromPtr(&handlePid) } }),
            );

            try posix.epoll_ctl(
                epoll,
                system.EPOLL.CTL_ADD,
                err_pipe[0],
                @constCast(&system.epoll_event{ .events = system.EPOLL.IN, .data = .{ .ptr = @intFromPtr(&handleError) } }),
            );

            try posix.epoll_ctl(
                epoll,
                system.EPOLL.CTL_ADD,
                output_pipe[0],
                @constCast(&system.epoll_event{ .events = system.EPOLL.IN, .data = .{ .ptr = @intFromPtr(&handleOutput) } }),
            );

            if (timeout) |seconds| {
                try posix.timerfd_settime(
                    timerfd,
                    .{},
                    &.{ .it_value = .{ .sec = seconds, .nsec = 0 }, .it_interval = .{ .sec = 0, .nsec = 0 } },
                    null,
                );
                try posix.epoll_ctl(
                    epoll,
                    system.EPOLL.CTL_ADD,
                    timerfd,
                    @constCast(&system.epoll_event{ .events = system.EPOLL.IN, .data = .{ .ptr = @intFromPtr(&handleTimeout) } }),
                );
            }

            var events: [1]system.epoll_event = undefined;
            var output_buffer: [1024]u8 = undefined;

            var term: ?std.process.Child.Term = null;

            while (true) {
                const num_events = posix.epoll_wait(epoll, &events, -1);
                if (num_events != events.len) {
                    log.warn("got {} IO events, expected {}", .{ num_events, events.len });
                    continue;
                }

                const event = events[0];
                const func: *const fn (
                    posix.fd_t,
                    posix.fd_t,
                    posix.fd_t,
                    posix.fd_t,
                    []u8,
                    *std.Io.Writer,
                ) anyerror!?std.process.Child.Term = @ptrFromInt(event.data.ptr);

                if (func(
                    pidfd,
                    timerfd,
                    err_pipe[0],
                    output_pipe[0],
                    &output_buffer,
                    output_writer,
                ) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (term) |t| {
                            return t;
                        }
                        return err;
                    },
                    else => return err,
                }) |t| {
                    if (term == null) {
                        std.posix.close(output_pipe[1]);
                        std.posix.close(pidfd);
                        term = t;
                    }
                }
            }
        },
    }
}
