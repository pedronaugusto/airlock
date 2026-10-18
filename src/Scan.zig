//! One directory's entries, each with its whole stat, read into a buffer
//! the caller owns.
//!
//! A walk that compares a tree against what it recorded asks two things of
//! every entry: its name and its stat. The ordinary way is a directory read
//! and then one stat per name, a call per file. Darwin's
//! `getattrlistbulk(2)` answers both for a batch of entries in one call,
//! the device, owner and group included, so a scan there reads batches; a
//! volume that refuses the call is read the ordinary way, from the start,
//! with nothing lost. Elsewhere a scan is the directory read and one
//! `airlock.stat` per entry (`statx`, `fstatat`; on Windows the attributes
//! and a reparse point's tag, so its kind is the file's, not the listing's).
//!
//! Both arms give the same answer, the stat `airlock.stat` gives the name
//! without following a link, except that a directory's size is zero on
//! either: a batch reports none, a data length being a file's attribute.
//!
//! Over a simulation a scan reads through the `Io` and stats each entry
//! through it: a simulation's handles take no raw call. The batch call is
//! a raw call like airlock's others (`scan`), decided by a test's seam
//! first; failed with `ENOTSUP` it is the volume without one.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const assert = std.debug.assert;
const sys = @import("sys.zig");

const Scan = @This();

dir: Io.Dir,
buffer: []align(@alignOf(usize)) u8,
arm: Arm,

/// One entry and its stat. `name` points into the scan's buffer and is
/// valid until the next call to `next`.
pub const Entry = struct {
    name: []const u8,
    stat: sys.Full,
};

pub const Error = Io.Dir.Reader.Error || sys.StatPathError || error{InputOutput};

/// The smallest buffer a scan reads into: one entry with the longest name
/// on any arm. Sixty-four kilobytes holds several hundred entries in a
/// batch, so a directory of ordinary size is one call.
pub const min_buffer_len = @max(Io.Dir.Reader.min_buffer_len, 1024);

/// Whether this platform has a batch call. A volume may still refuse it.
pub const batch_supported = builtin.target.os.tag.isDarwin();

const Arm = union(enum) {
    /// Nothing read yet: the first `next` chooses the arm.
    start,
    /// Batches: `count` entries left in the buffer from `cursor` on, and
    /// another call when they run out unless the last one was empty.
    batch: struct { cursor: usize, count: u32, done: bool },
    /// The directory read, and one stat per name.
    plain: Io.Dir.Reader,
};

/// A scan of `dir`, opened for iteration, from its first entry, into
/// `buffer` (at least `min_buffer_len` bytes). Reads nothing until `next`.
pub fn init(dir: Io.Dir, buffer: []align(@alignOf(usize)) u8) Scan {
    assert(buffer.len >= min_buffer_len);
    return .{ .dir = dir, .buffer = buffer, .arm = .start };
}

/// A scan that reads the directory the ordinary way on every platform:
/// what a batch is compared against, and how a result is reproduced on a
/// volume that takes the other arm.
pub fn initPlain(dir: Io.Dir, buffer: []align(@alignOf(usize)) u8) Scan {
    assert(buffer.len >= min_buffer_len);
    return .{ .dir = dir, .buffer = buffer, .arm = .{ .plain = .init(dir, buffer) } };
}

/// Whether the scan reads batches. Decided by the first `next`; a caller
/// that measures asks here.
pub fn isBatched(s: *const Scan) bool {
    return s.arm == .batch;
}

