//! `syncFile`, `syncDir` and `syncPath`: the call each level makes on each
//! platform, the fallback chains, and the errors that are never retried.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");
const harness = @import("testing/harness.zig");
const seam = @import("airlock.testing");
const Seam = seam.Seam;
const Call = seam.Call;
const expectCalls = harness.expectCalls;

const os = builtin.target.os.tag;
const is_windows = os == .windows;
const is_linux = os == .linux;
const is_darwin = os.isDarwin();

/// A file with a few bytes in it, open for writing.
fn scratchFile(s: *harness.Scratch) !Io.File {
    try s.write("data", "contents");
    return s.dir().openFile(testing.io, "data", .{ .mode = .read_write });
}

/// The code each platform's first sync call refuses with.
const refusal: seam.Code = if (is_windows) .INVALID_PARAMETER else if (is_darwin) .NOTTY else .INVAL;
const io_error: seam.Code = if (is_windows) .IO_DEVICE_ERROR else .IO;

test "each level makes the platform's call and reports what it reached" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    inline for ([_]airlock.Level{ .none, .ordered, .data, .full }) |level| {
        const h = try Seam.create(testing.allocator, testing.io, .{});
        defer h.destroy();
        const reached = try airlock.syncFile(h.io(), file, .{ .level = level });
        try testing.expectEqual(airlock.Reached.expected(level), reached);
        const expected: []const Call = switch (level) {
            .none => &.{},
            .ordered => if (is_darwin) &.{.sync_barrier} else if (is_linux) &.{.sync_data} else if (is_windows) &.{.sync_data} else &.{.sync_plain},
            .data => if (is_darwin) &.{.sync_full} else if (is_linux) &.{.sync_data} else if (is_windows) &.{.sync_data} else &.{.sync_plain},
            .full => if (is_darwin or is_linux or is_windows) &.{.sync_full} else &.{.sync_plain},
        };
        try expectCalls(h, expected);
    }
}

test "a Darwin barrier is a full flush with barrier off" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const h = try Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.full, try airlock.syncFile(h.io(), file, .{ .level = .ordered, .barrier = false }));
    try expectCalls(h, &.{.sync_full});
}

test "a refused call falls back to the next one, never to a weaker one first" {
    if (!is_linux and !is_darwin and !is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);

    const first: Call = if (is_darwin) .sync_full else if (is_linux) .sync_data else .sync_data;
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.always(first, refusal)} });
    defer h.destroy();
    const reached = try airlock.syncFile(h.io(), file, .{ .level = .data });
    if (is_darwin) {
        // exFAT, SMB: F_FULLFSYNC refused, fsync hands the bytes to the
        // device and no more.
        try testing.expectEqual(airlock.Reached.written, reached);
        try expectCalls(h, &.{ .sync_full, .sync_plain });
    } else {
        // A stronger call stands in: fsync, NtFlushBuffersFile.
        try testing.expectEqual(airlock.Reached.full, reached);
        try expectCalls(h, &.{ first, .sync_full });
    }
}

test "a chain that ends below the level says so in what it reached" {
    if (!is_linux and !is_darwin and !is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const plan = if (is_darwin)
        &[_]seam.Plan.Entry{seam.always(.sync_full, refusal)}
    else
        &[_]seam.Plan.Entry{ seam.always(.sync_data, refusal), seam.always(.sync_full, if (is_windows) .NOT_SUPPORTED else refusal) };
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = plan });
    defer h.destroy();
    const reached = try airlock.syncFile(h.io(), file, .{ .level = .data });
    try testing.expectEqual(if (is_darwin) airlock.Reached.written else airlock.Reached.none, reached);
    try testing.expect(!reached.atLeast(.data));
}

/// Whether `function` can return `error.<name>`.
fn canReturn(comptime name: []const u8, comptime function: anytype) bool {
    const returned = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const set = @typeInfo(returned).error_union.error_set;
    for (@typeInfo(set).error_set.error_names.?) |error_name| {
        if (std.mem.eql(u8, error_name, name)) return true;
    }
    return false;
}

test "only a call that refuses can return LevelUnavailable: one that degrades reports instead" {
    inline for (.{
        airlock.syncFile,
        airlock.syncDir,
        airlock.syncPath,
        airlock.writeFile,
        airlock.Pending.commit,
        airlock.Batch.commit,
        airlock.rename,
        airlock.remove,
        airlock.makePath,
        airlock.symLink,
    }) |function| try testing.expect(comptime !canReturn("LevelUnavailable", function));
    inline for (.{
        airlock.writeFileOrRefuse,
        airlock.Pending.commitOrRefuse,
        airlock.Batch.commitOrRefuse,
        airlock.symLinkOrRefuse,
    }) |function| try testing.expect(comptime canReturn("LevelUnavailable", function));
}

