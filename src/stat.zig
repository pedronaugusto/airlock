//! What a path is, as the platform's own stat reports it: the fields
//! `std.Io.File.Stat` carries and those it leaves out (the device, the
//! owner and group, the mode's bits, a creation time; on Windows the
//! attributes and a reparse point's tag), in one call. A path that is not
//! there and a path through something that is not a directory are told
//! apart, as the platform tells them apart: `FileNotFound` and `NotDir`.
//!
//! A raw call like airlock's others: a test's seam decides it, and over a
//! simulation it is the `Io`'s own stat, on the one volume the simulation
//! is, with no owner.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");

/// Everything one stat of a path reports.
pub const Stat = sys.Full;

pub const Options = struct {
    /// Follow a symbolic link, as opening the path would.
    follow_symlinks: bool = false,
};

pub const Error = sys.StatPathError;

/// The stat of what `sub_path` names relative to `dir` (which an absolute
/// `sub_path` ignores). On POSIX one `statx` or `fstatat`; on Windows the
/// file is opened for its attributes only and asked by handle.
pub fn stat(io: Io, dir: Io.Dir, sub_path: []const u8, options: Options) Error!Stat {
    return sys.statPath(io, dir.handle, sub_path, options.follow_symlinks);
}

test "a stat reports the file, and tells a missing name from a file in the way" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "hello" });
    const found = try stat(io, tmp.dir, "f", .{});
    try std.testing.expectEqual(Io.File.Kind.file, found.kind);
    try std.testing.expectEqual(@as(u64, 5), found.size);
    const std_stat = try tmp.dir.statFile(io, "f", .{});
    try std.testing.expectEqual(std_stat.mtime.nanoseconds, found.mtime.nanoseconds);
    try std.testing.expectEqual(@as(u64, @intCast(std_stat.inode)), found.inode);
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectEqual(@as(u32, 0o100000), found.mode & 0o170000);
        try std.testing.expect(found.device != 0);
    }

    try std.testing.expectError(error.FileNotFound, stat(io, tmp.dir, "absent", .{}));
    try std.testing.expectError(error.FileNotFound, stat(io, tmp.dir, "absent/below", .{}));
    // Windows answers a path through a file as a path not found.
    const through_file = stat(io, tmp.dir, "f/below", .{});
    if (builtin.target.os.tag == .windows)
        try std.testing.expectError(error.FileNotFound, through_file)
    else
        try std.testing.expectError(error.NotDir, through_file);
}

test "a stat follows a symbolic link only when asked" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "abc" });
    try tmp.dir.symLink(io, "target", "link", .{});
    try std.testing.expectEqual(Io.File.Kind.sym_link, (try stat(io, tmp.dir, "link", .{})).kind);
    const followed = try stat(io, tmp.dir, "link", .{ .follow_symlinks = true });
    try std.testing.expectEqual(Io.File.Kind.file, followed.kind);
    try std.testing.expectEqual(@as(u64, 3), followed.size);
}

test "a stat is a raw call a seam decides" {
    const io = std.testing.io;
    const testing = @import("airlock.testing");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    const s = try testing.Seam.create(std.testing.allocator, io, .{
        .plan = &.{testing.fail(.stat, 1, if (builtin.target.os.tag == .windows) .ACCESS_DENIED else .ACCES)},
    });
    defer s.destroy();
    try std.testing.expectError(error.AccessDenied, stat(s.io(), tmp.dir, "f", .{}));
    _ = try stat(s.io(), tmp.dir, "f", .{});
    try std.testing.expectEqual(@as(u32, 2), s.count(.stat));
}
