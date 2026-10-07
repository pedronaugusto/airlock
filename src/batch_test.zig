//! `Batch`: the barrier counts per platform, the rename order and fences,
//! directory dedup, the volume keys, and what a failure leaves behind.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");
const harness = @import("testing/harness.zig");
const Harness = harness.Harness;
const Call = harness.Call;
const expectCalls = harness.expectCalls;

const os = builtin.target.os.tag;
const is_windows = os == .windows;
const is_linux = os == .linux;
const is_darwin = os.isDarwin();
const is_tested_os = is_linux or is_darwin or is_windows;

const io_error: harness.Code = if (is_windows) .IO_DEVICE_ERROR else .IO;

fn expectContents(s: *harness.Scratch, name: []const u8, expected: ?[]const u8) !void {
    var buffer: [64]u8 = undefined;
    const got = s.read(name, &buffer);
    if (expected) |e| {
        try testing.expectEqualStrings(e, got orelse return error.TestExpectedFile);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), got);
    }
}

/// A pending with `bytes` written, for `name` in `dir`.
fn pending(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !airlock.Pending {
    var p = try airlock.create(io, dir, name, .{});
    errdefer p.discard(io);
    try p.file.writePositionalAll(io, bytes, 0);
    return p;
}

test "three publishes into one directory: the fewest barriers per platform" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var ps: [3]airlock.Pending = undefined;
    for (&ps, [_][]const u8{ "a", "b", "c" }) |*p, name| p.* = try pending(io, s.dir(), name, name);
    defer for (&ps) |*p| p.discard(io);
    var slots: [8]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    for (&ps) |*p| try batch.addPending(io, p, .replace);
    h.reset();
    const reached = try batch.commit(io, .{ .parallel = 1 });
    try testing.expect(reached.atLeast(.data));
    for ([_][]const u8{ "a", "b", "c" }) |name| try expectContents(&s, name, name);
    try testing.expectEqual(@as(usize, 0), (try s.entries(".")).prefixed);
    if (is_linux) {
        // Each file's fdatasync, then the directory once.
        try testing.expectEqual(@as(u32, 3), h.count(.sync_data));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_dir));
    } else if (is_darwin) {
        // W each, one barrier, W on the directory, one full flush.
        try testing.expectEqual(@as(u32, 4), h.count(.sync_writeout));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_barrier));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_full));
    } else {
        // NO_SYNC each and on the directory, one flush before the renames
        // and one after.
        try testing.expectEqual(@as(u32, 4), h.count(.sync_writeout));
        try testing.expectEqual(@as(u32, 2), h.count(.sync_full));
    }
}

test "files without renames: one flush per volume, no barrier" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    for ([_][]const u8{ "x", "y" }) |name| try s.write(name, name);
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    const x = try s.dir().openFile(testing.io, "x", .{ .mode = .read_write });
    defer x.close(testing.io);
    var slots: [4]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addFile(x);
    try batch.addPath(s.dir(), "y");
    const reached = try batch.commit(io, .{ .parallel = 1 });
    try testing.expect(reached.atLeast(.data));
    if (is_darwin) {
        try testing.expectEqual(@as(u32, 2), h.count(.sync_writeout));
        try testing.expectEqual(@as(u32, 0), h.count(.sync_barrier));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_full));
    } else if (is_windows) {
        try testing.expectEqual(@as(u32, 2), h.count(.sync_writeout));
        try testing.expectEqual(@as(u32, 1), h.count(.sync_full));
    } else {
        try testing.expectEqual(@as(u32, 2), h.count(.sync_data));
    }
}

