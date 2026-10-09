const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //=====================================================================
    // The module. Pure Zig over `std` and three of aegis's namespaces
    // (`aegis.id`, `aegis.handle`, `aegis.assert`, std-only themselves):
    // nothing to link and no build options, so nothing a consumer has to
    // match. The seam in front of its raw calls is a module of its own that
    // only airlock and `airlock.testing` import, so neither exports it.
    //=====================================================================

    const module = airlockModule(b, target, optimize);
    b.modules.put(b.graph.arena, "airlock", module) catch @panic("OOM");

    // Everything below is airlock's own: a project depending on airlock
    // neither needs nor fetches shakedown or preflight.
    if (b.pkg_hash.len != 0) return;

    //=====================================================================
    // Tests, on `airlock.testing`. shakedown is a lazy, test-only
    // dependency: production airlock imports nothing of ours. Its error is
    // returned last, so one configure pass asks for it and for preflight
    // together.
    //=====================================================================

    const test_filter = b.option([]const u8, "test-filter", "Select tests by name");
    const tests = b.addTest(.{
        .name = "airlock-tests",
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "seam", .module = module.import_table.get("seam").? }},
        }),
    });
    for (aegisImports(b, target, optimize)) |import| tests.root_module.addImport(import.name, import.module);
    var needed: error{LazyDependencyNeeded}!void = {};
    if (testingModule(b, module)) |seam| {
        tests.root_module.addImport("airlock.testing", seam);
        tests.root_module.addImport("shakedown", seam.import_table.get("shakedown").?);
    } else |err| needed = err;

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

    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // CI wiring and the benchmarks. preflight is lazy and only this tree
    // asks for it. `zig build bench` times bench/main.zig in ReleaseFast
    // by hand; CI invokes `--smoke`, which returns without measuring rows.
    //=====================================================================

    if (b.lazyImport(@This(), "preflight")) |preflight| {
        preflight.addCi(b, .{
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
        preflight.addConsumerCheck(b, .{
            .package = "airlock",
            .program = b.path("ci/consumer.zig"),
            .packages = &.{b.dependency("aegis", .{ .target = target, .optimize = optimize })},
        });
    }
    return needed;
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
    for (aegisImports(b, target, optimize)) |import| module.addImport(import.name, import.module);
    return module;
}

/// The aegis namespaces airlock imports, each as its own module: ids for the
/// volume and device numbers, typed indices for a batch's slots, and the
/// always-on contracts.
fn aegisImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) [3]std.Build.Module.Import {
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize });
    return .{
        .{ .name = "aegis.id", .module = aegis.module("aegis.id") },
        .{ .name = "aegis.handle", .module = aegis.module("aegis.handle") },
        .{ .name = "aegis.assert", .module = aegis.module("aegis.assert") },
    };
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
            .{ .name = "aegis.assert", .module = airlock.import_table.get("aegis.assert").? },
            .{ .name = "shakedown", .module = shakedown },
        },
    });
}

/// The published `airlock.testing`, made once per build of the package.
fn testingModule(b: *std.Build, airlock: *std.Build.Module) error{LazyDependencyNeeded}!*std.Build.Module {
    if (b.modules.get("airlock.testing")) |made| return made;
    const shakedown = try b.dependencyLazy("shakedown", .{ .target = airlock.resolved_target.?, .optimize = airlock.optimize.? });
    const module = seamModule(b, airlock, shakedown.module("shakedown"));
    b.modules.put(b.graph.arena, "airlock.testing", module) catch @panic("OOM");
    return module;
}

/// airlock and its seam again, in the mode a benchmark builds in: an
/// imported module keeps its own mode, so a ReleaseFast benchmark over the
/// Debug module would time the Debug module.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const airlock = airlockModule(b, target, optimize);
    // The tests asked for shakedown first; until it is fetched the build
    // stops before anything is compiled.
    const shakedown = b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize }) catch
        return b.allocator.dupe(std.Build.Module.Import, &.{.{ .name = "airlock", .module = airlock }}) catch @panic("OOM");
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "airlock", .module = airlock },
        .{ .name = "airlock.testing", .module = seamModule(b, airlock, shakedown.module("shakedown")) },
    }) catch @panic("OOM");
}
