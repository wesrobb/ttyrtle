const std = @import("std");
const win32 = @import("win32");
const geometry = @import("geometry.zig");
const input_queue = @import("input_queue.zig");
const output_queue = @import("output_queue.zig");
const session_lifecycle = @import("session_lifecycle.zig");

const console = win32.system.console;
const foundation = win32.foundation;
const job_objects = win32.system.job_objects;
const threading = win32.system.threading;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

pub const output_message = win32.ui.windows_and_messaging.WM_APP + 1;
pub const child_exit_message = win32.ui.windows_and_messaging.WM_APP + 2;
pub const input_failure_message = win32.ui.windows_and_messaging.WM_APP + 3;

pub const Session = struct {
    allocator: std.mem.Allocator,
    window: foundation.HWND,
    notification_token: usize,
    pseudo_console: ?console.HPCON,
    input_write: ?foundation.HANDLE,
    output_read: ?foundation.HANDLE,
    job: ?foundation.HANDLE,
    process: ?foundation.HANDLE,
    primary_thread: ?foundation.HANDLE,
    reader_thread: ?std.Thread,
    writer_thread: ?std.Thread,
    process_waiter_thread: ?std.Thread,
    pseudo_console_closer_thread: ?std.Thread,
    input: input_queue.InputQueue,
    output: output_queue.OutputQueue,
    input_failure_code: std.atomic.Value(u32),
    child_exit_code: std.atomic.Value(u32),
    child_exit_observed: std.atomic.Value(bool),
    state: std.atomic.Value(session_lifecycle.State),
    dimensions: geometry.Dimensions,

    pub fn create(
        allocator: std.mem.Allocator,
        window: foundation.HWND,
        notification_token: usize,
        dimensions: geometry.Dimensions,
        command_line_override: ?[]const u8,
    ) !*Session {
        var input_read: ?foundation.HANDLE = null;
        var input_write: ?foundation.HANDLE = null;
        var output_read: ?foundation.HANDLE = null;
        var output_write: ?foundation.HANDLE = null;
        var pseudo_console: ?console.HPCON = null;
        var job: ?foundation.HANDLE = null;
        var process_info: threading.PROCESS_INFORMATION = std.mem.zeroes(
            threading.PROCESS_INFORMATION,
        );

        if (kernel32.CreatePipe(&input_read, &input_write, null, 0) == 0)
            return win32Failure("CreatePipe for ConPTY input", error.CreateInputPipeFailed);
        errdefer closeHandle(&input_read);
        errdefer closeHandle(&input_write);

        if (kernel32.CreatePipe(&output_read, &output_write, null, 0) == 0)
            return win32Failure("CreatePipe for ConPTY output", error.CreateOutputPipeFailed);
        errdefer closeHandle(&output_read);
        errdefer closeHandle(&output_write);

        const create_result = kernel32.CreatePseudoConsole(
            .{
                .X = @intCast(dimensions.columns),
                .Y = @intCast(dimensions.rows),
            },
            input_read,
            output_write,
            0,
            &pseudo_console,
        );
        if (create_result.failed) {
            std.log.err("CreatePseudoConsole failed with HRESULT {}", .{create_result});
            return error.CreatePseudoConsoleFailed;
        }
        errdefer closePseudoConsole(&pseudo_console);

        job = kernel32.CreateJobObjectW(null, null) orelse
            return win32Failure("CreateJobObjectW", error.CreateJobObjectFailed);
        errdefer closeHandle(&job);
        var job_limits: job_objects.JOBOBJECT_EXTENDED_LIMIT_INFORMATION =
            std.mem.zeroes(job_objects.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        job_limits.BasicLimitInformation.LimitFlags =
            job_objects.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (kernel32.SetInformationJobObject(
            job,
            .JobObjectExtendedLimitInformation,
            @ptrCast(&job_limits),
            @sizeOf(job_objects.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0) return win32Failure(
            "SetInformationJobObject",
            error.ConfigureJobObjectFailed,
        );

        var attribute_bytes: usize = 0;
        _ = kernel32.InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
        if (attribute_bytes == 0)
            return win32Failure(
                "InitializeProcThreadAttributeList size query",
                error.AttributeListSizeFailed,
            );

        const attribute_storage = try allocator.alignedAlloc(
            u8,
            .of(usize),
            attribute_bytes,
        );
        defer allocator.free(attribute_storage);
        const attribute_list: threading.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(
            attribute_storage.ptr,
        );
        if (kernel32.InitializeProcThreadAttributeList(
            attribute_list,
            1,
            0,
            &attribute_bytes,
        ) == 0) return win32Failure(
            "InitializeProcThreadAttributeList",
            error.AttributeListInitializeFailed,
        );
        defer kernel32.DeleteProcThreadAttributeList(attribute_list);

        if (kernel32.UpdateProcThreadAttribute(
            attribute_list,
            0,
            threading.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @ptrCast(pseudo_console.?),
            @sizeOf(console.HPCON),
            null,
            null,
        ) == 0) return win32Failure(
            "UpdateProcThreadAttribute for ConPTY",
            error.AttributeListUpdateFailed,
        );

        var startup: threading.STARTUPINFOEXW = std.mem.zeroes(threading.STARTUPINFOEXW);
        startup.StartupInfo.cb = @sizeOf(threading.STARTUPINFOEXW);
        startup.lpAttributeList = attribute_list;

        const command_line_utf8 = if (command_line_override) |command|
            try allocator.dupe(u8, command)
        else
            try defaultShellCommandLine(allocator);
        defer allocator.free(command_line_utf8);
        const command_line = try std.unicode.utf8ToUtf16LeAllocZ(
            allocator,
            command_line_utf8,
        );
        defer allocator.free(command_line);

        if (kernel32.CreateProcessW(
            null,
            command_line.ptr,
            null,
            null,
            0,
            .{
                .EXTENDED_STARTUPINFO_PRESENT = 1,
                .CREATE_SUSPENDED = 1,
            },
            null,
            null,
            &startup.StartupInfo,
            &process_info,
        ) == 0) return win32Failure(
            "CreateProcessW for ConPTY child",
            error.CreateProcessFailed,
        );
        errdefer closeHandle(&process_info.hProcess);
        errdefer closeHandle(&process_info.hThread);
        if (kernel32.AssignProcessToJobObject(job, process_info.hProcess) == 0)
            return win32Failure(
                "AssignProcessToJobObject",
                error.AssignProcessToJobFailed,
            );
        if (kernel32.ResumeThread(process_info.hThread) == std.math.maxInt(u32))
            return win32Failure("ResumeThread", error.ResumeProcessFailed);

        // ConPTY owns these ends after successful process creation. Keeping
        // duplicate local handles open prevents deterministic disconnection.
        closeHandle(&input_read);
        closeHandle(&output_write);

        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .window = window,
            .notification_token = notification_token,
            .pseudo_console = pseudo_console,
            .input_write = input_write,
            .output_read = output_read,
            .job = job,
            .process = process_info.hProcess,
            .primary_thread = process_info.hThread,
            .reader_thread = null,
            .writer_thread = null,
            .process_waiter_thread = null,
            .pseudo_console_closer_thread = null,
            .input = .init(allocator),
            .output = .init(allocator),
            .input_failure_code = .init(0),
            .child_exit_code = .init(0),
            .child_exit_observed = .init(false),
            .state = .init(.starting),
            .dimensions = dimensions,
        };

        // Ownership has moved to the stable heap allocation used by the
        // reader thread.
        pseudo_console = null;
        input_write = null;
        output_read = null;
        job = null;
        process_info.hProcess = null;
        process_info.hThread = null;

        errdefer self.destroy();
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        self.process_waiter_thread = try std.Thread.spawn(.{}, processWaiterMain, .{self});
        self.state.store(.running, .release);
        return self;
    }

    pub fn destroy(self: *Session) void {
        _ = self.beginClosing();

        // Stop input before closing its pipe handle so the writer never races
        // a CloseHandle. CancelSynchronousIo releases a writer blocked inside
        // WriteFile; a writer waiting on the queue is released by close().
        if (self.writer_thread) |thread| {
            thread.join();
            self.writer_thread = null;
        }
        closeHandle(&self.input_write);

        // ClosePseudoConsole is already running independently and the output
        // reader remains active. Give the child a short grace period, then
        // close the kill-on-close job so the entire descendant tree exits and
        // cannot keep pseudoconsole closure blocked indefinitely.
        if (self.process) |process| {
            _ = kernel32.WaitForSingleObject(process, 250);
        }
        closeHandle(&self.job);
        if (self.process) |process| {
            if (kernel32.WaitForSingleObject(process, 5000) == foundation.WAIT_TIMEOUT) {
                _ = kernel32.TerminateProcess(process, 1);
                _ = kernel32.WaitForSingleObject(process, 5000);
            }
        }

        if (self.pseudo_console_closer_thread) |thread| {
            thread.join();
            self.pseudo_console_closer_thread = null;
        }
        if (self.process_waiter_thread) |thread| {
            thread.join();
            self.process_waiter_thread = null;
        }

        // EOF should follow pseudoconsole and child shutdown. Cancellation is
        // only a final bounded fallback after both have had time to flush.
        if (self.reader_thread) |thread| {
            if (kernel32.WaitForSingleObject(
                @ptrCast(thread.getHandle()),
                250,
            ) == foundation.WAIT_TIMEOUT) {
                _ = kernel32.CancelSynchronousIo(@ptrCast(thread.getHandle()));
            }
            thread.join();
            self.reader_thread = null;
        }
        closeHandle(&self.output_read);
        closeHandle(&self.primary_thread);
        closeHandle(&self.process);
        self.input.deinit();
        self.output.deinit();
        self.state.store(.closed, .release);

        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn drainOutput(self: *Session) output_queue.Batch {
        return self.output.drain();
    }

    /// Takes ownership of bytes encoded by the UI thread.
    pub fn queueInputOwned(self: *Session, bytes: []u8) !void {
        if (self.state.load(.acquire) != .running) return error.SessionClosing;
        return self.input.pushOwned(bytes);
    }

    pub fn inputFailureCode(self: *const Session) ?u32 {
        const code = self.input_failure_code.load(.acquire);
        return if (code == 0) null else code;
    }

    pub fn childExitCode(self: *const Session) ?u32 {
        if (!self.child_exit_observed.load(.acquire)) return null;
        return self.child_exit_code.load(.acquire);
    }

    pub fn sessionState(self: *const Session) session_lifecycle.State {
        return self.state.load(.acquire);
    }

    pub fn resize(self: *Session, dimensions: geometry.Dimensions) !bool {
        if (std.meta.eql(self.dimensions, dimensions)) return false;
        const pseudo_console = self.pseudo_console orelse
            return error.SessionClosing;
        const result = kernel32.ResizePseudoConsole(pseudo_console, .{
            .X = @intCast(dimensions.columns),
            .Y = @intCast(dimensions.rows),
        });
        if (result.failed) {
            std.log.err("ResizePseudoConsole failed with HRESULT {}", .{result});
            return error.ResizePseudoConsoleFailed;
        }
        self.dimensions = dimensions;
        return true;
    }

    /// Requests the single teardown path. The first caller owns the state
    /// transition; later child, window, and worker notifications are no-ops.
    pub fn beginClosing(self: *Session) bool {
        var current = self.state.load(.acquire);
        while (true) {
            switch (current) {
                .closing, .closed => return false,
                .starting, .running, .failed => {},
            }
            current = self.state.cmpxchgWeak(
                current,
                .closing,
                .acq_rel,
                .acquire,
            ) orelse break;
        }

        self.input.close();
        if (self.writer_thread) |thread|
            _ = kernel32.CancelSynchronousIo(@ptrCast(thread.getHandle()));
        self.startPseudoConsoleClose();
        return true;
    }

    fn startPseudoConsoleClose(self: *Session) void {
        const pseudo_console = self.pseudo_console orelse return;
        self.pseudo_console = null;
        self.pseudo_console_closer_thread = std.Thread.spawn(
            .{},
            closePseudoConsoleMain,
            .{pseudo_console},
        ) catch {
            // Thread creation failure is exceptional. Preserve correctness by
            // closing here while the independent output reader still drains.
            closePseudoConsoleValue(pseudo_console);
            return;
        };
    }

    fn writerMain(self: *Session) void {
        while (self.input.take()) |chunk| {
            defer self.allocator.free(chunk);

            var offset: usize = 0;
            while (offset < chunk.len) {
                var bytes_written: u32 = 0;
                if (kernel32.WriteFile(
                    self.input_write,
                    chunk.ptr + offset,
                    @intCast(chunk.len - offset),
                    &bytes_written,
                    null,
                ) == 0 or bytes_written == 0) {
                    const code: u32 = @intFromEnum(kernel32.GetLastError());
                    if (code != @intFromEnum(foundation.ERROR_BROKEN_PIPE) and
                        code != @intFromEnum(foundation.ERROR_OPERATION_ABORTED))
                    {
                        self.input_failure_code.store(code, .release);
                        self.markFailed();
                        _ = user32.PostMessageW(
                            self.window,
                            input_failure_message,
                            self.notification_token,
                            0,
                        );
                    }
                    self.input.close();
                    return;
                }
                offset += bytes_written;
            }
        }
    }

    fn readerMain(self: *Session) void {
        var buffer: [16 * 1024]u8 = undefined;
        var failure: ?output_queue.Failure = null;

        while (true) {
            var bytes_read: u32 = 0;
            if (kernel32.ReadFile(
                self.output_read,
                &buffer,
                buffer.len,
                &bytes_read,
                null,
            ) == 0) {
                const code: u32 = @intFromEnum(kernel32.GetLastError());
                if (code != @intFromEnum(foundation.ERROR_BROKEN_PIPE) and
                    code != @intFromEnum(foundation.ERROR_OPERATION_ABORTED))
                {
                    failure = .{ .read_file = code };
                }
                break;
            }
            if (bytes_read == 0) break;

            const should_post = self.output.push(buffer[0..bytes_read]) catch {
                if (failure == null) {
                    failure = .out_of_memory;
                    std.log.err("queuing ConPTY output ran out of memory", .{});
                }
                continue;
            };
            if (should_post and !self.postOutputMessage()) {
                if (failure == null) {
                    const code: u32 = @intFromEnum(kernel32.GetLastError());
                    std.log.err(
                        "posting ConPTY output failed with Win32 error {d}",
                        .{code},
                    );
                    failure = .{
                        .post_message = code,
                    };
                }
            }
        }

        if (self.output.finish(failure)) _ = self.postOutputMessage();
    }

    fn postOutputMessage(self: *Session) bool {
        return user32.PostMessageW(
            self.window,
            output_message,
            self.notification_token,
            0,
        ) != 0;
    }

    fn processWaiterMain(self: *Session) void {
        const result = kernel32.WaitForSingleObject(
            self.process,
            win32.system.windows_programming.INFINITE,
        );
        if (result == foundation.WAIT_OBJECT_0) {
            var exit_code: u32 = 0;
            if (kernel32.GetExitCodeProcess(self.process, &exit_code) != 0) {
                self.child_exit_code.store(exit_code, .release);
                self.child_exit_observed.store(true, .release);
            } else {
                std.log.err(
                    "GetExitCodeProcess failed with Win32 error {d}",
                    .{@intFromEnum(kernel32.GetLastError())},
                );
            }
            _ = user32.PostMessageW(
                self.window,
                child_exit_message,
                self.notification_token,
                0,
            );
        }
    }

    fn markFailed(self: *Session) void {
        _ = self.state.cmpxchgStrong(
            .running,
            .failed,
            .acq_rel,
            .acquire,
        );
    }
};

fn closePseudoConsoleMain(pseudo_console: console.HPCON) void {
    closePseudoConsoleValue(pseudo_console);
}

fn closePseudoConsoleValue(pseudo_console: console.HPCON) void {
    kernel32.ClosePseudoConsole(pseudo_console);
}

fn defaultShellCommandLine(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "pwsh.exe");
}

fn closeHandle(handle: *?foundation.HANDLE) void {
    if (handle.*) |value| {
        _ = kernel32.CloseHandle(value);
        handle.* = null;
    }
}

fn closePseudoConsole(handle: *?console.HPCON) void {
    if (handle.*) |value| {
        kernel32.ClosePseudoConsole(value);
        handle.* = null;
    }
}

fn win32Failure(context: []const u8, err: anyerror) anyerror {
    std.log.err("{s} failed with Win32 error {d}", .{
        context,
        @intFromEnum(kernel32.GetLastError()),
    });
    return err;
}
