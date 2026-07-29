const std = @import("std");
const win32 = @import("win32");
const output_queue = @import("output_queue.zig");

const console = win32.system.console;
const foundation = win32.foundation;
const threading = win32.system.threading;
const kernel32 = win32.kernel32;
const user32 = win32.user32;

pub const output_message = win32.ui.windows_and_messaging.WM_APP + 1;
pub const child_exit_message = win32.ui.windows_and_messaging.WM_APP + 2;

pub const Session = struct {
    allocator: std.mem.Allocator,
    window: foundation.HWND,
    pseudo_console: ?console.HPCON,
    input_write: ?foundation.HANDLE,
    output_read: ?foundation.HANDLE,
    process: ?foundation.HANDLE,
    primary_thread: ?foundation.HANDLE,
    reader_thread: ?std.Thread,
    process_waiter_thread: ?std.Thread,
    output: output_queue.OutputQueue,

    pub fn create(
        allocator: std.mem.Allocator,
        window: foundation.HWND,
        command_line_override: ?[]const u8,
    ) !*Session {
        var input_read: ?foundation.HANDLE = null;
        var input_write: ?foundation.HANDLE = null;
        var output_read: ?foundation.HANDLE = null;
        var output_write: ?foundation.HANDLE = null;
        var pseudo_console: ?console.HPCON = null;
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
            .{ .X = 80, .Y = 24 },
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
            .{ .EXTENDED_STARTUPINFO_PRESENT = 1 },
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

        // ConPTY owns these ends after successful process creation. Keeping
        // local copies open prevents EOF and broken-pipe detection.
        closeHandle(&input_read);
        closeHandle(&output_write);

        const self = try allocator.create(Session);
        self.* = .{
            .allocator = allocator,
            .window = window,
            .pseudo_console = pseudo_console,
            .input_write = input_write,
            .output_read = output_read,
            .process = process_info.hProcess,
            .primary_thread = process_info.hThread,
            .reader_thread = null,
            .process_waiter_thread = null,
            .output = .init(allocator),
        };

        // Ownership has moved to the stable heap allocation used by the
        // reader thread.
        pseudo_console = null;
        input_write = null;
        output_read = null;
        process_info.hProcess = null;
        process_info.hThread = null;

        errdefer self.destroy();
        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        self.process_waiter_thread = try std.Thread.spawn(.{}, processWaiterMain, .{self});
        return self;
    }

    pub fn destroy(self: *Session) void {
        closeHandle(&self.input_write);
        closePseudoConsole(&self.pseudo_console);
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.process_waiter_thread) |thread| {
            thread.join();
            self.process_waiter_thread = null;
        }
        closeHandle(&self.output_read);
        closeHandle(&self.primary_thread);
        closeHandle(&self.process);
        self.output.deinit();

        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn drainOutput(self: *Session) output_queue.Batch {
        return self.output.drain();
    }

    pub fn closeAfterChildExit(self: *Session) void {
        closeHandle(&self.input_write);
        closePseudoConsole(&self.pseudo_console);
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
                if (code != @intFromEnum(foundation.ERROR_BROKEN_PIPE)) {
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
        return user32.PostMessageW(self.window, output_message, 0, 0) != 0;
    }

    fn processWaiterMain(self: *Session) void {
        const result = kernel32.WaitForSingleObject(
            self.process,
            win32.system.windows_programming.INFINITE,
        );
        if (result == foundation.WAIT_OBJECT_0) {
            _ = user32.PostMessageW(self.window, child_exit_message, 0, 0);
        }
    }
};

fn defaultShellCommandLine(allocator: std.mem.Allocator) ![]u8 {
    const environment: std.process.Environ = .{ .block = .global };
    const shell = environment.getAlloc(allocator, "COMSPEC") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return allocator.dupe(u8, "cmd.exe"),
        else => return err,
    };
    defer allocator.free(shell);
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{shell});
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