/// The next entry, or null at the end of the directory. `.` and `..` are
/// never given; the order is the file system's. An entry removed between
/// the listing and its stat is passed over.
pub fn next(s: *Scan, io: Io) Error!?Entry {
    while (true) switch (s.arm) {
        .start => {
            if (batch_supported) switch (try sys.readBatch(io, s.dir.handle, s.buffer, true)) {
                .entries => |count| {
                    s.arm = .{ .batch = .{ .cursor = 0, .count = count, .done = count == 0 } };
                    continue;
                },
                .unsupported, .routed => {},
            };
            s.arm = .{ .plain = .init(s.dir, s.buffer) };
        },
        .batch => |*b| {
            if (b.count == 0) {
                if (b.done) return null;
                const batch = try sys.readBatch(io, s.dir.handle, s.buffer, false);
                const count = switch (batch) {
                    .entries => |n| n,
                    .unsupported, .routed => return error.Unexpected,
                };
                b.* = .{ .cursor = 0, .count = count, .done = count == 0 };
                if (count == 0) return null;
            }
            const parsed = parseEntry(s.buffer[b.cursor..]) orelse return error.Unexpected;
            assert(parsed.length != 0);
            assert(parsed.length <= s.buffer.len - b.cursor);
            b.cursor += parsed.length;
            b.count -= 1;
            if (isDots(parsed.name)) continue;
            if (parsed.stat) |stat| return .{ .name = parsed.name, .stat = stat };
            // The volume answered this entry short: its stat, the ordinary way.
            const stat = statOf(io, s.dir, parsed.name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            return .{ .name = parsed.name, .stat = stat };
        },
        .plain => |*reader| {
            const entry = try reader.next(io) orelse return null;
            if (isDots(entry.name)) continue;
            const stat = statOf(io, s.dir, entry.name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => |e| return e,
            };
            return .{ .name = entry.name, .stat = stat };
        },
    };
}

fn isDots(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// An entry's stat by name, a directory's size zeroed as a batch has it.
fn statOf(io: Io, dir: Io.Dir, name: []const u8) sys.StatPathError!sys.Full {
    var stat = try sys.statPath(io, dir.handle, name, false);
    if (stat.kind == .directory) stat.size = 0;
    return stat;
}

//=====================================================================
// A batch's entries. The attributes come packed in the order of their
// bits, each aligned to four bytes, the eight-byte ones included, so every
// field is copied out rather than cast. The set the volume returned comes
// first and says which of them it answered.
//=====================================================================

const attr = sys.batch_attr;

const Parsed = struct {
    /// The bytes this entry takes, which is how the next one is reached.
    length: usize,
    name: []const u8,
    /// Null when the volume did not answer every attribute asked, so the
    /// caller stats the name instead of filling a field from nothing.
    stat: ?sys.Full,
};

/// A field of the packed group: zero when the group is shorter than it,
/// which the length checks around each read turn into a refusal.
fn read(comptime T: type, bytes: []const u8) T {
    if (bytes.len < @sizeOf(T)) return 0;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[0..@sizeOf(T)]);
    return value;
}

const Fields = struct {
    group: []const u8,
    at: usize,

    fn take(f: *Fields, comptime T: type) ?T {
        if (f.at + @sizeOf(T) > f.group.len) return null;
        defer f.at += @sizeOf(T);
        return read(T, f.group[f.at..]);
    }

    fn time(f: *Fields) ?Io.Timestamp {
        const sec = f.take(i64) orelse return null;
        const nsec = f.take(i64) orelse return null;
        return .{ .nanoseconds = @as(i96, sec) * std.time.ns_per_s + nsec };
    }
};

fn parseEntry(bytes: []const u8) ?Parsed {
    const length = read(u32, bytes);
    if (length < 24 or length > bytes.len) return null;
    var f: Fields = .{ .group = bytes[0..length], .at = 4 };
    const returned_common = f.take(u32) orelse return null;
    _ = f.take(u32) orelse return null; // volume
    _ = f.take(u32) orelse return null; // directory
    const returned_file = f.take(u32) orelse return null;
    _ = f.take(u32) orelse return null; // fork

    if (returned_common & attr.cmn_name == 0) return null;
    const name_at = f.at;
    const name_offset = f.take(i32) orelse return null;
    const name_length = f.take(u32) orelse return null;
    if (name_offset < 0 or name_length == 0) return null;
    const start = name_at + @as(usize, @intCast(name_offset));
    // The length counts the terminator.
    if (start + name_length > length) return null;
    const name = f.group[start .. start + name_length - 1];

    const has = struct {
        fn bit(set: u32, mask: u32) bool {
            return set & mask != 0;
        }
    }.bit;
    var stat: sys.Full = .{
        .kind = .unknown,
        .size = 0,
        .mode = 0,
        .permissions = .default_file,
        .mtime = .zero,
        .ctime = .zero,
        .birth = null,
        .inode = 0,
        .device = 0,
        .uid = 0,
        .gid = 0,
        .attributes = 0,
        .reparse_tag = 0,
    };
    var access: u32 = 0;
    if (has(returned_common, attr.cmn_devid)) stat.device = f.take(u32) orelse return null;
    if (has(returned_common, attr.cmn_objtype)) stat.kind = vnodeKind(f.take(u32) orelse return null);
    if (has(returned_common, attr.cmn_crtime)) stat.birth = f.time() orelse return null;
    if (has(returned_common, attr.cmn_modtime)) stat.mtime = f.time() orelse return null;
    if (has(returned_common, attr.cmn_chgtime)) stat.ctime = f.time() orelse return null;
    if (has(returned_common, attr.cmn_ownerid)) stat.uid = f.take(u32) orelse return null;
    if (has(returned_common, attr.cmn_grpid)) stat.gid = f.take(u32) orelse return null;
    if (has(returned_common, attr.cmn_accessmask)) access = f.take(u32) orelse return null;
    if (has(returned_common, attr.cmn_fileid)) stat.inode = f.take(u64) orelse return null;
    if (has(returned_file, attr.file_datalength)) stat.size = f.take(u64) orelse return null;

    // Everything asked is required but the creation time, which not every
    // volume keeps, and a directory's data length, which no directory has.
    const required = attr.common & ~(attr.cmn_returned_attrs | attr.cmn_crtime);
    const short = returned_common & required != required or
        (stat.kind != .directory and !has(returned_file, attr.file_datalength));
    if (short) return .{ .length = length, .name = name, .stat = null };
    stat.mode = sys.modeOfKind(stat.kind) | (access & 0o7777);
    stat.permissions = sys.permissionsOfMode(stat.mode);
    if (stat.kind == .directory) stat.size = 0;
    return .{ .length = length, .name = name, .stat = stat };
}

/// Darwin's vnode types, how a batch names an entry's kind.
fn vnodeKind(objtype: u32) Io.File.Kind {
    return switch (objtype) {
        1 => .file,
        2 => .directory,
        3 => .block_device,
        4 => .character_device,
        5 => .sym_link,
        6 => .unix_domain_socket,
        7 => .named_pipe,
        else => .unknown,
    };
}

//=====================================================================
// Tests
//=====================================================================

const testing = std.testing;

fn expectSameStat(want: sys.Full, got: sys.Full) !void {
    try testing.expectEqual(want.kind, got.kind);
    try testing.expectEqual(want.mode, got.mode);
    try testing.expectEqual(want.size, got.size);
    try testing.expectEqual(want.mtime.nanoseconds, got.mtime.nanoseconds);
    try testing.expectEqual(want.ctime.nanoseconds, got.ctime.nanoseconds);
    try testing.expectEqual(want.inode, got.inode);
    try testing.expectEqual(want.device, got.device);
    try testing.expectEqual(want.uid, got.uid);
    try testing.expectEqual(want.gid, got.gid);
    try testing.expectEqual(want.attributes, got.attributes);
    try testing.expectEqual(want.reparse_tag, got.reparse_tag);
    if (want.birth != null and got.birth != null)
        try testing.expectEqual(want.birth.?.nanoseconds, got.birth.?.nanoseconds);
}

/// A directory of every kind a test can make, and a long name.
fn fill(io: Io, dir: Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "some bytes\n" });
    try dir.writeFile(io, .{ .sub_path = ".hidden", .data = "dot\n" });
    try dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try dir.createDir(io, "sub", .default_dir);
    try dir.writeFile(io, .{ .sub_path = "sub/inner", .data = "x" });
    try dir.writeFile(io, .{ .sub_path = "runnable", .data = "#!/bin/sh\n" });
    if (Io.File.Permissions.has_executable_bit) {
        const runnable = try dir.openFile(io, "runnable", .{});
        defer runnable.close(io);
        try runnable.setPermissions(io, .fromMode(0o755));
    }
    // A symbolic link needs a privilege on Windows a test may not have.
    if (builtin.target.os.tag != .windows) try dir.symLink(io, "plain.txt", "link", .{});
    try dir.writeFile(io, .{ .sub_path = "a-name-that-is-considerably-longer-than-the-others-in-this-directory", .data = "long\n" });
}

