//! Fuzz targets for what airlock takes apart: a caller's path. Every name
//! airlock makes durable is found in one (its base, its parent, the
//! directories `makePath` walks), so the walk over its bytes is a parser.
//!
//! Each target holds the same contract: any path gives indexes inside it
//! and slices of it, never a read past either end, and the parts it gives
//! are the parts a plain split would. They are shakedown `check`
//! properties: `zig build test` runs seeded cases, and `zig build test
//! --fuzz` searches.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = shakedown.gen;
const Case = shakedown.Case;
const Source = shakedown.Source;
const paths = @import("paths.zig");

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
