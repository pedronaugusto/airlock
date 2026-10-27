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

test "a path's components are found from the end" {
    try std.testing.expectEqual(@as(usize, 1), previousSeparator("a/b", 3));
    try std.testing.expectEqual(@as(usize, 0), previousSeparator("a/b", 1));
    try std.testing.expectEqual(@as(usize, 1), previousSeparator("a//b", 4));
    try std.testing.expectEqual(@as(usize, 0), previousSeparator("abc", 3));
}
