const app = @import("app");

test "hidden Win32 window initializes, paints, and closes cleanly" {
    try app.run(.smoke);
}
