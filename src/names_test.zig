//! `rename`, `remove` and `FileId`.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");
const harness = @import("testing/harness.zig");
const Harness = harness.Harness;

const os = builtin.os.tag;
const is_windows = os == .windows;
const is_linux = os == .linux;
const is_darwin = os.isDarwin();
const is_tested_os = is_linux or is_darwin or is_windows;

test "a rename within one directory syncs it once; across two, both" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "1");
    try s.dir().createDirPath(testing.io, "sub");
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    try testing.expectEqual(airlock.Reached.full, try airlock.rename(io, s.dir(), "a", s.dir(), "b", .{}));
    try testing.expectEqual(@as(u32, 1), h.count(.sync_dir));
    h.reset();
    try testing.expectEqual(airlock.Reached.full, try airlock.rename(io, s.dir(), "b", s.dir(), "sub/c", .{}));
    // sub/ received the name and the root lost it: both are synced.
    try testing.expectEqual(@as(u32, 2), h.count(.sync_dir));
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("1", s.read("sub/c", &buffer).?);
    try testing.expectEqual(@as(?[]const u8, null), s.read("b", &buffer));
    h.reset();
    try testing.expectEqual(airlock.Reached.none, try airlock.rename(io, s.dir(), "sub/c", s.dir(), "d", .{ .sync = .{ .level = .ordered } }));
    try testing.expectEqual(@as(u32, 0), h.count(.sync_dir));
}

test "a rename replaces, and a missing source is FileNotFound" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "new");
    try s.write("b", "old");
    _ = try airlock.rename(testing.io, s.dir(), "a", s.dir(), "b", .{});
    var buffer: [4]u8 = undefined;
    try testing.expectEqualStrings("new", s.read("b", &buffer).?);
    try testing.expectError(error.FileNotFound, airlock.rename(testing.io, s.dir(), "gone", s.dir(), "b", .{}));
}

test "remove syncs the directory that held the name, even while the file is open" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.dir().createDirPath(testing.io, "sub");
    try s.write("sub/a", "1");
    const held = try s.dir().openFile(testing.io, "sub/a", .{});
    defer held.close(testing.io);
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.full, try airlock.remove(h.io(), s.dir(), "sub/a", .{}));
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), s.read("sub/a", &buffer));
    try testing.expectEqual(@as(u32, 1), h.count(.sync_dir));
    try testing.expectError(error.FileNotFound, airlock.remove(h.io(), s.dir(), "sub/a", .{}));
}

test "a refused directory sync after a rename leaves it ordered, or refuses" {
    if (!is_linux) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "1");
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.sync_dir, .INVAL)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.ordered, try airlock.rename(h.io(), s.dir(), "a", s.dir(), "b", .{}));
    try testing.expectError(error.LevelUnavailable, airlock.rename(h.io(), s.dir(), "b", s.dir(), "c", .{ .sync = .{ .fallback = .refuse } }));
}

test "two handles to one file are one file; two files are two" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    try s.write("one", "1");
    try s.write("two", "2");
    const one = try s.dir().openFile(io, "one", .{});
    defer one.close(io);
    const again = try s.dir().openFile(io, "one", .{});
    defer again.close(io);
    const two = try s.dir().openFile(io, "two", .{});
    defer two.close(io);
    const a = try airlock.FileId.of(io, one);
    try testing.expect(a.eql(try airlock.FileId.of(io, again)));
    const b = try airlock.FileId.of(io, two);
    try testing.expect(!a.eql(b));
    try testing.expectEqual(a.volume, b.volume);
    const dir_file: Io.File = .{ .handle = s.dir().handle, .flags = .{ .nonblocking = false } };
    try testing.expect(!a.eql(try airlock.FileId.of(io, dir_file)));
}

test "a path names what a handle to it is open on, file or directory" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    try s.write("one", "1");
    try s.dir().createDirPath(io, "sub");
    const one = try s.dir().openFile(io, "one", .{});
    defer one.close(io);
    const sub = try s.dir().openDir(io, "sub", .{ .iterate = true });
    defer sub.close(io);
    try testing.expect((try airlock.FileId.ofPath(io, s.dir(), "one", .{})).eql(try airlock.FileId.of(io, one)));
    const sub_file: Io.File = .{ .handle = sub.handle, .flags = .{ .nonblocking = false } };
    try testing.expect((try airlock.FileId.ofPath(io, s.dir(), "sub", .{})).eql(try airlock.FileId.of(io, sub_file)));
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const absolute = buffer[0..try s.dir().realPathFile(io, "one", &buffer)];
    try testing.expect((try airlock.FileId.ofPath(io, Io.Dir.cwd(), absolute, .{})).eql(try airlock.FileId.of(io, one)));
    try testing.expectError(error.FileNotFound, airlock.FileId.ofPath(io, s.dir(), "gone", .{}));
}

test "a symbolic link is followed unless asked not to" {
    if (is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    try s.write("target", "1");
    try s.dir().symLink(io, "target", "link", .{});
    const target = try airlock.FileId.ofPath(io, s.dir(), "target", .{});
    try testing.expect(target.eql(try airlock.FileId.ofPath(io, s.dir(), "link", .{})));
    try testing.expect(!target.eql(try airlock.FileId.ofPath(io, s.dir(), "link", .{ .follow_symlinks = false })));
}

test "a socket cannot be opened as a file, and still has an identity" {
    if (is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buffer[0..try s.dir().realPath(io, &buffer)];
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const sock_path = try std.mem.print(&path_buffer, "{s}/s.sock", .{dir_path});
    if (sock_path.len >= 100) return error.SkipZigTest; // sun_path holds about 104 bytes
    const address = try Io.net.UnixAddress.init(sock_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const by_path = try airlock.FileId.ofPath(io, Io.Dir.cwd(), sock_path, .{});
    try testing.expect(by_path.eql(try airlock.FileId.ofPath(io, s.dir(), "s.sock", .{})));
}