test "renames happen in add order, and the directories are synced once each" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.dir().createDirPath(testing.io, "pack");
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var pack = try pending(io, s.dir(), "pack/p.pack", "P");
    defer pack.discard(io);
    var rev = try pending(io, s.dir(), "pack/p.rev", "R");
    defer rev.discard(io);
    var idx = try pending(io, s.dir(), "pack/p.idx", "I");
    defer idx.discard(io);
    var slots: [8]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &pack, .replace);
    try batch.addPending(io, &rev, .replace);
    try batch.fence();
    try batch.addPending(io, &idx, .replace);
    try batch.addDir(s.dir());
    h.reset();
    _ = try batch.commit(io, .{ .parallel = 1 });
    var names: [3][]const u8 = undefined;
    var n: usize = 0;
    for (h.fio.trace().records()) |r| {
        const f = r.event.foreign orelse continue;
        if (f.call != @backingInt(Call.rename) and f.call != @backingInt(Call.win_rename_ex)) continue;
        names[n] = r.event.subject.path.?;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("p.pack", names[0]);
    try testing.expectEqualStrings("p.rev", names[1]);
    try testing.expectEqualStrings("p.idx", names[2]);
    // pack/ once at the fence and once after; the root once.
    if (is_linux) try testing.expectEqual(@as(u32, 3), h.count(.sync_dir));
    // One parent opened for all three pendings (Windows also reopens each
    // directory it flushes).
    if (!is_windows) try testing.expectEqual(@as(u32, 1), h.count(.open_dir));
    for ([_][]const u8{ "pack/p.pack", "pack/p.rev", "pack/p.idx" }, [_][]const u8{ "P", "R", "I" }) |name, bytes| try expectContents(&s, name, bytes);
}

test "a fence on Darwin writes out every directory touched, then one barrier" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.dir().createDirPath(testing.io, "one");
    try s.dir().createDirPath(testing.io, "two");
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var a = try pending(io, s.dir(), "one/a", "a");
    defer a.discard(io);
    var b = try pending(io, s.dir(), "two/b", "b");
    defer b.discard(io);
    var c = try pending(io, s.dir(), "c", "c");
    defer c.discard(io);
    var slots: [8]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &a, .replace);
    try batch.addPending(io, &b, .replace);
    try batch.fence();
    try batch.addPending(io, &c, .replace);
    h.reset();
    _ = try batch.commit(io, .{ .parallel = 1 });
    var buffer: [64]Call = undefined;
    const calls = h.calls(&buffer);
    // After the second rename: W on one/, W on two/, then the barrier,
    // then the third rename.
    var i: usize = 0;
    var renames: usize = 0;
    while (i < calls.len and renames < 2) : (i += 1) {
        if (calls[i] == .rename) renames += 1;
    }
    try testing.expectEqualSlices(Call, &.{ .sync_writeout, .sync_writeout, .sync_barrier, .rename }, calls[i .. i + 4]);
}

test "keep_existing on a taken name syncs the existing file inside the batch" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("obj", "theirs");
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var p = try pending(io, s.dir(), "obj", "ours");
    defer p.discard(io);
    var slots: [2]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &p, .keep_existing);
    const reached = try batch.commit(io, .{ .parallel = 1 });
    try testing.expect(reached.atLeast(.data));
    try testing.expectEqual(airlock.Pending.State.kept, p.state);
    try expectContents(&s, "obj", "theirs");
    try testing.expectEqual(@as(u32, 1), h.count(.open_file));
    try testing.expectEqual(@as(usize, 0), (try s.entries(".")).prefixed);
}

test "a failed sync poisons the batch: nothing renamed, temps gone, the slot named" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const first: Call = if (is_linux) .sync_data else .sync_writeout;
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(first, 2, io_error)} });
    defer h.destroy();
    const io = h.io();
    var a = try pending(io, s.dir(), "a", "a");
    defer a.discard(io);
    var b = try pending(io, s.dir(), "b", "b");
    defer b.discard(io);
    var slots: [4]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &a, .replace);
    try batch.addPending(io, &b, .replace);
    try testing.expectError(error.InputOutput, batch.commit(io, .{ .parallel = 1 }));
    const failure = batch.failure().?;
    try testing.expectEqual(@as(u32, 1), failure.slot);
    try testing.expectEqual(@as(anyerror, error.InputOutput), failure.cause);
    try testing.expectEqual(airlock.Pending.State.poisoned, b.state);
    try testing.expectEqual(airlock.Pending.State.discarded, a.state);
    try expectContents(&s, "a", null);
    try expectContents(&s, "b", null);
    try testing.expectEqual(@as(usize, 0), (try s.entries(".")).count);
}

test "a failure after a rename is PublishedNotDurable" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const after: Call = if (is_linux) .sync_dir else if (is_darwin) .sync_full else .sync_full;
    const n: u32 = if (is_windows) 2 else 1;
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(after, n, io_error)} });
    defer h.destroy();
    const io = h.io();
    var a = try pending(io, s.dir(), "a", "a");
    defer a.discard(io);
    var slots: [2]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &a, .replace);
    try testing.expectError(error.PublishedNotDurable, batch.commit(io, .{ .parallel = 1 }));
    try testing.expectEqual(@as(anyerror, error.InputOutput), batch.failure().?.cause);
    try expectContents(&s, "a", "a");
}

