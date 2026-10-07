//! The single-fault sweep: every class of error at every step of each
//! operation, airlock's raw calls and std's `Io` calls alike, through
//! shakedown's `sweep`. After each run the check asserts what the operation
//! promises whatever failed: the destination is old or new and never torn,
//! no temp is left, a failed sync is never followed by another sync of that
//! file, an interrupted call is made again, and what a run reported is no
//! more than the crash model proves for the calls it made.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const airlock = @import("airlock.zig");
const harness = @import("testing/harness.zig");
const model_mod = @import("testing/model.zig");
const Harness = harness.Harness;
const Call = harness.Call;

const os = builtin.target.os.tag;
const is_windows = os == .windows;
const is_linux = os == .linux;
const is_darwin = os.isDarwin();
const is_tested_os = is_linux or is_darwin or is_windows;

const Kind = enum { replace, create_new, keep_existing, ordered, sync_file, rename, remove, batch, batch_two_dirs };

/// The error classes tried at each of airlock's calls: a refusal where the
/// call has one, a failure, a full disk, an interruption, a cancel, and on
/// Windows contention.
fn faultClasses(call: Call) []const shakedown.IoFault {
    const F = shakedown.IoFault;
    if (is_windows) {
        const common = [_]F{ .{ .fail = error.IO_DEVICE_ERROR }, .{ .fail = error.DISK_FULL }, .{ .fail = error.Canceled } };
        return switch (call) {
            .sync_data, .sync_writeout => &(common ++ [_]F{.{ .fail = error.INVALID_PARAMETER }}),
            .sync_full, .sync_dir => &(common ++ [_]F{.{ .fail = error.NOT_SUPPORTED }}),
            .win_rename_ex, .rename, .open_dir => &(common ++ [_]F{ .{ .fail = error.SHARING_VIOLATION }, .{ .fail = error.DELETE_PENDING } }),
            .create_temp => &(common ++ [_]F{.{ .fail = error.DELETE_PENDING }}),
            .close, .volume_name, .stat_id => &.{},
            else => &common,
        };
    }
    const common = [_]F{ .{ .fail = error.IO }, .{ .fail = error.NOSPC }, .{ .fail = error.INTR }, .{ .fail = error.Canceled } };
    const darwin_refusal = [_]F{.{ .fail = error.NOTTY }};
    const refusal = [_]F{.{ .fail = error.INVAL }};
    return switch (call) {
        .sync_full, .sync_barrier, .sync_dir => if (is_darwin) &(common ++ darwin_refusal) else &(common ++ refusal),
        .sync_data, .sync_plain, .sync_writeout, .rename_noreplace => &(common ++ refusal),
        .link => &(common ++ [_]F{.{ .fail = error.PERM }}),
        .create_temp => &.{ .{ .fail = error.ACCES }, .{ .fail = error.NOSPC }, .{ .fail = error.INTR }, .{ .fail = error.Canceled } },
        .open_dir, .open_file, .unlink => &.{ .{ .fail = error.ACCES }, .{ .fail = error.INTR }, .{ .fail = error.Canceled } },
        .stat_id, .getfl => &.{ .{ .fail = error.ACCES }, .{ .fail = error.INTR } },
        .close => &.{ .{ .fail = error.IO }, .{ .fail = error.INTR } },
        else => &common,
    };
}

