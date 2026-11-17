//! The parts of a path airlock takes apart: where its base starts, its
//! parent, its components. The paths are a caller's bytes, so these are
//! pure and fuzzed (src/fuzz_test.zig): any input gives indexes inside it,
//! never a read past either end.

const builtin = @import("builtin");
const std = @import("std");

const is_windows = builtin.target.os.tag == .windows;

pub fn isSeparator(c: u8) bool {
    return c == '/' or (is_windows and c == '\\');
}

/// Where the last component of `path` starts: after its last separator,
/// or 0.
pub fn baseStart(path: []const u8) usize {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (isSeparator(path[i - 1])) return i;
    }
    return 0;
}

/// The directory part of `path`, given where its base starts (not 0): "/"
/// for a name at the root.
pub fn parentPath(path: []const u8, base_start: usize) []const u8 {
    return if (base_start == 1) path[0..1] else path[0 .. base_start - 1];
}

/// Where the separator before `end` is in `path`, or 0: the end of the
/// component before the one that ends at `end`.
pub fn previousSeparator(path: []const u8, end: usize) usize {
    var i = end;
    while (i > 0 and !isSeparator(path[i - 1])) i -= 1;
    while (i > 0 and isSeparator(path[i - 1])) i -= 1;
    return i;
}

/// `path`'s length without its trailing separators.
pub fn trimmedEnd(path: []const u8) usize {
    var end = path.len;
    while (end > 0 and isSeparator(path[end - 1])) end -= 1;
    return end;
}

/// The components of `path[start..end]`, in order, the empty ones and `.`
/// left out.
pub const Components = struct {
    path: []const u8,
    at: usize,
    end: usize,

    pub fn next(c: *Components) ?[]const u8 {
        while (c.at < c.end) {
            while (c.at < c.end and isSeparator(c.path[c.at])) c.at += 1;
            var j = c.at;
            while (j < c.end and !isSeparator(c.path[j])) j += 1;
            const name = c.path[c.at..j];
            c.at = j;
            if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
            return name;
        }
        return null;
    }
};

/// Why a path from untrusted input does not stay beneath the directory it
/// is resolved in.
pub const Escape = enum {
    /// No component: empty, separators alone, or `.` alone.
    empty,
    /// It starts at a root: a separator (on Windows a UNC share too).
    absolute,
    /// A `..` component.
    parent,
    /// A NUL byte, which no system call takes.
    nul,
    /// Windows: a `:`, a drive (`C:x` is relative to that drive's own
    /// directory) or an alternate data stream (`a:b`).
    colon,
    /// Windows: a device name (`CON`, `NUL`, `AUX`, `PRN`, `COM1`, `LPT1`,
    /// ... with any extension), which names the device in every directory.
    device,
    /// Windows: a component ending in `.` or a space, which Windows strips
    /// (`.. ` is `..`).
    trailing,
    /// A component is a symbolic link (on Windows a junction too): found by
    /// the walk, not by `escapes`.
    link,
};

/// Where `path` escapes, and why: the component's bounds in it.
pub const Escaped = struct { why: Escape, start: usize, end: usize };

/// Whether `path`, from untrusted input, stays beneath the directory it is
/// resolved in by its text alone: null when it does. Empty components and
/// `.` are passed over; the rules marked Windows hold there alone, where the
/// system reads names that way. Pure: any input gives bounds inside it.
pub fn escapes(path: []const u8) ?Escaped {
    if (path.len != 0 and isSeparator(path[0])) return .{ .why = .absolute, .start = 0, .end = 1 };
    var named = false;
    var at: usize = 0;
    while (at < path.len) {
        while (at < path.len and isSeparator(path[at])) at += 1;
        var j = at;
        while (j < path.len and !isSeparator(path[j])) j += 1;
        const name = path[at..j];
        defer at = j;
        if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
        const why: ?Escape = if (std.mem.findScalar(u8, name, 0) != null)
            .nul
        else if (std.mem.eql(u8, name, ".."))
            .parent
        else if (is_windows) windowsEscape(name) else null;
        if (why) |w| return .{ .why = w, .start = at, .end = j };
        named = true;
    }
    if (!named) return .{ .why = .empty, .start = 0, .end = path.len };
    return null;
}

fn windowsEscape(name: []const u8) ?Escape {
    if (std.mem.findScalar(u8, name, ':') != null) return .colon;
    const last = name[name.len - 1];
    if (last == '.' or last == ' ') return .trailing;
    if (isDevice(name)) return .device;
    return null;
}

/// Whether `name`'s stem (up to its first `.`, trailing spaces off) is one
/// of Windows' device names, in any case: `COM` and `LPT` with a digit or
/// a superscript one, two or three.
fn isDevice(name: []const u8) bool {
    var stem = name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
    while (stem.len != 0 and stem[stem.len - 1] == ' ') stem = stem[0 .. stem.len - 1];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    if (stem.len < 4) return false;
    const prefix = stem[0..3];
    if (!std.ascii.eqlIgnoreCase(prefix, "COM") and !std.ascii.eqlIgnoreCase(prefix, "LPT")) return false;
    const digit = stem[3..];
    if (digit.len == 1) return std.ascii.isDigit(digit[0]);
    // ¹ ² ³ in UTF-8.
    return digit.len == 2 and digit[0] == 0xc2 and (digit[1] == 0xb9 or digit[1] == 0xb2 or digit[1] == 0xb3);
}

test "a path escapes by a root, a parent, a NUL, or nothing named; on Windows by a colon, a device or a stripped end" {
    const T = std.testing;
    try T.expectEqual(null, escapes("a/b/c.txt"));
    try T.expectEqual(null, escapes("a//./b/"));
    try T.expectEqual(null, escapes("..a/b..c/...d"));
    try T.expectEqual(Escape.absolute, escapes("/etc/passwd").?.why);
    try T.expectEqual(Escape.parent, escapes("a/../../b").?.why);
    try T.expectEqualStrings("..", "a/../../b"[escapes("a/../../b").?.start..escapes("a/../../b").?.end]);
    try T.expectEqual(Escape.nul, escapes("a/b\x00c").?.why);
    for ([_][]const u8{ "", "/", ".", "./.", "//" }) |p| {
        const e = escapes(p).?;
        try T.expect(e.why == .empty or e.why == .absolute);
    }
    if (is_windows) {
        try T.expectEqual(Escape.absolute, escapes("\\\\server\\share\\x").?.why);
        try T.expectEqual(Escape.colon, escapes("C:x").?.why);
        try T.expectEqual(Escape.colon, escapes("a/b:stream").?.why);
        try T.expectEqual(Escape.trailing, escapes("a/.. ").?.why);
        try T.expectEqual(Escape.trailing, escapes("a/b.").?.why);
        try T.expectEqual(Escape.device, escapes("a/nul.txt").?.why);
        try T.expectEqual(Escape.device, escapes("CON").?.why);
        try T.expectEqual(Escape.device, escapes("com1 .log").?.why);
        try T.expectEqual(Escape.device, escapes("LPT\xc2\xb9").?.why);
        try T.expectEqual(null, escapes("console/com10/lpt"));
    } else {
        try T.expectEqual(null, escapes("C:x/nul.txt/a. "));
    }
}

test "a path's components are found from the end" {
    try std.testing.expectEqual(@as(usize, 1), previousSeparator("a/b", 3));
    try std.testing.expectEqual(@as(usize, 0), previousSeparator("a/b", 1));
    try std.testing.expectEqual(@as(usize, 1), previousSeparator("a//b", 4));
    try std.testing.expectEqual(@as(usize, 0), previousSeparator("abc", 3));
}
