const app = @import("app.zig");
const build_options = @import("build_options");

pub fn main() !void {
    try app.run(if (build_options.smoke_test) .smoke else .normal);
}
