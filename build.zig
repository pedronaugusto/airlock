const std = @import("std");

/// What a project that depends on airlock builds: the `airlock` module, pure Zig
/// over `std` and aegis (its `id`, `handle` and `assert` namespaces), with
/// nothing to link and no build options, so nothing a consumer has to match.
/// The seam in front of its raw calls is a module of its own that only airlock
/// and `airlock.testing` import, so neither exports it. `airlock.testing` is
/// made by `testing`, and only a build that calls it fetches shakedown.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    b.modules.put(b.graph.arena, "airlock", airlockModule(b, target, optimize)) catch @panic("OOM");
}

/// airlock's development: its tests, example and benchmarks under preflight's
/// gate. The tests run on `airlock.testing` over shakedown, which airlock ships
/// lazily for that seam; it is bound to airlock's aegis. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const package = b.dependency("airlock", .{ .target = target, .optimize = optimize });
    const p = package.builder;
    const module = package.module("airlock");
    // Fetches shakedown on the first pass, which ends here until it is there.
    const seam = testing(package) catch return;

    //=====================================================================
    // Tests, on `airlock.testing`. Production airlock imports nothing of
    // ours; shakedown is the seam's, fetched only by a build that asks for it.
    //=====================================================================

    const tests = b.addTest(.{
        .name = "airlock-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = p.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "seam", .module = module.import_table.get("seam").? }},
        }),
    });
    tests.root_module.addImport("aegis", aegisModule(p, target, optimize));
    tests.root_module.addImport("airlock.testing", seam);
    tests.root_module.addImport("shakedown", seam.import_table.get("shakedown").?);

    const test_step = b.step("test", "Run the tests, the example and benchmark startup");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const check_step = b.step("check", "Compile the tests and the example without running them");
    check_step.dependOn(&tests.step);

    //=====================================================================
    // Example: built AND run against the module a consumer gets.
    // examples/usage.zig is also README.md's Usage block (zig build docs --
    // usage), so the snippet a reader copies is code CI executes.
    //=====================================================================

    const example = b.addExecutable(.{
        .name = "usage",
        .root_module = b.createModule(.{
            .root_source_file = p.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "airlock", .module = module }},
        }),
    });
    const example_run = b.addRunArtifact(example);
    example_run.setCwd(p.path("."));
    const examples_step = b.step("examples", "Build and run the usage example");
    examples_step.dependOn(&example_run.step);
    test_step.dependOn(examples_step);
    check_step.dependOn(&example.step);

    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // The gate and the benchmarks. `bay bench` times bench/main.zig in ReleaseFast
    // by hand; CI invokes `--smoke`, which returns without measuring rows.
    //=====================================================================

    tools.preflight.addCi(b, p, .{
        .tests = test_step,
        .portable_tests = true,
        .bench = .{
            .programs = &.{
                .{ .name = "airlock-bench", .source = "bench/main.zig" },
                .{ .name = "airlock-macos-batch", .source = "bench/macos_batch.zig" },
            },
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
        },
    });
    // A project that depends on airlock by path, with no packages to
    // fetch: the build a consumer gets.
    tools.preflight.addConsumerCheck(b, p, .{
        .package = "airlock",
        .program = p.path("ci/consumer.zig"),
        .packages = &.{p.dependency("aegis", .{ .target = target, .optimize = optimize })},
    });
}

/// The test seam for a project's tests: the module `airlock.testing`, on
/// shakedown, for `airlock`'s dependency in that project's build.
///
///     const airlock_build = @import("airlock"); // at the top of the build.zig
///
///     const airlock = b.dependency("airlock", .{ .target = target, .optimize = optimize });
///     tests.root_module.addImport("airlock.testing", try airlock_build.testing(airlock));
///
/// Only a build that calls this fetches shakedown: while it is being
/// fetched this returns `error.LazyDependencyNeeded`, as
/// `std.Build.dependencyLazy` does, for the build function to return.
pub fn testing(airlock: *std.Build.Dependency) error{LazyDependencyNeeded}!*std.Build.Module {
    return testingModule(airlock.builder, airlock.module("airlock"));
}

/// `airlock` and the seam module it imports, built for `target` and
/// `optimize`.
fn airlockModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const seam = b.createModule(.{
        .root_source_file = b.path("src/seam.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/airlock.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "seam", .module = seam }},
    });
    module.addImport("aegis", aegisModule(b, target, optimize));
    return module;
}

/// aegis, from which airlock takes ids for the volume and device numbers, typed
/// indices for a batch's slots, and the always-on contracts.
fn aegisModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    return b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
}

/// `airlock.testing` over `airlock`'s own seam: the hook it builds is the
/// one that `airlock`'s raw calls look for.
fn seamModule(b: *std.Build, airlock: *std.Build.Module, shakedown: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/testing.zig"),
        .target = airlock.resolved_target,
        .optimize = airlock.optimize,
        .imports = &.{
            .{ .name = "seam", .module = airlock.import_table.get("seam").? },
            .{ .name = "aegis", .module = airlock.import_table.get("aegis").? },
            .{ .name = "shakedown", .module = shakedown },
        },
    });
}

/// The published `airlock.testing`, made once per build of the package.
fn testingModule(b: *std.Build, airlock: *std.Build.Module) error{LazyDependencyNeeded}!*std.Build.Module {
    if (b.modules.get("airlock.testing")) |made| return made;
    // One aegis is linked: shakedown takes airlock's own.
    const shakedown = try b.dependencyLazy("shakedown", .{ .target = airlock.resolved_target.?, .optimize = airlock.optimize.?, .aegis = .consumer });
    shakedown.module("shakedown").addImport("aegis", airlock.import_table.get("aegis").?);
    const module = seamModule(b, airlock, shakedown.module("shakedown"));
    b.modules.put(b.graph.arena, "airlock.testing", module) catch @panic("OOM");
    return module;
}

/// airlock and its seam again, in the mode a benchmark builds in: an
/// imported module keeps its own mode, so a ReleaseFast benchmark over the
/// Debug module would time the Debug module. `b` is the development build.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const p = b.dependency("airlock", .{ .target = target, .optimize = optimize }).builder;
    const airlock = airlockModule(p, target, optimize);
    // The same binding as `testing` makes, over a module of this mode.
    const shakedown = p.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    shakedown.module("shakedown").addImport("aegis", airlock.import_table.get("aegis").?);
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "airlock", .module = airlock },
        .{ .name = "shakedown", .module = shakedown.module("shakedown") },
        .{ .name = "airlock.testing", .module = seamModule(p, airlock, shakedown.module("shakedown")) },
    }) catch @panic("OOM");
}
