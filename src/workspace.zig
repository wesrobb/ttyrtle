const std = @import("std");
const terminal = @import("terminal.zig");

pub const TabId = enum(u64) { _ };
pub const SessionId = enum(u64) { _ };

pub const IdSource = struct {
    next_tab: u64 = 1,
    next_session: u64 = 1,

    fn tab(self: *IdSource) TabId {
        const id: TabId = @enumFromInt(self.next_tab);
        self.next_tab += 1;
        return id;
    }

    fn session(self: *IdSource) SessionId {
        const id: SessionId = @enumFromInt(self.next_session);
        self.next_session += 1;
        return id;
    }
};

pub const TerminalSession = struct {
    pub const OwnedProcess = struct {
        context: *anyopaque,
        destroy: *const fn (context: *anyopaque) void,
    };

    id: SessionId,
    model: terminal.TerminalModel,
    process: ?OwnedProcess = null,

    fn init(
        self: *TerminalSession,
        allocator: std.mem.Allocator,
        id: SessionId,
        rows: u16,
        columns: u16,
    ) !void {
        self.* = .{
            .id = id,
            .model = undefined,
        };
        try self.model.init(allocator, rows, columns);
    }

    pub fn attachProcess(self: *TerminalSession, process: OwnedProcess) !void {
        if (self.process != null) return error.ProcessAlreadyAttached;
        self.process = process;
    }

    pub fn processAs(self: *TerminalSession, comptime Process: type) ?*Process {
        const owned = self.process orelse return null;
        return @ptrCast(@alignCast(owned.context));
    }

    pub fn closeProcess(self: *TerminalSession) void {
        self.model.setReplySink(null);
        if (self.process) |process| process.destroy(process.context);
        self.process = null;
    }

    fn deinit(self: *TerminalSession) void {
        self.closeProcess();
        self.model.deinit();
    }
};

pub const PaneNode = union(enum) {
    terminal: *TerminalSession,

    fn deinit(self: *PaneNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .terminal => |session| {
                session.deinit();
                allocator.destroy(session);
            },
        }
    }

    pub fn terminalSession(self: *PaneNode) *TerminalSession {
        return switch (self.*) {
            .terminal => |session| session,
        };
    }

    pub fn terminalSessionConst(self: *const PaneNode) *const TerminalSession {
        return switch (self.*) {
            .terminal => |session| session,
        };
    }
};

pub const Tab = struct {
    id: TabId,
    title_override: ?[]u8 = null,
    root: PaneNode,

    fn deinit(self: *Tab, allocator: std.mem.Allocator) void {
        if (self.title_override) |title| allocator.free(title);
        self.root.deinit(allocator);
    }
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    ids: *IdSource,
    tabs: std.ArrayListUnmanaged(Tab) = .empty,
    active_tab_id: ?TabId = null,

    pub fn init(allocator: std.mem.Allocator, ids: *IdSource) Workspace {
        return .{
            .allocator = allocator,
            .ids = ids,
        };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.tabs.items) |*item| item.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn createTab(
        self: *Workspace,
        rows: u16,
        columns: u16,
    ) !TabId {
        const tab_id = self.ids.tab();
        const session = try self.allocator.create(TerminalSession);
        errdefer self.allocator.destroy(session);
        try session.init(
            self.allocator,
            self.ids.session(),
            rows,
            columns,
        );
        errdefer session.deinit();
        try self.tabs.append(self.allocator, .{
            .id = tab_id,
            .root = .{ .terminal = session },
        });
        if (self.active_tab_id == null) self.active_tab_id = tab_id;
        return tab_id;
    }

    pub fn closeTab(self: *Workspace, id: TabId) bool {
        const index = self.indexOf(id) orelse return false;
        var removed = self.tabs.orderedRemove(index);
        removed.deinit(self.allocator);

        if (self.active_tab_id == id) {
            self.active_tab_id = if (self.tabs.items.len == 0)
                null
            else
                self.tabs.items[@min(index, self.tabs.items.len - 1)].id;
        }
        return true;
    }

    pub fn setActive(self: *Workspace, id: TabId) bool {
        if (self.indexOf(id) == null) return false;
        self.active_tab_id = id;
        return true;
    }

    pub fn renameTab(self: *Workspace, id: TabId, title: ?[]const u8) !bool {
        const item = self.tab(id) orelse return false;
        const replacement = if (title) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        if (item.title_override) |old| self.allocator.free(old);
        item.title_override = replacement;
        return true;
    }

    pub fn reorderTab(self: *Workspace, id: TabId, new_index: usize) bool {
        const old_index = self.indexOf(id) orelse return false;
        if (new_index >= self.tabs.items.len) return false;
        if (old_index == new_index) return true;

        const moved = self.tabs.orderedRemove(old_index);
        self.tabs.insertAssumeCapacity(new_index, moved);
        return true;
    }

    pub fn tab(self: *Workspace, id: TabId) ?*Tab {
        const index = self.indexOf(id) orelse return null;
        return &self.tabs.items[index];
    }

    pub fn activeTab(self: *Workspace) ?*Tab {
        return self.tab(self.active_tab_id orelse return null);
    }

    pub fn activeSession(self: *Workspace) ?*TerminalSession {
        const active = self.activeTab() orelse return null;
        return active.root.terminalSession();
    }

    fn indexOf(self: *const Workspace, id: TabId) ?usize {
        for (self.tabs.items, 0..) |item, index| {
            if (item.id == id) return index;
        }
        return null;
    }
};

