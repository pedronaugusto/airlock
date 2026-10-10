//! Every crash of each operation, inside a `Sim`: airlock's calls routed
//! onto its simulated disk, a power loss at every step of the run, and
//! every state the disk could come back in after it. Each state is checked
//! for what the operation promises: a destination is old or new and never
//! torn; once the operation returned at `data`, it is new in every state;
//! a batch's fence holds whenever its renames do.
//!
//! The disk's rules are the platform's (`Sim.Fs`), checked against ext4,
//! xfs and btrfs by shakedown's crash replay; airlock's calls are the
//! platform's own, made one for one through the seam's route.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const airlock = @import("airlock.zig");
const seam = @import("airlock.testing");
const Seam = seam.Seam;

const os = builtin.target.os.tag;
const is_tested_os = os == .linux or os.isDarwin() or os == .windows;

const Kind = enum { replace, create_new, keep_existing, ordered, sync_file, rename, remove, batch, batch_two_dirs, sym_link, make_path };

/// The simulated disk's names, as this platform's file systems compare them.
const names: @FieldType(shakedown.Sim.Fs.Options, "names") = if (os.isDarwin()) .darwin else if (os == .windows) .windows else .posix;

const Operation = struct {
    kind: Kind,
    plan: []const seam.Plan.Entry = &.{},
    barrier: bool = true,
    max_states: u32 = 512,
    h: ?*Seam = null,
    reached: airlock.Reached = .none,
    /// Whether the stopped run returned before its crash.
    returned: bool = false,
    /// Whether the run's own setup was done before its crash.
    ready: bool = false,

    fn dests(s: *const Operation) []const []const u8 {
        return switch (s.kind) {
            .batch => &.{ "a", "b", "c" },
            .batch_two_dirs => &.{ "a", "sub/b", "sub/c" },
            .rename => &.{"b"},
            else => &.{"a"},
        };
    }

    fn existedBefore(s: *const Operation) bool {
        return s.kind != .create_new and s.kind != .keep_existing;
    }

    pub fn setUp(s: *Operation, sim: *shakedown.Sim) !void {
        const fs = sim.fs();
        try fs.mkdir("sub");
        if (s.existedBefore()) {
            for (s.dests()) |d| try fs.write(d, "old");
        }
        if (s.kind == .rename) try fs.write("src", "new");
        s.h = try Seam.create(testing.allocator, sim.io(), .{ .plan = s.plan, .trace = .off });
        s.reached = .none;
        s.returned = false;
        s.ready = s.kind != .sym_link;
    }

    pub fn tearDown(s: *Operation) void {
        if (s.h) |h| h.destroy();
        s.h = null;
    }

    pub fn run(s: *Operation, base: Io) !void {
        _ = base;
        const io = s.h.?.io();
        const dir = Io.Dir.cwd();
        if (s.kind == .sym_link) {
            // "a" is a link to "old-target"; the run points it at
            // "new-target". Reading through it says which. Set up durably,
            // so a crash after it finds both targets whole.
            _ = try airlock.writeFile(io, dir, "old-target", "old", .{});
            _ = try airlock.writeFile(io, dir, "new-target", "new", .{});
            try dir.deleteFile(io, "a");
            _ = try airlock.symLink(io, dir, "old-target", "a", .{});
            s.ready = true;
        }
        const commit: airlock.Pending.CommitOptions = .{ .barrier = s.barrier };
        switch (s.kind) {
            .replace, .ordered, .create_new, .keep_existing => {
                var options = commit;
                options.publish = switch (s.kind) {
                    .create_new => .create_new,
                    .keep_existing => .keep_existing,
                    else => .replace,
                };
                options.level = if (s.kind == .ordered) .ordered else .data;
                const done = try airlock.writeFile(io, dir, "a", "new", .{ .commit = options });
                s.reached = done.reached;
            },
            .sync_file => {
                const file = try dir.openFile(io, "a", .{ .mode = .read_write });
                defer file.close(io);
                try file.writePositionalAll(io, "new", 0);
                s.reached = try airlock.syncFile(io, file, .{ .barrier = s.barrier });
            },
            .rename => s.reached = try airlock.rename(io, dir, "src", dir, "b", .{}),
            .remove => s.reached = try airlock.remove(io, dir, "a", .{}),
            .sym_link => s.reached = try airlock.symLink(io, dir, "new-target", "a", .{}),
            .make_path => s.reached = (try airlock.makePath(io, dir, "sub/x/y", .{})).reached,
            .batch, .batch_two_dirs => try s.runBatch(io),
        }
        s.returned = true;
    }

    fn runBatch(s: *Operation, io: Io) !void {
        var pendings: [3]airlock.Pending = undefined;
        var count: usize = 0;
        defer for (pendings[0..count]) |*p| p.discard(io);
        const dir = Io.Dir.cwd();
        for (s.dests()) |d| {
            pendings[count] = try airlock.create(io, dir, d, .{});
            count += 1;
            try pendings[count - 1].file().writePositionalAll(io, "new", 0);
        }
        var slots: [8]airlock.Batch.Slot = undefined;
        var batch: airlock.Batch = .init(&slots);
        defer batch.reset(io);
        try batch.addPending(io, &pendings[0], .replace);
        try batch.addPending(io, &pendings[1], .replace);
        try batch.fence();
        try batch.addPending(io, &pendings[2], .replace);
        try batch.addDir(dir);
        s.reached = try batch.commit(io, .{ .parallel = 1, .barrier = s.barrier });
    }

    /// What a program does after the crash: removes the temps it left,
    /// through a seam over the recovery's own simulation.
    pub fn recover(s: *Operation, io: Io) !void {
        _ = s;
        const h = try Seam.create(testing.allocator, io, .{ .trace = .off });
        defer h.destroy();
        for ([_][]const u8{ ".", "sub" }) |path| {
            var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            defer dir.close(io);
            _ = try airlock.pruneTemps(h.io(), dir, ".", .{ .older_than = .zero });
        }
    }

    /// What the disk came back with, against what the run promised.
    pub fn check(s: *Operation, io: Io) !void {
        try expectNoTemps(io);
        if (!s.ready) return;
        const durable = s.returned and s.reached.atLeast(.data);
        const cwd = Io.Dir.cwd();
        switch (s.kind) {
            .sync_file => if (durable) try expectContents(io, "a", "new"),
            .remove => if (durable) try testing.expectError(error.FileNotFound, cwd.statFile(io, "a", .{})),
            .make_path => if (durable) (try cwd.openDir(io, "sub/x/y", .{})).close(io),
            else => {
                var news: [3]bool = @splat(false);
                for (s.dests(), 0..) |d, i| {
                    var buffer: [16]u8 = undefined;
                    const got = cwd.readFile(io, d, &buffer) catch |err| switch (err) {
                        error.FileNotFound => {
                            // A destination that existed before the run
                            // never goes missing.
                            if (s.existedBefore()) return error.LostDestination;
                            if (durable and s.kind != .keep_existing) return error.MissingDestination;
                            continue;
                        },
                        else => |e| return e,
                    };
                    news[i] = std.mem.eql(u8, got, "new");
                    if (!news[i] and !std.mem.eql(u8, got, "old")) return error.TornDestination;
                    if (durable and !news[i] and s.kind != .keep_existing) return error.NotDurable;
                }
                // The fence: the rename after it is never seen without
                // both before it.
                if ((s.kind == .batch or s.kind == .batch_two_dirs) and news[2] and !(news[0] and news[1])) return error.FenceBroken;
            },
        }
    }
};