/// Every entry of a scan matches `airlock.stat` of its name; returns how
/// many there were.
fn expectScanMatchesStat(io: Io, dir: Io.Dir, s: *Scan) !usize {
    var n: usize = 0;
    while (try s.next(io)) |entry| {
        var want = try sys.statPath(io, dir.handle, entry.name, false);
        if (want.kind == .directory) want.size = 0;
        try expectSameStat(want, entry.stat);
        n += 1;
    }
    return n;
}

test "a scan gives every entry with the stat airlock.stat gives it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fill(io, tmp.dir);
    var buffer: [64 * 1024]u8 align(@alignOf(usize)) = undefined;
    var scan = init(tmp.dir, &buffer);
    const n = try expectScanMatchesStat(io, tmp.dir, &scan);
    var plain = initPlain(tmp.dir, &buffer);
    try testing.expectEqual(n, try expectScanMatchesStat(io, tmp.dir, &plain));
    try testing.expect(n >= 7);
    try testing.expectEqual(batch_supported, scan.isBatched());
}

test "a volume without the batch call is read the ordinary way, from the start" {
    if (!batch_supported) return error.SkipZigTest;
    const io = testing.io;
    const seam = @import("airlock.testing");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fill(io, tmp.dir);
    const h = try seam.Seam.create(testing.allocator, io, .{ .plan = &.{seam.always(.scan, .OPNOTSUPP)} });
    defer h.destroy();
    var buffer: [8 * 1024]u8 align(@alignOf(usize)) = undefined;
    var scan = init(tmp.dir, &buffer);
    const n = try expectScanMatchesStat(h.io(), tmp.dir, &scan);
    try testing.expect(!scan.isBatched());
    try testing.expect(n >= 7);
    try testing.expectEqual(@as(u32, 1), h.count(.scan));
}

