//! Fuzz targets for what airlock takes apart: a caller's path. Every name
//! airlock makes durable is found in one (its base, its parent, the
//! directories `makePath` walks), so the walk over its bytes is a parser.
//! And for what it copies: a file of any size, with holes anywhere.
//!
//! Each path target holds the same contract: any path gives indexes inside
//! it and slices of it, never a read past either end, and the parts it
//! gives are the parts a plain split would. The copy target holds that a
//! copy, cloned or not, is the source byte for byte. They are shakedown
//! `check` properties: `zig build test` runs seeded cases, and `zig build
//! test --fuzz` searches.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Case = shakedown.Case;
const Source = shakedown.Source;
const paths = @import("paths.zig");
const airlock = @import("airlock.zig");

/// A path whose bytes lean to the ones that matter: separators, dots,
/// a name's letter, and now and then anything at all, so the walks meet
/// runs of separators, `.` and `..`, and the empty components between.
fn pathInto(s: *Source, out: []u8) []u8 {
    const len = gen.intRange(s, usize, 0, out.len);
    for (out[0..len]) |*b| b.* = switch (gen.int(s, u3)) {
        0, 1 => '/',
        2 => '\\',
        3, 4 => '.',
        5, 6 => 'a',
        7 => gen.int(s, u8),
    };
    return out[0..len];
}

/// Whether `part` is a slice of `whole`.
fn inside(whole: []const u8, part: []const u8) bool {
    const start = @intFromPtr(whole.ptr);
    const at = @intFromPtr(part.ptr);
    return at >= start and at + part.len <= start + whole.len;
}

fn noSeparator(bytes: []const u8) bool {
    for (bytes) |c| if (paths.isSeparator(c)) return false;
    return true;
}

test "a path's base and parent are found inside it" {
    try shakedown.check(testing.allocator, {}, fuzzBase, .{});
}

fn fuzzBase(_: void, c: *Case) !void {
    var buffer: [48]u8 = undefined;
    const path = pathInto(c.source, &buffer);
    const b = paths.baseStart(path);
    try testing.expect(b <= path.len);
    try testing.expect(noSeparator(path[b..]));
    try testing.expect(b == 0 or paths.isSeparator(path[b - 1]));
    if (b != 0) {
        const parent = paths.parentPath(path, b);
        try testing.expect(inside(path, parent) and parent.ptr == path.ptr);
        // The root is its own parent: "/" for a name under it.
        try testing.expect(parent.len <= b and parent.len != 0);
    }
    const end = paths.trimmedEnd(path);
    try testing.expect(end <= path.len);
    try testing.expect(end == 0 or !paths.isSeparator(path[end - 1]));
    for (path[end..]) |ch| try testing.expect(paths.isSeparator(ch));
}

test "the walk back from a component ends at the one before it" {
    try shakedown.check(testing.allocator, {}, fuzzBack, .{});
}

fn fuzzBack(_: void, c: *Case) !void {
    var buffer: [48]u8 = undefined;
    const path = pathInto(c.source, &buffer);
    const end = gen.intRange(c.source, usize, 0, path.len);
    const back = paths.previousSeparator(path, end);
    try testing.expect(back <= end);
    try testing.expect(back == 0 or !paths.isSeparator(path[back - 1]));
    // Past `back`: separators, then one component reaching `end`.
    var i = back;
    while (i < end and paths.isSeparator(path[i])) i += 1;
    try testing.expect(back == 0 or i > back);
    try testing.expect(noSeparator(path[i..end]));
}

test "the components of a path are its names, the empty ones and . left out" {
    try shakedown.check(testing.allocator, {}, fuzzComponents, .{});
}

fn fuzzComponents(_: void, c: *Case) !void {
    var buffer: [48]u8 = undefined;
    const path = pathInto(c.source, &buffer);
    const start = gen.intRange(c.source, usize, 0, path.len);
    const end = gen.intRange(c.source, usize, start, path.len);
    // The names a plain split finds, in order.
    var expected: [48][]const u8 = undefined;
    var n: usize = 0;
    var split = std.mem.splitAny(u8, path[start..end], if (@import("builtin").target.os.tag == .windows) "/\\" else "/");
    while (split.next()) |name| {
        if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
        expected[n] = name;
        n += 1;
    }
    var components: paths.Components = .{ .path = path, .at = start, .end = end };
    var seen: usize = 0;
    while (components.next()) |name| : (seen += 1) {
        try testing.expect(seen < n);
        try testing.expect(inside(path[start..end], name));
        try testing.expect(name.len != 0 and noSeparator(name) and !std.mem.eql(u8, name, "."));
        try testing.expectEqualStrings(expected[seen], name);
    }
    try testing.expectEqual(n, seen);
}

test "a copy is its source byte for byte, or its first bytes, at any size and with holes anywhere" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try shakedown.check(testing.allocator, tmp.dir, fuzzCopy, .{ .cases = 64 });
}

/// The largest source a case makes: a few of its 64 KiB clone granules,
/// past one copy buffer.
const max_copy = 256 * 1024;

fn fuzzCopy(dir: std.Io.Dir, c: *Case) !void {
    const io = testing.io;
    const gpa = testing.allocator;
    const len = gen.intRange(c.source, usize, 0, max_copy);
    // What the source reads as: zeros where no extent was written.
    const expected = try gpa.alloc(u8, len);
    defer gpa.free(expected);
    @memset(expected, 0);
    {
        const src = try dir.createFile(io, "src", .{ .truncate = true });
        defer src.close(io);
        // The length first: what no extent writes is a hole.
        try src.setLength(io, len);
        for (0..gen.intRange(c.source, usize, 0, 4)) |_| {
            if (len == 0) break;
            const at = gen.intRange(c.source, usize, 0, len - 1);
            const extent = expected[at..][0..gen.intRange(c.source, usize, 1, len - at)];
            _ = gen.bytesInto(c.source, extent);
            try src.writePositionalAll(io, extent, at);
        }
    }
    // The bytes are the property; durability is the crash model's.
    const how = gen.oneOf(c.source, airlock.Clone, &.{ .auto, .never });
    if (gen.oneOf(c.source, bool, &.{ false, true })) {
        // A prefix, through a pending: what a writer had appended so far.
        const limit = gen.intRange(c.source, usize, 0, len);
        const src = try dir.openFile(io, "src", .{});
        defer src.close(io);
        var p = try airlock.create(io, dir, "dst", .{});
        defer p.discard(io);
        try testing.expectEqual(.copy, try p.copyFrom(io, src, .{ .clone = how, .limit = limit }));
        _ = try p.commit(io, .{ .level = .none });
        const got = try dir.readFileAlloc(io, "dst", gpa, .unlimited);
        defer gpa.free(got);
        return testing.expectEqualSlices(u8, expected[0..limit], got);
    }
    const copied = try airlock.copyFile(io, dir, "src", dir, "dst", .{ .clone = how, .commit = .{ .level = .none } });
    if (how == .never) try testing.expectEqual(.copy, copied.by);
    const got = try dir.readFileAlloc(io, "dst", gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, expected, got);
}
