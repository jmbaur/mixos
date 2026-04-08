const builtin = @import("builtin");
const posix = std.posix;
const std = @import("std");
const system = std.os.linux;
const C = @cImport({
    @cInclude("sys/epoll.h");
});

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
    working_directory: []const u8,
    envp: [:null]?[*:0]u8,
    errfd: posix.fd_t,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
    stderr: posix.fd_t,
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

fn handlePid(args: CallbackArgs) anyerror!?std.process.Child.Term {
    var siginfo: system.siginfo_t = undefined;

    while (true) {
        switch (system.E.init(system.waitid(.PIDFD, args.pidfd, &siginfo, system.W.EXITED))) {
            .SUCCESS => {},
            .CHILD => return error.NoChildProcess,
            .INTR => continue,
            .INVAL => return error.InvalidArguments,
            else => |err| return posix.unexpectedErrno(err),
        }
        break;
    }

    try posix.epoll_ctl(args.epoll, system.EPOLL.CTL_DEL, args.pidfd, null);

    args.state.process_complete = true;

    // We can close the stdout/stderr pipes on the writer's end, which will
    // cause EPOLLHUP, thus allowing us to capture the rest of the process'
    // output.
    posix.close(args.stdout_pipe[1]);
    if (args.stderr_pipe) |stderr_pipe| {
        posix.close(stderr_pipe[1]);
    }

    const status: u32 = @bitCast(siginfo.fields.common.second.sigchld.status);
    const code: CLD = @enumFromInt(siginfo.code);
    const term: std.process.Child.Term = switch (code) {
        .EXITED => .{ .Exited = @truncate(status) },
        .KILLED, .DUMPED => .{ .Signal = status },
        .TRAPPED, .STOPPED => .{ .Stopped = status },
        _, .CONTINUED => .{ .Unknown = status },
    };

    log.debug("process ended with term {}", .{term});

    return term;
}

fn handleError(args: CallbackArgs) anyerror!?std.process.Child.Term {
    const T = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

    var err_buf: [@sizeOf(T)]u8 = undefined;
    _ = try posix.read(args.errfd, &err_buf);

    const err_int = std.mem.readInt(T, &err_buf, .little);
    const err = @errorFromInt(err_int);

    // The process never ran, so we mark everything as complete.
    args.state.* = .{
        .process_complete = true,
        .stdout_done = true,
        .stderr_done = true,
    };

    return err;
}

fn handleStdout(args: CallbackArgs) anyerror!?std.process.Child.Term {
    handleOutput(args.stdout_pipe[0], args.output_buffer, args.stdout_writer) catch |err| switch (err) {
        error.EndOfStream => {
            try posix.epoll_ctl(args.epoll, system.EPOLL.CTL_DEL, args.stdout_pipe[0], null);
            args.state.stdout_done = true;
            return null;
        },
        else => return err,
    };

    return null;
}

fn handleStderr(args: CallbackArgs) anyerror!?std.process.Child.Term {
    std.debug.assert(args.stderr_pipe != null);
    const stderr_pipe = args.stderr_pipe.?;

    handleOutput(
        stderr_pipe[0],
        args.output_buffer,
        args.stderr_writer,
    ) catch |err| switch (err) {
        error.EndOfStream => {
            try posix.epoll_ctl(args.epoll, system.EPOLL.CTL_DEL, stderr_pipe[0], null);
            args.state.stderr_done = true;
            return null;
        },
        else => return err,
    };

    return null;
}

fn handleOutput(
    outputfd: posix.fd_t,
    output_buffer: []u8,
    output_writer: *std.Io.Writer,
) !void {
    const n = try posix.read(outputfd, output_buffer[0..]);
    if (n == 0) {
        return error.EndOfStream;
    }

    try output_writer.writeAll(output_buffer[0..n]);
    try output_writer.flush();
}