test "a batch call that fails partway is the scan's error" {
    if (!batch_supported) return error.SkipZigTest;
    const io = testing.io;
    const seam = @import("airlock.testing");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (0..64) |i| {
        var name: [64]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.mem.print(&name, "entry-{d:0>3}-long-enough-to-take-room", .{i}), .data = "x" });
    }
    const h = try seam.Seam.create(testing.allocator, io, .{ .plan = &.{seam.fail(.scan, 2, .IO)} });
    defer h.destroy();
    var buffer: [min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    var scan = init(tmp.dir, &buffer);
    while (true) {
        const entry = scan.next(h.io()) catch |err| {
            try testing.expectEqual(error.InputOutput, err);
            break;
        };
        if (entry == null) return error.TestUnexpectedResult;
    }
}

test "a scan reads a directory of many batches, and again over the same handle" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const count = 300;
    for (0..count) |i| {
        var name: [96]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.mem.print(&name, "entry-{d:0>4}-with-a-name-long-enough-to-fill-the-buffer", .{i}), .data = "x" });
    }
    // The smallest buffer, so a batch holds a few entries and the scan
    // makes many calls.
    var buffer: [min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    for (0..2) |_| {
        var seen: std.bit_set.Static(count) = .empty;
        var scan = init(tmp.dir, &buffer);
        while (try scan.next(io)) |entry| {
            try testing.expectEqual(@as(u64, 1), entry.stat.size);
            const i = try std.fmt.parseInt(usize, entry.name[6..10], 10);
            try testing.expect(!seen.isSet(i));
            seen.set(i);
        }
        try testing.expectEqual(@as(usize, count), seen.count());
    }
}

test "a scan of an empty directory gives nothing, and stays finished" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buffer: [min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    var scan = init(tmp.dir, &buffer);
    try testing.expectEqual(null, try scan.next(io));
    try testing.expectEqual(null, try scan.next(io));
}

test "over a simulation a scan reads and stats through the Io" {
    const shakedown = @import("shakedown");
    const seam = @import("airlock.testing");
    const sim = try shakedown.Sim.init(testing.allocator, .{});
    defer sim.deinit();
    const fs = sim.fs();
    try fs.mkdir("d");
    try fs.write("d/one", "1");
    try fs.write("d/three", "333");
    try fs.mkdir("d/sub");
    const Run = struct {
        fn run(base: Io) !void {
            const h = try seam.Seam.create(testing.allocator, base, .{});
            defer h.destroy();
            const io = h.io();
            const dir = try Io.Dir.cwd().openDir(io, "d", .{ .iterate = true });
            defer dir.close(io);
            var buffer: [min_buffer_len]u8 align(@alignOf(usize)) = undefined;
            var scan = init(dir, &buffer);
            var sizes: u64 = 0;
            var kinds: u32 = 0;
            while (try scan.next(io)) |entry| {
                sizes += entry.stat.size;
                kinds += @intFromBool(entry.stat.kind == .directory);
                try testing.expectEqual(@as(u64, 0), entry.stat.device);
            }
            try testing.expectEqual(@as(u64, 4), sizes);
            try testing.expectEqual(@as(u32, 1), kinds);
            try testing.expect(!scan.isBatched());
            // The batch call is decided, and routed: no raw call is made.
            try testing.expectEqual(@as(u32, if (batch_supported) 1 else 0), h.count(.scan));
            try testing.expectEqual(@as(u32, 3), h.count(.stat));
        }
    };
    try testing.expect(sim.run(Run.run, .{sim.io()}) == .finished);
}
