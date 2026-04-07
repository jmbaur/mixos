const builtin = @import("builtin");
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
    argv: [*:null]const ?[*:0]const u8,
    envp: [:null]?[*:0]u8,
    errfd: posix.fd_t,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
    stderr: posix.fd_t,
    working_directory: []const u8,
) noreturn {
    const err = child: {
        posix.chdir(working_directory) catch |err| break :child err;

        posix.dup2(stdin, posix.STDIN_FILENO) catch |err| break :child err;
        posix.dup2(stdout, posix.STDOUT_FILENO) catch |err| break :child err;
        posix.dup2(stderr, posix.STDERR_FILENO) catch |err| break :child err;

        break :child posix.execvpeZ(argv[0].?, argv, envp);
    };

    const err_int = @intFromError(err);
    var err_buf: [@sizeOf(@TypeOf(err_int))]u8 = undefined;
    std.mem.writeInt(@TypeOf(err_int), &err_buf, err_int, .little);
    _ = posix.write(errfd, &err_buf) catch {};
    posix.exit(1);
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
    arena: std.mem.Allocator,
    argv: []const []const u8,
    output_writer: *std.Io.Writer,
    working_directory: []const u8,
    timeout: ?isize,
) !std.process.Child.Term {
    const epoll = try posix.epoll_create1(0);
    defer posix.close(epoll);

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;

    const envp = try std.process.createEnvironFromExisting(
        arena,
        @ptrCast(std.os.environ.ptr),
        .{},
    );

    const dev_null = try std.fs.cwd().openFile("/dev/null", .{});
    defer dev_null.close();

    const output_pipe = try posix.pipe();
    defer {
        posix.close(output_pipe[0]);
    }
    const err_pipe = try posix.pipe();
    defer {
        posix.close(err_pipe[0]);
        posix.close(err_pipe[1]);
    }

    const timerfd = try posix.timerfd_create(.BOOTTIME, .{ .CLOEXEC = true });
    defer posix.close(timerfd);

    switch (try posix.fork()) {
        0 => runChild(
            argv_buf,
            envp,
            err_pipe[1],
            dev_null.handle,
            output_pipe[1],
            output_pipe[1],
            working_directory,
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
                    error.EndOfStream => return if (term) |t| t else err,
                    else => return err,
                }) |t| {
                    if (term == null) {
                        posix.close(output_pipe[1]);
                        posix.close(pidfd);
                        term = t;
                    }
                }
            }
        },
    }
}

test "run" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // timeout
    {
        var output: std.Io.Writer.Discarding = .init(&.{});

        // TODO(jared): skip test if any kernel features we use here aren't available (EPOLL/TIMERFD/etc)
        try std.testing.expectError(error.Timeout, run(
            arena.allocator(),
            &.{ "sleep", "2" },
            &output.writer,
            "/",
            1,
        ) catch |err| switch (err) {
            // Since this test is slightly impure in that it runs some
            // external command, we should allow for locked-down/sandboxed
            // environments that do not have the capability to run this test.
            error.FileNotFound => return error.SkipZigTest,
            else => err,
        });
    }
}