fn pidfd_send_signal(pidfd: posix.fd_t, signal: i32) !void {
    switch (system.E.init(system.pidfd_send_signal(pidfd, signal, null, 0))) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        .BADF, .INVAL => return error.InvalidArguments,
        .SRCH => return error.ProcessNotFound,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn handleTimer(args: CallbackArgs) anyerror!?std.process.Child.Term {
    // Consume the timer event
    var elapsed: u64 = 0;
    _ = try posix.read(args.timerfd, std.mem.asBytes(&elapsed));

    try posix.epoll_ctl(args.epoll, system.EPOLL.CTL_DEL, args.timerfd, null);

    try pidfd_send_signal(args.pidfd, posix.SIG.TERM);

    args.state.process_timeout = true;

    log.debug("process timeout", .{});

    return null;
}

const CallbackState = struct {
    process_complete: bool = false,
    process_timeout: bool = false,
    stdout_done: bool = false,
    stderr_done: bool = false,
};

const CallbackArgs = struct {
    events: u32,
    epoll: posix.fd_t,
    pidfd: posix.fd_t,
    timerfd: posix.fd_t,
    errfd: posix.fd_t,
    stdout_pipe: [2]posix.fd_t,
    stderr_pipe: ?[2]posix.fd_t,
    output_buffer: []u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    state: *CallbackState,
};

pub fn run(
    arena: std.mem.Allocator,
    argv: []const []const u8,
    opts: struct {
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
        working_directory: []const u8 = "/",
        timeout: ?i64 = null,
    },
) anyerror!std.process.Child.Term {
    const epoll = try posix.epoll_create1(C.EPOLL_CLOEXEC);
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

    const stdout_pipe = try posix.pipe();
    defer {
        posix.close(stdout_pipe[0]);
    }

    const stderr_pipe = if (opts.stdout_writer != opts.stderr_writer) try posix.pipe() else null;
    defer {
        if (stderr_pipe) |pipe| {
            posix.close(pipe[0]);
        }
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
            opts.working_directory,
            envp,
            err_pipe[1],
            dev_null.handle,
            stdout_pipe[1],
            if (stderr_pipe) |pipe| pipe[1] else stdout_pipe[1],
        ),
        else => |pid| {
            const pidfd = try pidfd_open(pid, 0);
            defer posix.close(pidfd);

            try posix.epoll_ctl(
                epoll,
                system.EPOLL.CTL_ADD,
                pidfd,
                @constCast(&system.epoll_event{
                    .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
                    .data = .{ .ptr = @intFromPtr(&handlePid) },
                }),
            );

            try posix.epoll_ctl(
                epoll,
                system.EPOLL.CTL_ADD,
                err_pipe[0],
                @constCast(&system.epoll_event{
                    .events = system.EPOLL.IN | system.EPOLL.ONESHOT,
                    .data = .{ .ptr = @intFromPtr(&handleError) },
                }),
            );

            try posix.epoll_ctl(
                epoll,
                system.EPOLL.CTL_ADD,
                stdout_pipe[0],
                @constCast(&system.epoll_event{
                    .events = system.EPOLL.IN,
                    .data = .{ .ptr = @intFromPtr(&handleStdout) },
                }),
            );

            if (stderr_pipe) |pipe| {
                try posix.epoll_ctl(
                    epoll,
                    system.EPOLL.CTL_ADD,
                    pipe[0],
                    @constCast(&system.epoll_event{
                        .events = system.EPOLL.IN,
                        .data = .{ .ptr = @intFromPtr(&handleStderr) },
                    }),
                );
            }

            if (opts.timeout) |seconds| {
                try posix.timerfd_settime(
                    timerfd,
                    .{},
                    &.{
                        .it_value = .{ .sec = seconds, .nsec = 0 },
                        .it_interval = .{ .sec = 0, .nsec = 0 },
                    },
                    null,
                );
                try posix.epoll_ctl(
                    epoll,
                    system.EPOLL.CTL_ADD,
                    timerfd,
                    @constCast(&system.epoll_event{
                        .events = system.EPOLL.IN,
                        .data = .{ .ptr = @intFromPtr(&handleTimer) },
                    }),
                );
            }

            var events: [10]system.epoll_event = undefined;
            var buffer: [1024]u8 = undefined;

            var ret: anyerror!std.process.Child.Term = error.Unexpected;

            var state: CallbackState = .{};

            while (true) {
                if (state.stdout_done and (stderr_pipe == null or state.stderr_done)) {
                    if (state.process_complete) {
                        return if (state.process_timeout) error.Timeout else ret;
                    } else {
                        try pidfd_send_signal(pidfd, posix.SIG.KILL);
                    }
                }

                const num_events = posix.epoll_wait(epoll, &events, -1);
                for (events[0..num_events]) |event| {
                    const func: *const fn (CallbackArgs) anyerror!?std.process.Child.Term = @ptrFromInt(event.data.ptr);

                    if (func(.{
                        .events = event.events,
                        .epoll = epoll,
                        .pidfd = pidfd,
                        .timerfd = timerfd,
                        .errfd = err_pipe[0],
                        .stdout_pipe = stdout_pipe,
                        .stderr_pipe = if (stderr_pipe) |pipe| pipe else null,
                        .output_buffer = &buffer,
                        .stdout_writer = opts.stdout_writer,
                        .stderr_writer = opts.stderr_writer,
                        .state = &state,
                    })) |term| {
                        if (term) |t| {
                            ret = t;
                        }
                    } else |err| {
                        ret = err;
                    }
                }
            }
        },
    }
}

test run {
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
            .{
                .stdout_writer = &output.writer,
                .stderr_writer = &output.writer,
                .timeout = 1,
            },
        ) catch |err| switch (err) {
            // Since this test is slightly impure in that it runs some
            // external command, we should allow for locked-down/sandboxed
            // environments that do not have the capability to run this test.
            error.FileNotFound => return error.SkipZigTest,
            else => err,
        });
    }
}
