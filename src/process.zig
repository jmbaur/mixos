const builtin = @import("builtin");
const posix = std.posix;
const std = @import("std");
const C = @cImport({
    @cInclude("sys/epoll.h");
});

const EPOLL = std.os.linux.EPOLL;

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
    const ret = std.os.linux.pidfd_open(pid, flags);
    if (ret < 0) {
        return switch (std.os.linux.errno(ret)) {
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
    io: std.Io,
    working_directory: []const u8,
    errfd: posix.fd_t,
    stdin: posix.fd_t,
    stdout: posix.fd_t,
    stderr: posix.fd_t,
    opts: std.process.ReplaceOptions,
) noreturn {
    const err = child: {
        // don't close
        const cwd = std.Io.Dir.cwd().openDir(io, working_directory, .{}) catch |err| break :child err;

        io.vtable.processSetCurrentDir(io.userdata, cwd) catch |err| break :child err;

        _ = posix.system.dup2(stdin, posix.STDIN_FILENO);
        _ = posix.system.dup2(stdout, posix.STDOUT_FILENO);
        _ = stderr;
        // _ = posix.system.dup2(stderr, posix.STDERR_FILENO);

        break :child io.vtable.processReplace(io.userdata, opts);
    };

    std.debug.print("HERE {}\n", .{err});
    const err_int = @intFromError(err);
    var err_buf: [@sizeOf(@TypeOf(err_int))]u8 = undefined;
    std.mem.writeInt(@TypeOf(err_int), &err_buf, err_int, .little);
    _ = posix.system.write(errfd, &err_buf, err_buf.len);
    posix.system.exit(1);
}

fn handlePid(args: CallbackArgs) anyerror!?std.process.Child.Term {
    var siginfo: posix.system.siginfo_t = undefined;

    while (true) {
        switch (std.os.linux.errno(std.os.linux.waitid(.PIDFD, args.pidfd, &siginfo, posix.system.W.EXITED, null))) {
            .SUCCESS => {},
            .CHILD => return error.NoChildProcess,
            .INTR => continue,
            .INVAL => return error.InvalidArguments,
            else => |err| return posix.unexpectedErrno(err),
        }
        break;
    }

    _ = posix.system.epoll_ctl(args.epoll, EPOLL.CTL_DEL, args.pidfd, null);

    args.state.process_complete = true;

    // We can close the stdout/stderr pipes on the writer's end, which will
    // cause EPOLLHUP, thus allowing us to capture the rest of the process'
    // output.
    _ = posix.system.close(args.stdout_pipe[1]);
    if (args.stderr_pipe) |stderr_pipe| {
        _ = posix.system.close(stderr_pipe[1]);
    }

    const status: u32 = @bitCast(siginfo.fields.common.second.sigchld.status);
    const code: std.os.linux.CLD = @enumFromInt(siginfo.code);
    return switch (code) {
        .EXITED => .{ .exited = @truncate(status) },
        .KILLED, .DUMPED => .{ .signal = @enumFromInt(status) },
        .TRAPPED, .STOPPED => .{ .stopped = @enumFromInt(status) },
        _, .CONTINUED => .{ .unknown = status },
    };
}

fn handleError(args: CallbackArgs) anyerror!?std.process.Child.Term {
    // The process never ran, so we mark everything as complete.
    args.state.* = .{
        .process_complete = true,
        .stdout_done = true,
        .stderr_done = true,
    };

    const T = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

    var err_buf: [@sizeOf(T)]u8 = undefined;
    _ = posix.system.read(args.errfd, &err_buf, err_buf.len);

    const err_int = std.mem.readInt(T, &err_buf, .little);
    const err = @errorFromInt(err_int);

    return err;
}

fn handleStdout(args: CallbackArgs) anyerror!?std.process.Child.Term {
    handleOutput(args.stdout_pipe[0], args.output_buffer, args.stdout_writer) catch |err| switch (err) {
        error.EndOfStream => {
            _ = posix.system.epoll_ctl(args.epoll, EPOLL.CTL_DEL, args.stdout_pipe[0], null);
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
            _ = posix.system.epoll_ctl(args.epoll, EPOLL.CTL_DEL, stderr_pipe[0], null);
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

fn pidfd_send_signal(pidfd: posix.fd_t, signal: posix.SIG) !void {
    switch (std.os.linux.errno(std.os.linux.pidfd_send_signal(pidfd, signal, null, 0))) {
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

    _ = posix.system.epoll_ctl(args.epoll, EPOLL.CTL_DEL, args.timerfd, null);

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
    io: std.Io,
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
    io: std.Io,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    opts: struct {
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
        working_directory: []const u8 = "/",
        timeout: ?i64 = null,
    },
) !std.process.Child.Term {
    _ = arena; // autofix
    const epoll: posix.fd_t = @intCast(posix.system.epoll_create1(C.EPOLL_CLOEXEC));
    defer _ = posix.system.close(epoll);

    const dev_null = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{});
    defer dev_null.close(io);

    var stdout_pipe = std.mem.zeroes([2]posix.fd_t);
    _ = posix.system.pipe(&stdout_pipe);
    defer _ = posix.system.close(stdout_pipe[0]);

    var stderr_pipe: ?[2]posix.fd_t = std.mem.zeroes([2]posix.fd_t);
    if (opts.stdout_writer != opts.stderr_writer) {
        _ = posix.system.pipe(&stderr_pipe.?);
    } else {
        stderr_pipe = null;
    }
    defer {
        if (stderr_pipe) |pipe| _ = posix.system.close(pipe[0]);
    }

    var err_pipe = std.mem.zeroes([2]posix.fd_t);
    _ = posix.system.pipe(&err_pipe);
    defer {
        _ = posix.system.close(err_pipe[0]);
        _ = posix.system.close(err_pipe[1]);
    }

    const timerfd: posix.fd_t = @intCast(posix.system.timerfd_create(
        .BOOTTIME,
        @bitCast(posix.system.TFD{ .CLOEXEC = true }),
    ));
    defer _ = posix.system.close(timerfd);

    switch (posix.system.fork()) {
        0 => runChild(
            io,
            opts.working_directory,
            err_pipe[1],
            dev_null.handle,
            stdout_pipe[1],
            if (stderr_pipe) |pipe| pipe[1] else stdout_pipe[1],
            .{ .argv = argv },
        ),
        else => |pid| {
            const pidfd = try pidfd_open(@intCast(pid), 0);
            defer _ = posix.system.close(pidfd);

            _ = posix.system.epoll_ctl(
                epoll,
                EPOLL.CTL_ADD,
                pidfd,
                @constCast(&posix.system.epoll_event{
                    .events = EPOLL.IN | EPOLL.ONESHOT,
                    .data = .{ .ptr = @intFromPtr(&handlePid) },
                }),
            );

            _ = posix.system.epoll_ctl(
                epoll,
                EPOLL.CTL_ADD,
                err_pipe[0],
                @constCast(&posix.system.epoll_event{
                    .events = EPOLL.IN | EPOLL.ONESHOT,
                    .data = .{ .ptr = @intFromPtr(&handleError) },
                }),
            );

            _ = posix.system.epoll_ctl(
                epoll,
                EPOLL.CTL_ADD,
                stdout_pipe[0],
                @constCast(&posix.system.epoll_event{
                    .events = EPOLL.IN,
                    .data = .{ .ptr = @intFromPtr(&handleStdout) },
                }),
            );

            if (stderr_pipe) |pipe| {
                _ = posix.system.epoll_ctl(
                    epoll,
                    EPOLL.CTL_ADD,
                    pipe[0],
                    @constCast(&posix.system.epoll_event{
                        .events = EPOLL.IN,
                        .data = .{ .ptr = @intFromPtr(&handleStderr) },
                    }),
                );
            }

            if (opts.timeout) |seconds| {
                _ = posix.system.timerfd_settime(
                    timerfd,
                    0,
                    &.{ .it_value = .{ .sec = @intCast(seconds), .nsec = 0 }, .it_interval = .{ .sec = 0, .nsec = 0 } },
                    null,
                );
                _ = posix.system.epoll_ctl(
                    epoll,
                    EPOLL.CTL_ADD,
                    timerfd,
                    @constCast(&posix.system.epoll_event{
                        .events = EPOLL.IN,
                        .data = .{ .ptr = @intFromPtr(&handleTimer) },
                    }),
                );
            }

            var events: [10]posix.system.epoll_event = undefined;
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

                const num_events = posix.system.epoll_wait(epoll, &events, events.len, -1);
                for (events[0..@intCast(num_events)]) |event| {
                    const func: *const fn (CallbackArgs) anyerror!?std.process.Child.Term = @ptrFromInt(event.data.ptr);

                    if (func(.{
                        .events = event.events,
                        .io = io,
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
            std.testing.io,
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
