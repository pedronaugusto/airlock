//! `syncFile`, `syncDir` and `syncPath`: the call each level makes on each
//! platform, the fallback chains, and the errors that are never retried.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const airlock = @import("airlock.zig");
const harness = @import("testing/harness.zig");
const Harness = harness.Harness;
const Call = harness.Call;
const expectCalls = harness.expectCalls;

const os = builtin.os.tag;
const is_windows = os == .windows;
const is_linux = os == .linux;
const is_darwin = os.isDarwin();

/// A file with a few bytes in it, open for writing.
fn scratchFile(s: *harness.Scratch) !Io.File {
    try s.write("data", "contents");
    return s.dir().openFile(testing.io, "data", .{ .mode = .read_write });
}

/// The code each platform's first sync call refuses with.
const refusal: harness.Code = if (is_windows) .INVALID_PARAMETER else if (is_darwin) .NOTTY else .INVAL;
const io_error: harness.Code = if (is_windows) .IO_DEVICE_ERROR else .IO;

test "each level makes the platform's call and reports what it reached" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    inline for ([_]airlock.Level{ .none, .ordered, .data, .full }) |level| {
        const h = try Harness.create(testing.allocator, testing.io, .{});
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
    const h = try Harness.create(testing.allocator, testing.io, .{});
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
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(first, refusal)} });
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

test "refuse returns LevelUnavailable where the fallback falls below the level" {
    if (!is_linux and !is_darwin and !is_windows) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const plan = if (is_darwin)
        &[_]harness.RawPlan.Entry{harness.always(.sync_full, refusal)}
    else
        &[_]harness.RawPlan.Entry{ harness.always(if (is_linux) .sync_data else .sync_data, refusal), harness.always(.sync_full, refusal) };
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = plan });
    defer h.destroy();
    try testing.expectError(error.LevelUnavailable, airlock.syncFile(h.io(), file, .{ .level = .data, .fallback = .refuse }));
    // Reported, the same chain ends below the level, and says so.
    h.reset();
    const reached = try airlock.syncFile(h.io(), file, .{ .level = .data });
    try testing.expectEqual(if (is_darwin) airlock.Reached.written else airlock.Reached.none, reached);
}

test "a Darwin barrier refused goes to the full flush, which keeps the order" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.sync_barrier, .NOTTY)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.full, try airlock.syncFile(h.io(), file, .{ .level = .ordered, .fallback = .refuse }));
    try expectCalls(h, &.{ .sync_barrier, .sync_full });
}

test "a failed sync is returned once: no retry, no weaker call" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const file = try scratchFile(&s);
    defer file.close(testing.io);
    const first: Call = if (is_darwin) .sync_full else if (is_linux) .sync_data else if (is_windows) .sync_data else .sync_plain;
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(first, io_error)} });
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
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.fail(first, 1, .INTR)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.expected(.data), try airlock.syncFile(h.io(), file, .{ .level = .data }));
    try expectCalls(h, &.{ first, first });

    const c = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = first, .n = 1 } }, .fault = .canceled }} });
    defer c.destroy();
    try testing.expectError(error.Canceled, airlock.syncFile(c.io(), file, .{ .level = .data }));
}

test "a directory sync is the platform's directory call; none at ordered" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "1");
    const h = try Harness.create(testing.allocator, testing.io, .{});
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
    const h = try Harness.create(testing.allocator, testing.io, .{});
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

test "a refused directory sync reports none, or refuses" {
    if (!is_linux) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{ .plan = &.{harness.always(.sync_dir, .INVAL)} });
    defer h.destroy();
    try testing.expectEqual(airlock.Reached.none, try airlock.syncDir(h.io(), s.dir(), .{}));
    try testing.expectError(error.LevelUnavailable, airlock.syncDir(h.io(), s.dir(), .{ .fallback = .refuse }));
}

test "syncPath opens the file and syncs it" {
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("data", "contents");
    const h = try Harness.create(testing.allocator, testing.io, .{});
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