const TestProcess = struct {
    destroy_count: usize = 0,

    fn destroy(context: *anyopaque) void {
        const self: *TestProcess = @ptrCast(@alignCast(context));
        self.destroy_count += 1;
    }
};

test "workspace creates stable tab and session identities" {
    var ids: IdSource = .{};
    var workspace = Workspace.init(std.testing.allocator, &ids);
    defer workspace.deinit();

    const first = try workspace.createTab(24, 80);
    const first_session = workspace.activeSession().?.id;
    const second = try workspace.createTab(24, 80);

    try std.testing.expect(first != second);
    try std.testing.expect(first_session != workspace.tabs.items[1].root.terminalSession().id);
    try std.testing.expectEqual(first, workspace.active_tab_id.?);
}

test "id source keeps identities unique across workspaces" {
    var ids: IdSource = .{};
    var first = Workspace.init(std.testing.allocator, &ids);
    defer first.deinit();
    var second = Workspace.init(std.testing.allocator, &ids);
    defer second.deinit();

    const first_tab = try first.createTab(24, 80);
    const second_tab = try second.createTab(24, 80);
    try std.testing.expect(first_tab != second_tab);
    try std.testing.expect(first.activeSession().?.id != second.activeSession().?.id);
}

test "terminal session owns and closes its attached process once" {
    var ids: IdSource = .{};
    var workspace = Workspace.init(std.testing.allocator, &ids);
    defer workspace.deinit();
    _ = try workspace.createTab(24, 80);

    var process: TestProcess = .{};
    const session = workspace.activeSession().?;
    try session.attachProcess(.{
        .context = &process,
        .destroy = TestProcess.destroy,
    });
    try std.testing.expectError(
        error.ProcessAlreadyAttached,
        session.attachProcess(.{
            .context = &process,
            .destroy = TestProcess.destroy,
        }),
    );
    session.closeProcess();
    session.closeProcess();
    try std.testing.expectEqual(@as(usize, 1), process.destroy_count);
}

test "closing active tab chooses its nearest remaining neighbor" {
    var ids: IdSource = .{};
    var workspace = Workspace.init(std.testing.allocator, &ids);
    defer workspace.deinit();

    const first = try workspace.createTab(24, 80);
    const second = try workspace.createTab(24, 80);
    const third = try workspace.createTab(24, 80);
    try std.testing.expect(workspace.setActive(second));
    try std.testing.expect(workspace.closeTab(second));
    try std.testing.expectEqual(third, workspace.active_tab_id.?);
    try std.testing.expect(workspace.closeTab(third));
    try std.testing.expectEqual(first, workspace.active_tab_id.?);
    try std.testing.expect(workspace.closeTab(first));
    try std.testing.expectEqual(@as(?TabId, null), workspace.active_tab_id);
}

test "tabs can be renamed, selected, and reordered by stable id" {
    var ids: IdSource = .{};
    var workspace = Workspace.init(std.testing.allocator, &ids);
    defer workspace.deinit();

    const first = try workspace.createTab(24, 80);
    const second = try workspace.createTab(24, 80);
    const third = try workspace.createTab(24, 80);
    try std.testing.expect(try workspace.renameTab(second, "build"));
    try std.testing.expectEqualStrings("build", workspace.tab(second).?.title_override.?);
    try std.testing.expect(workspace.reorderTab(third, 0));
    try std.testing.expectEqual(third, workspace.tabs.items[0].id);
    try std.testing.expect(workspace.reorderTab(third, 2));
    try std.testing.expectEqual(third, workspace.tabs.items[2].id);
    try std.testing.expect(workspace.setActive(second));
    try std.testing.expectEqual(second, workspace.activeTab().?.id);
    try std.testing.expect(!workspace.setActive(@enumFromInt(999)));
    try std.testing.expect(!workspace.reorderTab(first, 99));
}
