const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig, `std` only: nothing to link and no build
    // options, so nothing a consumer has to match.
    //=====================================================================

    const module = b.addModule("airlock", .{
        .root_source_file = b.path("src/airlock.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Everything below is airlock's own: a project depending on airlock
    // neither needs nor fetches shakedown or preflight.
    if (b.dep_prefix.len != 0) return;

    //=====================================================================
    // Tests. shakedown is a lazy, test-only dependency: production airlock
    // imports nothing of ours.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{
        .name = "airlock-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize })) |shakedown| {
        tests.root_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |_| {}

    const test_step = b.step("test", "Run the tests and the example");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const check_step = b.step("check", "Compile the tests, example and benchmarks without running them");
    check_step.dependOn(&tests.step);

    //=====================================================================
    // Example: built AND run against the module a consumer gets.
    // examples/usage.zig is also README.md's Usage block (zig build docs --
    // usage), so the snippet a reader copies is code CI executes.
    //=====================================================================

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "airlock", .module = module }},
        }),
    });
    const example_run = b.addRunArtifact(example);
    example_run.setCwd(b.path("."));
    const examples_step = b.step("examples", "Build and run the usage example");
    examples_step.dependOn(&example_run.step);
    test_step.dependOn(examples_step);
    check_step.dependOn(&example.step);

    //=====================================================================
    // Benchmarks: run by hand with `zig build bench`, compiled by CI and
    // never timed there. Results are JSON lines under zig-out/bench/.
    //=====================================================================

    const bench = b.addExecutable(.{
        .name = "airlock-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .fast else optimize,
            .imports = &.{.{ .name = "airlock", .module = module }},
        }),
    });
    if (b.dependencyLazy("shakedown", .{ .target = target, .optimize = .fast })) |shakedown| {
        bench.root_module.addImport("shakedown", shakedown.module("shakedown"));
    } else |_| {}
    const bench_run = b.addRunArtifact(bench);
    bench_run.setCwd(b.path("."));
    bench_run.addPassthruArgs();
    b.step("bench", "Run the benchmarks (by hand; never timed in CI)").dependOn(&bench_run.step);
    check_step.dependOn(&bench.step);

    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // CI wiring. preflight is lazy and only this tree asks for it.
    //=====================================================================

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{ .tests = test_step, .portable_tests = true });
        // A project that depends on airlock by path, with no packages to
        // fetch: the build a consumer gets.
        preflight.addConsumerCheck(b, .{ .package = "airlock", .program = b.path("ci/consumer.zig") });
    }
}
