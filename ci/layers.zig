//! Source layers, lowest first. Every production source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "seam", .patterns = &.{
        "src/seam.zig",
    } },
    .{ .name = "primitives", .patterns = &.{
        "src/Blocking.zig",
        "src/level.zig",
        "src/sys.zig",
    } },
    .{ .name = "platform", .patterns = &.{
        "src/platform.zig",
        "src/FileId.zig",
    } },
    .{ .name = "staging", .patterns = &.{
        "src/Staged.zig",
    } },
    .{ .name = "operations", .patterns = &.{
        "src/Pending.zig",
        "src/names.zig",
    } },
    .{ .name = "batch", .patterns = &.{
        "src/Batch.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/airlock.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

/// The seam is a module of its own, so airlock and `airlock.testing` share
/// it without either exporting it.
pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "seam", .path = "src/seam.zig" },
    .{ .name = "airlock.testing", .path = "src/testing.zig" },
};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "aegis.assert",
        "aegis.handle",
        "aegis.id",
        "airlock",
        "builtin",
        "shakedown",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};

/// Tokens only their owner may spell: every sync, rename and identity call
/// airlock makes goes through `src/sys.zig`, where each code is mapped and
/// the test seam sits in front of it. Moved here from strand, with the
/// calls airlock adds.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "raw calls owner", .tokens = &.{
        "fsync",
        "fdatasync",
        "F_FULLFSYNC",
        "FULLFSYNC",
        "F_BARRIERFSYNC",
        "BARRIERFSYNC",
        "FlushFileBuffers",
        "NtFlushBuffersFile",
        "NtFlushBuffersFileEx",
        "statx",
        "fstat",
        "fstatat",
        "FILE_ID_INFO",
        "renameat",
        "renameat2",
        "renameatx_np",
        "linkat",
        "unlinkat",
        "mkdirat",
        "symlinkat",
    }, .owners = &.{ "src/sys.zig", "bench/primitives.zig", "bench/baseline/**" } },
};