/// No temp survives the recovery's prune.
fn expectNoTemps(io: Io) !void {
    for ([_][]const u8{ ".", "sub" }) |path| {
        var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) return error.TempLeft;
        }
    }
}

fn expectContents(io: Io, name: []const u8, expected: []const u8) !void {
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings(expected, try Io.Dir.cwd().readFile(io, name, &buffer));
}

fn everyCrash(ctx: *Operation) !void {
    if (!is_tested_os) return error.SkipZigTest;
    var report: shakedown.EveryFaultReport = .{};
    defer report.deinit();
    const result = shakedown.everyCrash(testing.allocator, ctx, .{
        .sim = .{ .fs = .{ .names = names }, .watchdog = null },
        .max_states = ctx.max_states,
        .diagnostics = &report,
    });
    const done = result catch |err| {
        if (report.failure) |f| {
            std.debug.print("every crash {t}: {t} at {any}\n{s}\n", .{ ctx.kind, f.err, f.injected, f.trace });
        }
        return err;
    };
    // Every state of every point was tried.
    try testing.expectEqual(@as(u64, 0), done.bounded);
}

fn crashes(kind: Kind) !void {
    var ctx: Operation = .{ .kind = kind };
    try everyCrash(&ctx);
}

test "every crash: replace at data" {
    try crashes(.replace);
}

test "every crash: replace at ordered" {
    try crashes(.ordered);
}

test "every crash: create_new" {
    try crashes(.create_new);
}

test "every crash: keep_existing" {
    try crashes(.keep_existing);
}

test "every crash: syncFile" {
    try crashes(.sync_file);
}

test "every crash: rename" {
    try crashes(.rename);
}

test "every crash: remove" {
    try crashes(.remove);
}

test "every crash: a batch of three with a fence" {
    try crashes(.batch);
}

test "every crash: a batch over two directories" {
    try crashes(.batch_two_dirs);
}

test "every crash: a symbolic link swap" {
    if (os == .windows) return error.SkipZigTest;
    try crashes(.sym_link);
}

test "every crash: makePath" {
    try crashes(.make_path);
}

test "every crash: Darwin with barrier off, a full flush on the file and the directory" {
    if (!os.isDarwin()) return error.SkipZigTest;
    var ctx: Operation = .{ .kind = .replace, .barrier = false };
    try everyCrash(&ctx);
}

test "every crash: a refused directory sync reports ordered, and keeps it" {
    // The directory's sync refused: the name may be lost, the data never torn.
    const refused: seam.Code = if (os == .windows) .NOT_SUPPORTED else if (os.isDarwin()) .NOTTY else .INVAL;
    const plan = [_]seam.Plan.Entry{seam.always(.sync_dir, refused)};
    var ctx: Operation = .{ .kind = .replace, .plan = &plan };
    try everyCrash(&ctx);
}