test "a Darwin barrier refused goes to the full flush, which keeps the order" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.always(.sync_barrier, .NOTTY)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.full, try airlock.syncFile(h.io(), file, .{ .level = .ordered }));
    try expectCalls(h, &.{ .sync_barrier, .sync_full });
}

test "a failed sync is returned once: no retry, no weaker call" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const first: Call = if (is_darwin) .sync_full else if (is_linux) .sync_data else if (is_windows) .sync_data else .sync_plain;
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.always(first, io_error)} });
    defer h.destroy();
    try testing.expectError(error.InputOutput, airlock.syncFile(h.io(), file, .{ .level = .data }));
    try expectCalls(h, &.{first});
}

test "an interrupted sync is made again, and a cancel ends it" {
    if (is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const first: Call = if (is_darwin) .sync_full else if (is_linux) .sync_data else .sync_plain;
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.fail(first, 1, .INTR)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.expected(.data), try airlock.syncFile(h.io(), file, .{ .level = .data }));
    try expectCalls(h, &.{ first, first });

    const c = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = first, .n = 1 } }, .fault = .canceled }} });
    defer c.destroy();
    try testing.expectError(error.Canceled, airlock.syncFile(c.io(), file, .{ .level = .data }));
}

test "a directory sync is the platform's directory call; none at ordered" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "1");
    const h = try Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.none, try airlock.syncDir(h.io(), s.dir(), .{ .level = .ordered }));
    try expectCalls(h, &.{});
    try testing.expectEqual(airlock.Reached.full, try airlock.syncDir(h.io(), s.dir(), .{ .level = .data }));
    if (is_windows) {
        // A directory handle opened to be read cannot be flushed: it is
        // reopened with FILE_ADD_FILE, then flushed.
        try expectCalls(h, &.{ .open_dir, .sync_dir, .close });
    } else {
        try expectCalls(h, &.{.sync_dir});
    }
}

test "cwd and an O_PATH handle are reopened for the sync; a bad number is returned" {
    const h = try Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.full, try airlock.syncDir(h.io(), Io.Dir.cwd(), .{}));
    if (!is_windows) try expectCalls(h, &.{ .open_dir, .sync_dir, .close });
    if (!is_linux) return;

    var s: harness.Scratch = .init();
    defer s.cleanup();
    const path_only = try s.dir().openDir(testing.io, ".", .{});
    defer path_only.close(testing.io);
    h.reset();
    try testing.expectEqual(airlock.Reached.full, try airlock.syncDir(h.io(), path_only, .{}));
    try expectCalls(h, &.{ .sync_dir, .getfl, .open_dir, .sync_dir, .close });

    // A number nothing has open: EBADF that is not O_PATH is returned,
    // never answered by syncing whatever "." is.
    h.reset();
    try testing.expectError(error.Unexpected, airlock.syncDir(h.io(), .{ .handle = 9999 }, .{}));
    try expectCalls(h, &.{ .sync_dir, .getfl });
}

test "a refused directory sync reports none" {
    if (!is_linux) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Seam.create(testing.allocator, testing.io, .{ .plan = &.{seam.always(.sync_dir, .INVAL)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.none, try airlock.syncDir(h.io(), s.dir(), .{}));
}

test "syncPath opens the file and syncs it" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("data", "contents");
    const h = try Seam.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.expected(.data), try airlock.syncPath(h.io(), s.dir(), "data", .{}));
    var buffer: [8]Call = undefined;
    const got = h.calls(&buffer);
    try testing.expectEqual(Call.open_file, got[0]);
    try testing.expectEqual(Call.close, got[got.len - 1]);
    try testing.expectError(error.FileNotFound, airlock.syncPath(h.io(), s.dir(), "gone", .{}));
}

test "the real calls, without a hook, reach what the table says" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    inline for ([_]airlock.Level{ .none, .ordered, .data, .full }) |level| {
        try testing.expectEqual(airlock.Reached.expected(level), try airlock.syncFile(testing.io, file, .{ .level = level }));
    }
    try testing.expectEqual(airlock.Reached.full, try airlock.syncDir(testing.io, s.dir(), .{}));
}