const Sweep = struct {
    kind: Kind,
    scratch: harness.Scratch = undefined,
    h: *Harness = undefined,
    pendings: [3]airlock.Pending = undefined,
    pending_count: usize = 0,
    reached: airlock.Reached = .none,
    published: bool = false,
    /// A run's scratch and harness outlive its `tearDown`, for `check`;
    /// the next `setUp` or `finish` ends them.
    live: bool = false,

    /// The destinations each operation writes, and what was there before.
    fn dests(s: *const Sweep) []const []const u8 {
        return switch (s.kind) {
            .batch => &.{ "a", "b", "c" },
            .batch_two_dirs => &.{ "a", "sub/b", "sub/c" },
            .rename => &.{"b"},
            else => &.{"a"},
        };
    }

    pub fn setUp(s: *Sweep, fio: *shakedown.FaultIo) !void {
        s.finish();
        s.scratch = .init();
        errdefer s.scratch.cleanup();
        try s.scratch.dir().createDirPath(testing.io, "sub");
        if (s.kind != .create_new and s.kind != .keep_existing) {
            for (s.dests()) |d| try s.scratch.write(d, "old");
        }
        if (s.kind == .rename) try s.scratch.write("src", "new");
        s.h = try Harness.over(testing.allocator, fio, .{});
        s.live = true;
        s.pending_count = 0;
        s.reached = .none;
        s.published = false;
    }

    /// What a caller's defer does: every pending ends.
    pub fn tearDown(s: *Sweep) void {
        for (s.pendings[0..s.pending_count]) |*p| p.discard(testing.io);
        s.pending_count = 0;
    }

    fn finish(s: *Sweep) void {
        if (!s.live) return;
        s.h.destroy();
        s.scratch.cleanup();
        s.live = false;
    }

    pub fn run(s: *Sweep, base: Io) !void {
        _ = base;
        const io = s.h.io();
        const dir = s.scratch.dir();
        switch (s.kind) {
            .replace, .ordered, .create_new, .keep_existing => {
                const publish: airlock.Pending.Publish = switch (s.kind) {
                    .create_new => .create_new,
                    .keep_existing => .keep_existing,
                    else => .replace,
                };
                const level: airlock.Level = if (s.kind == .ordered) .ordered else .data;
                const done = try airlock.writeFile(io, dir, "a", "new", .{ .commit = .{ .publish = publish, .level = level } });
                s.reached = done.reached;
            },
            .sync_file => {
                const file = try dir.openFile(testing.io, "a", .{ .mode = .read_write });
                defer file.close(testing.io);
                try file.writePositionalAll(io, "new", 0);
                s.reached = try airlock.syncFile(io, file, .{});
            },
            .rename => s.reached = try airlock.rename(io, dir, "src", dir, "b", .{}),
            .remove => s.reached = try airlock.remove(io, dir, "a", .{}),
            .batch, .batch_two_dirs => try s.runBatch(io),
        }
        s.published = true;
    }

    fn runBatch(s: *Sweep, io: Io) !void {
        const dir = s.scratch.dir();
        for (s.dests()) |d| {
            s.pendings[s.pending_count] = try airlock.create(io, dir, d, .{});
            s.pending_count += 1;
            try s.pendings[s.pending_count - 1].file().writePositionalAll(io, "new", 0);
        }
        var slots: [8]airlock.Batch.Slot = undefined;
        var batch: airlock.Batch = .init(&slots);
        defer batch.reset(io);
        try batch.addPending(io, &s.pendings[0], .replace);
        try batch.addPending(io, &s.pendings[1], .replace);
        try batch.fence();
        try batch.addPending(io, &s.pendings[2], .replace);
        try batch.addDir(dir);
        s.reached = try batch.commit(io, .{ .parallel = 1 });
    }

    pub fn faultsFor(s: *Sweep, record: shakedown.IoTrace.Record) []const shakedown.IoFault {
        _ = s;
        const f = record.event.foreign orelse return &.{};
        return faultClasses(@fromBackingInt(@as(u8, @intCast(f.call))));
    }

    pub fn check(s: *Sweep, base: Io, result: anyerror!void, injected: ?shakedown.Injected) !void {
        _ = base;
        const err: ?anyerror = if (result) |_| null else |e| e;
        try s.checkFiles(err);
        try s.checkNoTemps(err);
        if (injected) |inj| try s.checkInjected(inj, err);
        if (err == null) try s.checkModel();
    }

    /// Old or new, never torn; new once the operation succeeded; untouched
    /// if it failed before publishing anything.
    fn checkFiles(s: *Sweep, err: ?anyerror) !void {
        var buffer: [16]u8 = undefined;
        const published = err == null or err.? == error.PublishedNotDurable;
        const initially: ?[]const u8 = if (s.kind == .create_new or s.kind == .keep_existing) null else "old";
        for (s.dests()) |d| {
            const got = s.scratch.read(d, &buffer);
            switch (s.kind) {
                // An in-place write is the caller's; only the sync is airlock's.
                .sync_file => if (err == null) try testing.expectEqualStrings("new", got.?),
                .remove => if (err == null) try testing.expectEqual(@as(?[]const u8, null), got),
                else => {
                    if (got) |bytes| {
                        if (!std.mem.eql(u8, bytes, "old") and !std.mem.eql(u8, bytes, "new")) return error.TornDestination;
                    }
                    // A batch or a rename that failed after its rename may
                    // leave the new name; it is then never torn.
                    const batch = s.kind == .batch or s.kind == .batch_two_dirs or s.kind == .rename;
                    if (err == null or (published and !batch)) {
                        try testing.expectEqualStrings("new", got orelse return error.MissingDestination);
                    } else if (!published and !batch) {
                        try testing.expectEqualDeep(initially, got);
                    }
                },
            }
        }
    }

    fn checkNoTemps(s: *Sweep, err: ?anyerror) !void {
        _ = err;
        try testing.expectEqual(@as(usize, 0), (try s.scratch.entries(".")).prefixed);
        var sub = try s.scratch.dir().openDir(testing.io, "sub", .{ .iterate = true });
        defer sub.close(testing.io);
        var it = sub.iterate();
        while (try it.next(testing.io)) |e| {
            if (std.mem.startsWith(u8, e.name, ".")) return error.TempLeft;
        }
    }

    fn checkInjected(s: *Sweep, inj: shakedown.Injected, err: ?anyerror) !void {
        if (inj.call != .foreign) return;
        const records = s.h.fio.trace().records();
        var at: ?usize = null;
        for (records, 0..) |r, i| if (r.step == inj.step) {
            at = i;
        };
        const index = at orelse return;
        const record = records[index];
        const call: Call = @fromBackingInt(@as(u8, @intCast(record.event.foreign.?.call)));
        const name = @errorName(inj.fault.fail);
        // An interruption is retried in place: the same call, at once.
        if (std.mem.eql(u8, name, "INTR")) {
            if (call == .close) {
                if (record.event.subject.path == null) return;
                for (records[index + 1 ..]) |r| {
                    const f = r.event.foreign orelse continue;
                    if (f.call == @backingInt(Call.close) and eqlPath(r.event.subject.path, record.event.subject.path)) return error.CloseRetried;
                }
                return;
            }
            try testing.expectEqual(@as(?anyerror, null), err);
            return;
        }
        // A failed sync is final for that file: nothing syncs it again.
        const failure = std.mem.eql(u8, name, "IO") or std.mem.eql(u8, name, "NOSPC") or std.mem.eql(u8, name, "IO_DEVICE_ERROR") or std.mem.eql(u8, name, "DISK_FULL");
        if (failure and isSync(call) and record.event.subject.path != null) {
            for (records[index + 1 ..]) |r| {
                const f = r.event.foreign orelse continue;
                if (isSync(@fromBackingInt(@as(u8, @intCast(f.call)))) and eqlPath(r.event.subject.path, record.event.subject.path)) return error.SyncAfterFailure;
            }
        }
    }

    fn checkModel(s: *Sweep) !void {
        if (s.kind == .batch_two_dirs or s.kind == .rename or s.kind == .remove or s.kind == .sync_file) return;
        var m: model_mod.Model = .init(model_mod.native());
        const proved = m.replay(s.h);
        if (s.reached.atLeast(.ordered) and !proved.atLeast(.ordered)) return error.ReportedAboveModel;
        if (s.reached.atLeast(.data) and !proved.atLeast(.data)) return error.ReportedAboveModel;
    }
};

