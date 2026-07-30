const app = @import("app");

test "hidden Win32 window initializes, paints, and closes cleanly" {
    try app.run(.smoke);
}

test "hidden GPU renderer presents repeatedly across clean lifecycles" {
    for (0..3) |_| try app.run(.smoke);
}

test "hidden window retains the GDI fallback path" {
    try app.run(.smoke_gdi);
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

test "host close drains and tears down busy ConPTY sessions repeatedly" {
    for (0..3) |_| try app.run(.integration_host_close);
}
