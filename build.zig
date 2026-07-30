const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addExecutable(b, .{
        .name = "ttyrtle",
        .target = target,
        .optimize = optimize,
        .smoke_test = false,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the terminal").dependOn(&run.step);

    const unit_tests = b.addTest(.{
        .name = "unit-tests",
        .root_module = createModule(b, .{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = .Debug,
            .include_win32 = false,
        }),
        .use_llvm = true,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run fast unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const app_module = createModule(b, .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = .Debug,
        .ghostty_optimize = .ReleaseSafe,
        .include_win32 = true,
    });
    const integration_root = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = .Debug,
    });
    integration_root.addImport("app", app_module);
    const integration_tests = b.addTest(.{
        .name = "integration-tests",
        .root_module = integration_root,
        .use_llvm = true,
    });
    if (target.result.os.tag == .windows) integration_tests.subsystem = .Windows;
    // ConPTY children inspect the host process standard handles while
    // initializing their console. Zig's test-server protocol reserves stdin
    // for build-runner messages, so run Win32 integration tests with ordinary
    // inherited stdio and use their exit code as the result.
    const run_integration_tests = std.Build.Step.Run.create(
        b,
        "run integration-tests",
    );
    run_integration_tests.addArtifactArg(integration_tests);
    run_integration_tests.stdio = .inherit;
    const integration_step = b.step(
        "test-integration",
        "Run tests that create a hidden Win32 window",
    );
    integration_step.dependOn(&run_integration_tests.step);

    const smoke_exe = addExecutable(b, .{
        .name = "ttyrtle-smoke",
        .target = target,
        .optimize = .Debug,
        .smoke_test = true,
    });
    const run_smoke = b.addRunArtifact(smoke_exe);
    const smoke_step = b.step(
        "smoke",
        "Create, paint, and close a hidden terminal window",
    );
    smoke_step.dependOn(&run_smoke.step);

    const check_debug = addExecutable(b, .{
        .name = "ttyrtle-check-debug",
        .target = target,
        .optimize = .Debug,
        .smoke_test = false,
    });
    const check_release = addExecutable(b, .{
        .name = "ttyrtle-check-release",
        .target = target,
        .optimize = .ReleaseFast,
        .smoke_test = false,
    });
    const check_step = b.step("check", "Compile Debug and ReleaseFast");
    check_step.dependOn(&check_debug.step);
    check_step.dependOn(&check_release.step);

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "test" },
        .check = true,
    });
    const verify_step = b.step("verify", "Run all automated verification");
    verify_step.dependOn(&fmt.step);
    verify_step.dependOn(test_step);
    verify_step.dependOn(integration_step);
    verify_step.dependOn(smoke_step);
    verify_step.dependOn(check_step);
}

const ExecutableOptions = struct {
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    smoke_test: bool,
};

fn addExecutable(
    b: *std.Build,
    options: ExecutableOptions,
) *std.Build.Step.Compile {
    const root_module = createModule(b, .{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        // Keep application code debuggable without running Ghostty's mature
        // VT parser through the prohibitively slow Debug code path.
        .ghostty_optimize = if (options.optimize == .Debug)
            .ReleaseSafe
        else
            options.optimize,
        .include_win32 = true,
    });
    const build_options = b.addOptions();
    build_options.addOption(bool, "smoke_test", options.smoke_test);
    root_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = root_module,
        .use_llvm = true,
    });
    if (options.target.result.os.tag == .windows) exe.subsystem = .Windows;
    return exe;
}

const ModuleOptions = struct {
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ghostty_optimize: ?std.builtin.OptimizeMode = null,
    include_win32: bool,
};

fn createModule(
    b: *std.Build,
    options: ModuleOptions,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = options.target,
        .optimize = options.optimize,
    });

    const ghostty = b.dependency("ghostty", .{
        .target = options.target,
        .optimize = options.ghostty_optimize orelse options.optimize,
        .@"emit-lib-vt" = true,
        .simd = false,
    });
    module.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    if (options.include_win32) {
        const win32 = b.dependency("win32", .{});
        module.addImport("win32", win32.module("win32"));
    }

    return module;
}