fn isSync(call: Call) bool {
    return switch (call) {
        .sync_full, .sync_barrier, .sync_data, .sync_plain, .sync_writeout, .sync_dir => true,
        else => false,
    };
}

fn eqlPath(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn sweepOne(kind: Kind) !void {
    if (!is_tested_os) return error.SkipZigTest;
    var ctx: Sweep = .{ .kind = kind };
    defer ctx.finish();
    var report: shakedown.SweepReport = .{};
    defer report.deinit(testing.allocator);
    const result = shakedown.sweep(testing.allocator, testing.io, &ctx, .{
        .short = true,
        .diagnostics = &report,
        .errors = &.{ error.InputOutput, error.NoSpaceLeft },
    });
    _ = result catch |err| {
        if (report.failure) |f| {
            std.debug.print("sweep {t}: {t} at {any}\n{s}\n", .{ kind, f.err, f.injected, f.trace });
        }
        return err;
    };
}

test "sweep: replace at data" {
    try sweepOne(.replace);
}

test "sweep: replace at ordered" {
    try sweepOne(.ordered);
}

test "sweep: create_new" {
    try sweepOne(.create_new);
}

test "sweep: keep_existing" {
    try sweepOne(.keep_existing);
}

test "sweep: syncFile" {
    try sweepOne(.sync_file);
}

test "sweep: rename" {
    try sweepOne(.rename);
}

test "sweep: remove" {
    try sweepOne(.remove);
}

test "sweep: a batch of three with a fence" {
    try sweepOne(.batch);
}

test "sweep: a batch over two directories" {
    try sweepOne(.batch_two_dirs);
}

test "the model proves what a real replace reports, and no more" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    try s.write("a", "old");
    inline for (.{ airlock.Level.ordered, airlock.Level.data }) |level| {
        const h = try Harness.create(testing.allocator, testing.io, .{});
        defer h.destroy();
        const done = try airlock.writeFile(h.io(), s.dir(), "a", "new", .{ .commit = .{ .level = level } });
        var m: model_mod.Model = .init(model_mod.native());
        const proved = m.replay(h);
        try testing.expectEqual(@as(u8, 1), m.dest_count);
        try testing.expectEqual(@as(u8, 1), m.temp_count);
        try testing.expectEqual(if (level == .data) airlock.Reached.data else airlock.Reached.ordered, proved);
        try testing.expect(done.reached.atLeast(level));
    }
}

