const app = @import("app");

test "hidden Win32 window initializes, paints, and closes cleanly" {
    try app.run(.smoke);
}

test "hidden GPU renderer presents repeatedly across clean lifecycles" {
    for (0..3) |_| try app.run(.smoke);
}

test "GPU renderer caches layouts and recovers across Phase 5 lifecycles" {
    try app.run(.smoke_phase5);
}

test "native tab control mirrors the active workspace tab" {
    try app.run(.smoke_tabs);
}

test "tab shortcuts consume matching key release and character messages" {
    try app.run(.smoke_shortcuts);
}

test "inline tab rename commits cancels clears and survives resize" {
    try app.run(.smoke_rename);
}

test "tab context menus and middle-click dispatch native actions" {
    try app.run(.smoke_tab_interactions);
}

test "tab drag reordering preserves native identities and active selection" {
    try app.run(.smoke_tab_drag);
}

test "closing one native top-level window leaves its sibling live" {
    try app.run(.smoke_multi_window);
}

test "keyboard tab moves preserve DPI seams, accessibility, and renderer cost" {
    try app.run(.smoke_transfer_hardening);
}

test "finite ConPTY child output reaches the terminal model" {
    try app.run(.integration);
}

test "finite ConPTY child receives encoded input and echoes it" {
    try app.run(.integration_input);
}

test "hosted ConPTY child observes an exact window resize" {
    try app.run(.integration_resize);
}

test "inactive ConPTY sessions retain output, OSC tab labels, and asynchronous completion" {
    try app.run(.integration_multi_session);
}

test "resize and DPI changes update every attached ConPTY session" {
    try app.run(.integration_multi_resize);
}

test "repeated host close drains and tears down busy sessions without stale notifications" {
    for (0..5) |_| try app.run(.integration_host_close);
}

test "final visible window disappears before its busy session retirement completes" {
    try app.run(.integration_final_retirement);
}
