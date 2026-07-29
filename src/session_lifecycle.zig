const std = @import("std");

pub const State = enum(u8) {
    starting,
    running,
    closing,
    closed,
    failed,
};

pub const Machine = struct {
    state: State = .starting,

    pub fn startupSucceeded(self: *Machine) !void {
        if (self.state != .starting) return error.IllegalTransition;
        self.state = .running;
    }

    pub fn startupFailed(self: *Machine) !void {
        if (self.state != .starting) return error.IllegalTransition;
        self.state = .failed;
    }

    pub fn fail(self: *Machine) !void {
        if (self.state != .running) return error.IllegalTransition;
        self.state = .failed;
    }

    /// Returns true only for the owner that first initiates teardown.
    pub fn requestClose(self: *Machine) bool {
        switch (self.state) {
            .starting, .running, .failed => {
                self.state = .closing;
                return true;
            },
            .closing, .closed => return false,
        }
    }

    pub fn cleanupFinished(self: *Machine) !void {
        if (self.state != .closing) return error.IllegalTransition;
        self.state = .closed;
    }
};

test "successful session follows running close lifecycle" {
    var machine: Machine = .{};
    try machine.startupSucceeded();
    try std.testing.expectEqual(State.running, machine.state);
    try std.testing.expect(machine.requestClose());
    try std.testing.expectEqual(State.closing, machine.state);
    try machine.cleanupFinished();
    try std.testing.expectEqual(State.closed, machine.state);
}

test "close requests are idempotent" {
    var machine: Machine = .{};
    try machine.startupSucceeded();
    try std.testing.expect(machine.requestClose());
    try std.testing.expect(!machine.requestClose());
    try machine.cleanupFinished();
    try std.testing.expect(!machine.requestClose());
}

test "failed startup can still be cleaned up" {
    var machine: Machine = .{};
    try machine.startupFailed();
    try std.testing.expectEqual(State.failed, machine.state);
    try std.testing.expect(machine.requestClose());
    try machine.cleanupFinished();
    try std.testing.expectEqual(State.closed, machine.state);
}

test "illegal state transitions are rejected" {
    var machine: Machine = .{};
    try std.testing.expectError(error.IllegalTransition, machine.cleanupFinished());
    try machine.startupSucceeded();
    try std.testing.expectError(error.IllegalTransition, machine.startupSucceeded());
    try std.testing.expectError(error.IllegalTransition, machine.startupFailed());
}