test "on Darwin the model shows the window barrier = false closes" {
    if (!is_darwin) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    inline for (.{ true, false }) |barrier| {
        const h = try Harness.create(testing.allocator, testing.io, .{});
        defer h.destroy();
        _ = try airlock.writeFile(h.io(), s.dir(), "a", "new", .{ .commit = .{ .barrier = barrier } });
        var honoured: model_mod.Model = .init(.darwin);
        var dropped: model_mod.Model = .init(.darwin_barrier_dropped);
        try testing.expectEqual(airlock.Reached.data, honoured.replay(h));
        // A drive that drops the barrier can tear the replace in the
        // window before the directory's flush; without the barrier there
        // is no window.
        try testing.expectEqual(if (barrier) airlock.Reached.none else airlock.Reached.data, dropped.replay(h));
    }
}

test "the model proves a batch with a fence" {
    if (!is_tested_os) return error.SkipZigTest;
    var s: harness.Scratch = .init();
    defer s.cleanup();
    const h = try Harness.create(testing.allocator, testing.io, .{});
    defer h.destroy();
    const io = h.io();
    var ps: [3]airlock.Pending = undefined;
    for (&ps, [_][]const u8{ "a", "b", "c" }) |*p, name| p.* = try airlock.create(io, s.dir(), name, .{});
    defer for (&ps) |*p| p.discard(io);
    var slots: [4]airlock.Batch.Slot = undefined;
    var batch: airlock.Batch = .init(&slots);
    defer batch.reset(io);
    try batch.addPending(io, &ps[0], .replace);
    try batch.addPending(io, &ps[1], .replace);
    try batch.fence();
    try batch.addPending(io, &ps[2], .replace);
    _ = try batch.commit(io, .{ .parallel = 1 });
    var m: model_mod.Model = .init(model_mod.native());
    try testing.expectEqual(airlock.Reached.data, m.replay(h));
    try testing.expectEqual(@as(u8, 3), m.dest_count);
}
