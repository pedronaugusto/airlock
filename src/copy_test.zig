//! `copyFile`: a durable copy, cloned where the filesystem clones, copied
//! where it does not, and never under its name until whole.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");

const is_darwin = builtin.target.os.tag.isDarwin();

fn expectSame(io: Io, dir: Io.Dir, a: []const u8, b: []const u8) !void {
    const gpa = testing.allocator;
    const x = try dir.readFileAlloc(io, a, gpa, .unlimited);
    defer gpa.free(x);
    const y = try dir.readFileAlloc(io, b, gpa, .unlimited);
    defer gpa.free(y);
    try testing.expectEqualSlices(u8, x, y);
}

fn source(io: Io, dir: Io.Dir, name: []const u8, len: usize, seed: u64) !void {
    const gpa = testing.allocator;
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    var prng: std.Random.DefaultPrng = .init(seed);
    prng.random().bytes(bytes);
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

test "a copy holds the source's bytes at every size, cloned where the filesystem clones" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]usize{ 0, 1, 4095, 4096, 65537, 1 << 20 }, 0..) |len, i| {
        try source(io, tmp.dir, "src", len, i);
        const auto = try airlock.copyFile(io, tmp.dir, "src", tmp.dir, "dst", .{});
        try expectSame(io, tmp.dir, "src", "dst");
        // APFS clones; the CI's ext4 and NTFS copy.
        if (is_darwin) try testing.expectEqual(.clone, auto.by);
        const copied = try airlock.copyFile(io, tmp.dir, "src", tmp.dir, "dst", .{ .clone = .never });
        try testing.expectEqual(.copy, copied.by);
        try expectSame(io, tmp.dir, "src", "dst");
    }
}

test "clone always: a clone, or CloneUnsupported with nothing published" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try source(io, tmp.dir, "src", 10000, 7);
    if (airlock.copyFile(io, tmp.dir, "src", tmp.dir, "dst", .{ .clone = .always })) |copied| {
        try testing.expectEqual(.clone, copied.by);
        try expectSame(io, tmp.dir, "src", "dst");
    } else |err| {
        try testing.expectEqual(error.CloneUnsupported, err);
        try testing.expectError(error.FileNotFound, tmp.dir.access(io, "dst", .{}));
    }
}

test "a copy replaces its destination whole, and a missing source touches nothing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dst", .data = "old" });
    try testing.expectError(error.FileNotFound, airlock.copyFile(io, tmp.dir, "missing", tmp.dir, "dst", .{}));
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("old", try tmp.dir.readFile(io, "dst", &buffer));
    try source(io, tmp.dir, "src", 3000, 3);
    _ = try airlock.copyFile(io, tmp.dir, "src", tmp.dir, "dst", .{});
    try expectSame(io, tmp.dir, "src", "dst");
    // Only the copy is left: no temp beside it.
    var names: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |_| names += 1;
    try testing.expectEqual(2, names);
}

test "a copy takes the source's permissions, or those asked" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try source(io, tmp.dir, "src", 100, 1);
    try tmp.dir.setFilePermissions(io, "src", .fromMode(0o640), .{});
    for ([_]bool{ true, false }) |clone| {
        _ = try airlock.copyFile(io, tmp.dir, "src", tmp.dir, "a", .{ .clone = if (clone) .auto else .never });
        try testing.expectEqual(0o640, (try tmp.dir.statFile(io, "a", .{})).permissions.toMode() & 0o777);
        _ = try airlock.copyFile(io, tmp.dir, "src", tmp.dir, "b", .{ .clone = if (clone) .auto else .never, .mode = .{ .exact = .fromMode(0o600) } });
        try testing.expectEqual(0o600, (try tmp.dir.statFile(io, "b", .{})).permissions.toMode() & 0o777);
    }
}

const seam = @import("airlock.testing");
const Seam = seam.Seam;
const is_linux = builtin.target.os.tag == .linux;

test "a refused clone is a copy, and a failed clone publishes nothing" {
    // Only where airlock asks for a clone; elsewhere it copies without asking.
    if (!is_linux and !is_darwin) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try source(testing.io, tmp.dir, "src", 5000, 9);
    {
        const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.always(.clone, .XDEV)} });
        defer h.destroy();
        const copied = try airlock.copyFile(h.io(), tmp.dir, "src", tmp.dir, "dst", .{});
        try testing.expectEqual(.copy, copied.by);
        try testing.expectEqual(1, h.count(.clone));
        try expectSame(testing.io, tmp.dir, "src", "dst");
        try testing.expectError(error.CloneUnsupported, airlock.copyFile(h.io(), tmp.dir, "src", tmp.dir, "other", .{ .clone = .always }));
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "other", .{}));
    }
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.always(.clone, .IO)} });
    defer h.destroy();
    try testing.expectError(error.InputOutput, airlock.copyFile(h.io(), tmp.dir, "src", tmp.dir, "failed", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "failed", .{}));
    // Nothing beside the two files: the failed copy's temp is gone.
    var names: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |_| names += 1;
    try testing.expectEqual(2, names);
}