test "a full batch says so; the caller commits and starts the next one" {
    var slots: [1]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    try batch.fence();
    try testing.expectError(error.BatchFull, batch.fence());
}

test "Linux syncs concurrently and the calls are the same multiset" {
    if (!is_linux) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    var names: [16][8]u8 = undefined;
    var counts: [2][@typeInfo(Call).@"enum".field_names.len]u32 = undefined;
    for ([_]u8{ 1, 16 }, 0..) |parallel, round| {
        const h = try Harness.create(testing.allocator, testing.io, .{});
        defer h.destroy();
        const io = h.io();
        var ps: [16]airlock.Pending = undefined;
        for (&ps, &names, 0..) |*p, *name, i| {
            const n = std.mem.print(name, "f{d}-{d}", .{ i, round }) catch unreachable; // unreachable: 8 bytes hold the name
            p.* = try pending(io, s.dir(), n, "x");
        }
        defer for (&ps) |*p| p.discard(io);
        var slots: [16]airlock.Batch.Slot = undefined;
        var batch: airlock.Batch = .init(&slots);
        defer batch.reset(io);
        for (&ps) |*p| try batch.addPending(io, p, .replace);
        h.reset();
        _ = try batch.commit(io, .{ .parallel = parallel });
        for (&counts[round], 0..) |*c, i| c.* = h.count(@fromBackingInt(@as(u8, @intCast(i))));
    }
    try testing.expectEqualSlices(u32, &counts[0], &counts[1]);
}

test "two hundred nested pendings stay within one descriptor each, plus parallel" {
    if (is_windows or !is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const io = testing.io;
    const count = 200;
    var names: [count][16]u8 = undefined;
    var ps: [count]airlock.Pending = undefined;
    var slots: [count]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    const before = try openDescriptors();
    for (&ps, &names, 0..) |*p, *name, i| {
        const n = std.mem.print(name, "d{d}/f", .{i % 50}) catch unreachable; // unreachable: 16 bytes hold the name
        if (i < 50) try s.dir().createDirPath(io, n[0 .. n.len - 2]);
        p.* = try airlock.create(io, s.dir(), n, .{});
        try batch.addPending(io, p, .replace);
    }
    defer for (&ps) |*p| p.discard(io);
    try testing.expect(try openDescriptors() - before <= count);
    _ = try batch.commit(io, .{ .parallel = 1 });
    try testing.expectEqual(before, try openDescriptors());
}

/// How many descriptors this process has open.
fn openDescriptors() !usize {
    var n: usize = 0;
    var fd: i32 = 0;
    while (fd < 4096) : (fd += 1) {
        const rc = if (is_linux) std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0) else @as(usize, @bitCast(@as(isize, std.c.fcntl(fd, std.c.F.GETFD)))); // safe: fcntl's int result, widened
        if (std.posix.errno(rc) == .SUCCESS) n += 1;
    }
    return n;
}

test "Windows: two directories that differ only in the device name are two volumes" {
    if (!is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    // A cloned volume keeps the serial and the file ids; only the NT
    // device name tells it apart. Give the second slot another one.
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .volume_name, .n = 2 } }, .fault = .{ .value = 0xfeed } },
    } });
    defer h.destroy();
    const io = h.io();
    var slots: [2]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addDir(s.dir());
    try batch.addDir(s.dir());
    _ = try batch.commit(io, .{});
    try testing.expectEqual(@as(u32, 2), h.count(.sync_writeout));
    try testing.expectEqual(@as(u32, 2), h.count(.sync_full));
}

test "Windows: NO_SYNC refused (ReFS) flushes each file instead" {
    if (!is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    for ([_][]const u8{ "x", "y" }) |name| try s.write(name, name);
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.sync_writeout, .INVALID_PARAMETER)} });
    defer h.destroy();
    const io = h.io();
    const x = try s.dir().openFile(testing.io, "x", .{ .mode = .read_write });
    defer x.close(testing.io);
    const y = try s.dir().openFile(testing.io, "y", .{ .mode = .read_write });
    defer y.close(testing.io);
    var slots: [2]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addFile(x);
    try batch.addFile(y);
    try testing.expectEqual(airlock.Reached.full, try batch.commit(io, .{}));
    // A flush per file, and no volume flush for what they covered.
    try testing.expectEqual(@as(u32, 2), h.count(.sync_full));
}