test "a retry waits with doubling, jittered sleeps on the clock until its deadline" {
    const platform = @import("platform.zig");
    const h = try Seam.create(testing.allocator, testing.io, .{ .clock = true });
    defer h.destroy();
    const Retry = struct {
        io: Io,
        tries: u32 = 0,
        result: Io.Cancelable!void = {},

        const Self = @This();

        pub fn run(r: *Self) void {
            var backoff: platform.Backoff = .start(r.io, .fromMilliseconds(2000));
            while (true) {
                r.tries += 1;
                const again = backoff.wait(r.io) catch |err| {
                    r.result = err;
                    return;
                };
                if (!again) return;
            }
        }
    };
    var retry: Retry = .{ .io = h.io() };
    try h.drive(testing.io, &retry);
    try retry.result;
    // From 1 ms, doubling to a 100 ms cap, each scaled by [0.5, 1.5):
    // about 25 sleeps fill 2 s; the last one ends at the deadline.
    const sleeps = h.fio.count(.sleep);
    try testing.expect(sleeps >= 15 and sleeps <= 45);
    try testing.expectEqual(@as(u64, retry.tries - 1), sleeps);
    try testing.expectEqual(@as(i96, std.time.ns_per_s + 2 * std.time.ns_per_s), h.clock.?.read(.awake).nanoseconds);
}

/// A file of two pages mapped for writing, "x" at an offset in its second.
fn mappedFile(s: *harness.Scratch) !struct { file: Io.File, map: Io.File.MemoryMap } {
    const io = testing.io;
    const len = 2 * std.heap.pageSize();
    const file = try s.dir().createFile(io, "mapped", .{ .read = true, .truncate = true });
    errdefer file.close(io);
    try file.setLength(io, len);
    const map = try file.createMemoryMap(io, .{ .len = len });
    return .{ .file = file, .map = map };
}

test "a mapped range is written back, then synced as its file at each level" {
    if (builtin.os.tag != .linux and !is_darwin and !is_windows) return error.SkipZigTest;
    const io = testing.io;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    var m = try mappedFile(&s);
    defer m.file.close(io);
    defer m.map.destroy(io);
    // Past the first page, across none of its own.
    const at = std.heap.pageSize() + 100;
    inline for ([_]airlock.Level{ .none, .ordered, .data, .full }) |level| {
        @memcpy(m.map.memory[at..][0..5], @tagName(level)[0..4] ++ "!");
        const h = try Seam.create(testing.allocator, io, .{});
        defer h.destroy();
        const reached = try airlock.syncMapped(h.io(), &m.map, m.map.memory[at..][0..5], .{ .level = level });
        try testing.expect(reached.atLeast(level));
        const expected: []const Call = switch (level) {
            .none => &.{},
            .ordered => if (is_darwin) &.{ .write_mapped, .sync_barrier } else if (is_linux) &.{.write_mapped} else &.{ .write_mapped, .sync_data },
            .data => if (is_darwin) &.{ .write_mapped, .sync_full } else if (is_linux) &.{.write_mapped} else &.{ .write_mapped, .sync_data },
            .full => &.{ .write_mapped, .sync_full },
        };
        try expectCalls(h, expected);
        if (level != .none) {
            // The file holds what was written through the map.
            var buffer: [5]u8 = undefined;
            try testing.expectEqual(@as(usize, 5), try m.file.readPositionalAll(io, &buffer, at));
            try testing.expectEqualStrings(@tagName(level)[0..4] ++ "!", &buffer);
        }
    }
}

test "a failed writeback of a mapped range is returned, and no sync follows it" {
    if (builtin.os.tag != .linux and !is_darwin and !is_windows) return error.SkipZigTest;
    const io = testing.io;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    var m = try mappedFile(&s);
    defer m.file.close(io);
    defer m.map.destroy(io);
    const h = try Seam.create(testing.allocator, io, .{ .plan = &.{seam.always(.write_mapped, io_error)} });
    defer h.destroy();
    m.map.memory[0] = 'y';
    try testing.expectError(error.InputOutput, airlock.syncMapped(h.io(), &m.map, m.map.memory[0..1], .{}));
    try expectCalls(h, &.{.write_mapped});
}

test "a map std made as a buffer is written back positionally, then synced" {
    const io = testing.io;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(io);
    var memory: [8]u8 align(std.heap.page_size_min) = "contents".*;
    const map: Io.File.MemoryMap = .{ .file = file, .offset = 0, .memory = &memory, .section = null };
    memory[0..3].* = "CON".*;
    const h = try Seam.create(testing.allocator, io, .{});
    defer h.destroy();
    try testing.expect((try airlock.syncMapped(h.io(), &map, memory[0..3], .{})).atLeast(.data));
    try testing.expectEqual(@as(u32, 0), h.count(.write_mapped));
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("CONtents", s.read("data", &buffer).?);
}
