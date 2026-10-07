//! A crash-consistency model of airlock's call sequences, in the manner of
//! ALICE (Pillai et al., OSDI '14) and CrashMonkey.
//!
//! The model replays the raw calls of a run against one platform's
//! documented persistence rules and, at every point a crash could land,
//! enumerates every set of effects that could have reached the disk. It
//! checks what each destination then holds: the old file, the complete new
//! one, or a torn one (the new name over contents that did not persist).
//! From that it proves a level: `ordered` if no crash point can tear a
//! destination, `data` if, in addition, the end of the run leaves every
//! destination new in every crash state. For a batch it also checks each
//! fence: no crash point shows a rename after it without every rename
//! before it.
//!
//! The model covers one directory: the temps and the destinations of a
//! publish or a batch side by side. Each rule cites its source:
//!
//! - Linux, fsync(2) and fdatasync(2): a sync persists the file's data (and
//!   for `fdatasync` what it takes to read it back); "calling fsync() does
//!   not necessarily ensure that the entry in the directory containing the
//!   file has also reached disk. For that an explicit fsync() on a file
//!   descriptor for the directory is also needed." Anything not synced may
//!   or may not have persisted, in any combination.
//! - Darwin, fsync(2) and fcntl(2): `fsync` hands data to the device and
//!   does not persist it. `F_FULLFSYNC` persists the file and "data that had
//!   been fsync'd on the same device before". `F_BARRIERFSYNC` "applies to
//!   I/O that have been flushed with fsync(2) on the same device before":
//!   everything handed to the device before it reaches the disk before
//!   anything issued after it. The model runs with the barrier honoured, and
//!   with it dropped, as a drive without barrier support might.
//! - A symbolic link is a directory entry holding its target: it persists
//!   with the directory's entries, by the directory's sync.
//! - Windows, NtFlushBuffersFileEx and NtFlushBuffersFile: `DATA_SYNC_ONLY`
//!   persists the file's data and "metadata that is necessary for data
//!   retrieval"; `NO_SYNC` writes out without flushing the device cache; a
//!   plain flush persists the handle's file and, by flushing the device
//!   cache, whatever was written out before.
//!
//! The model is airlock's reading of those documents, so it cannot catch a
//! wrong reading. A real crash test (block-level replay on Linux) checks it
//! by hand before a release.
const std = @import("std");
const builtin = @import("builtin");
const seam = @import("airlock.testing");
const level = @import("../level.zig");
const Reached = level.Reached;

pub const Platform = enum { linux, darwin, darwin_barrier_dropped, windows };

/// The platform this build runs on, barrier honoured.
pub fn native() Platform {
    const os = builtin.target.os.tag;
    if (os == .linux) return .linux;
    if (os.isDarwin()) return .darwin;
    if (os == .windows) return .windows;
    return .linux;
}

const max_effects = 24;
const Mask = u32;

const Effect = struct {
    /// A temp's contents; a rename onto a destination; a symbolic link's
    /// creation, which is a directory entry and its target together.
    kind: enum { data, name, link },
    /// The temp an effect belongs to: its data, or the rename that points a
    /// destination at it. For a name, also its place in rename order.
    temp: u8,
    /// For a name: the destination it renames onto.
    dest: u8,
};

/// What a crash point leaves at one destination.
pub const State = enum { old, new, torn };

pub const Model = struct {
    platform: Platform,
    effects: [max_effects]Effect = undefined,
    count: u8 = 0,
    /// Effects that have reached the disk for certain.
    persisted: Mask = 0,
    /// Effects handed to the device, which a later device flush persists.
    written: Mask = 0,
    /// For each effect, the effects that must have reached the disk if it did
    /// (a barrier's order).
    requires: [max_effects]Mask = @splat(0),
    temps: [max_effects][]const u8 = undefined,
    temp_count: u8 = 0,
    /// The next temp a rename moves, in the order they were added.
    next_rename: u8 = 0,
    dests: [max_effects][]const u8 = undefined,
    dest_count: u8 = 0,
    /// Whether any crash point could leave a destination torn.
    ever_torn: bool = false,
    /// What a barrier ordered before everything issued after it.
    pending_barrier: Mask = 0,
    /// A batch's fences, as the number of renames before each.
    fences: [4]u8 = undefined,
    fence_count: u8 = 0,
    /// Whether any crash point could show a rename after a fence without
    /// one before it.
    fence_broken: bool = false,

    pub fn init(platform: Platform) Model {
        return .{ .platform = platform };
    }

    /// A temp file, its contents written: the data effect, not yet on disk.
    pub fn create(m: *Model, temp: []const u8) void {
        const t = m.temp_count;
        m.temps[t] = temp;
        m.temp_count += 1;
        m.add(.{ .kind = .data, .temp = t, .dest = 0 });
    }

    /// A symbolic link created under a temp name: its entry and its
    /// target reach the disk together, with the directory's entries.
    pub fn createLink(m: *Model, temp: []const u8) void {
        const t = m.temp_count;
        m.temps[t] = temp;
        m.temp_count += 1;
        m.add(.{ .kind = .link, .temp = t, .dest = 0 });
    }

    /// A batch's fence after its first `renames` renames: no crash may
    /// show a later rename without every earlier one.
    pub fn fenceAt(m: *Model, renames: u8) void {
        m.fences[m.fence_count] = renames;
        m.fence_count += 1;
    }

    /// Whether every fence held at every crash point so far.
    pub fn fencesHeld(m: *const Model) bool {
        return !m.fence_broken;
    }

    /// A destination that existed before the run, holding the old file.
    pub fn destination(m: *Model, name: []const u8) u8 {
        for (m.dests[0..m.dest_count], 0..) |d, i| if (std.mem.eql(u8, d, name)) return @intCast(i);
        m.dests[m.dest_count] = name;
        m.dest_count += 1;
        return m.dest_count - 1;
    }

    fn add(m: *Model, e: Effect) void {
        std.debug.assert(m.count < max_effects);
        m.effects[m.count] = e;
        m.count += 1;
    }

    fn tempIndex(m: *const Model, subject: ?[]const u8) ?u8 {
        const name = subject orelse return null;
        for (m.temps[0..m.temp_count], 0..) |t, i| if (std.mem.eql(u8, t, name)) return @intCast(i);
        return null;
    }

    fn dataOf(m: *const Model, temp: u8) Mask {
        var mask: Mask = 0;
        for (m.effects[0..m.count], 0..) |e, i| {
            if (e.kind != .name and e.temp == temp) mask |= @as(Mask, 1) << @intCast(i);
        }
        return mask;
    }

    /// The directory's entries: renames, and the links created in it.
    fn entries(m: *const Model) Mask {
        var mask: Mask = 0;
        for (m.effects[0..m.count], 0..) |e, i| {
            if (e.kind != .data) mask |= @as(Mask, 1) << @intCast(i);
        }
        return mask;
    }

    fn all(m: *const Model) Mask {
        return if (m.count == 32) ~@as(Mask, 0) else (@as(Mask, 1) << @intCast(m.count)) - 1;
    }

    /// Everything handed to the device before now reaches the disk before
    /// anything issued after it.
    fn barrier(m: *Model) void {
        // Effects issued later are added later; record the order as a
        // requirement on each future effect by remembering the mask now.
        m.pending_barrier |= m.written | m.persisted;
    }

    /// The effects a call makes, by platform. `subject` names the temp a
    /// file sync is on; a sync with no temp subject is on the directory.
    pub fn call(m: *Model, c: seam.Call, subject: ?[]const u8) void {
        const temp = m.tempIndex(subject);
        const file: Mask = if (temp) |t| m.dataOf(t) else 0;
        switch (c) {
            .create_temp => {},
            .rename, .rename_noreplace, .link, .win_rename_ex => {
                const d = m.destination(subject.?);
                m.add(.{ .kind = .name, .temp = m.next_rename, .dest = d });
                m.requires[m.count - 1] = m.pending_barrier;
                m.next_rename += 1;
            },
            .sync_data => m.persisted |= file,
            .sync_full => switch (m.platform) {
                .linux => m.persisted |= file,
                // A device flush: this file (or, with no temp named, the
                // directory's entries), and everything written before.
                else => m.persisted |= file | m.written | (if (temp == null) m.entries() else 0),
            },
            .sync_plain, .sync_writeout => m.written |= if (temp != null) file else m.entries(),
            .sync_barrier => {
                m.written |= file;
                if (m.platform == .darwin) m.barrier();
            },
            .sync_dir => switch (m.platform) {
                .linux => m.persisted |= m.entries(),
                else => m.persisted |= m.entries() | m.written,
            },
            else => {},
        }
        m.written |= m.persisted;
    }

    /// What each destination holds if exactly `on_disk` reached the disk.
    fn stateOf(m: *const Model, on_disk: Mask, dest: u8) State {
        var latest: ?Effect = null;
        for (m.effects[0..m.count], 0..) |e, i| {
            if (e.kind != .name or e.dest != dest) continue;
            if (on_disk & (@as(Mask, 1) << @intCast(i)) != 0) latest = e;
        }
        const e = latest orelse return .old;
        return if (on_disk & m.dataOf(e.temp) == m.dataOf(e.temp)) .new else .torn;
    }

    /// Whether `on_disk` shows a rename after a fence without every rename
    /// before it.
    fn breaksFence(m: *const Model, on_disk: Mask) bool {
        for (m.fences[0..m.fence_count]) |boundary| {
            var before_all = true;
            var after_any = false;
            for (m.effects[0..m.count], 0..) |e, i| {
                if (e.kind != .name) continue;
                const present = on_disk & (@as(Mask, 1) << @intCast(i)) != 0;
                if (e.temp < boundary and !present) before_all = false;
                if (e.temp >= boundary and present) after_any = true;
            }
            if (after_any and !before_all) return true;
        }
        return false;
    }

    fn consistent(m: *const Model, on_disk: Mask) bool {
        for (m.requires[0..m.count], 0..) |req, i| {
            if (on_disk & (@as(Mask, 1) << @intCast(i)) == 0) continue;
            if (on_disk & req != req) return false;
        }
        return true;
    }

    /// One crash point: every set of not-yet-persisted effects that could
    /// have reached the disk with the persisted ones. Returns whether every
    /// destination is new in every such set.
    pub fn crash(m: *Model) bool {
        const free = m.all() & ~m.persisted;
        var all_new = true;
        var subset: Mask = free;
        while (true) {
            const on_disk = m.persisted | subset;
            if (m.consistent(on_disk)) {
                if (m.breaksFence(on_disk)) m.fence_broken = true;
                for (0..m.dest_count) |d| switch (m.stateOf(on_disk, @intCast(d))) {
                    .torn => {
                        m.ever_torn = true;
                        all_new = false;
                    },
                    .old => all_new = false,
                    .new => {},
                };
            }
            if (subset == 0) break;
            subset = (subset - 1) & free;
        }
        return all_new;
    }

    /// The level the run proves, given whether its end left everything new.
    pub fn proves(m: *const Model, end_all_new: bool) Reached {
        if (m.ever_torn) return .none;
        return if (end_all_new) .data else .ordered;
    }

    /// Replays airlock's calls from a trace, a crash point after each, and
    /// returns the level proved. Calls a fault failed are not made.
    pub fn replay(m: *Model, h: *seam.Seam) Reached {
        _ = m.crash();
        var end_all_new = m.crash();
        for (h.fio.trace().records()) |r| {
            const f = r.event.foreign orelse continue;
            if (r.event.outcome == .err) continue;
            const c: seam.Call = @fromBackingInt(@as(u8, @intCast(f.call)));
            if (c == .create_temp) m.create(r.event.subject.path.?);
            if (c == .symlink) m.createLink(r.event.subject.path.?);
            m.call(c, r.event.subject.path);
            end_all_new = m.crash();
        }
        return m.proves(end_all_new);
    }
};

test "Linux: a synced temp renamed and the directory synced proves data" {
    var m: Model = .init(.linux);
    m.create("t");
    _ = m.destination("d");
    m.call(.sync_data, "t");
    try std.testing.expect(!m.crash());
    m.call(.rename, "d");
    try std.testing.expect(!m.crash());
    m.call(.sync_dir, null);
    try std.testing.expectEqual(Reached.data, m.proves(m.crash()));
}

test "Linux: a rename before the sync can tear" {
    var m: Model = .init(.linux);
    m.create("t");
    m.call(.rename, "d");
    m.call(.sync_dir, null);
    try std.testing.expectEqual(Reached.none, m.proves(m.crash()));
}

test "Darwin: the barrier orders the data before the name; dropped, it tears" {
    for ([_]Platform{ .darwin, .darwin_barrier_dropped }) |platform| {
        var m: Model = .init(platform);
        m.create("t");
        m.call(.sync_barrier, "t");
        _ = m.crash();
        m.call(.rename, "d");
        _ = m.crash();
        m.call(.sync_dir, null);
        const proved = m.proves(m.crash());
        // The end is durable either way: the directory's full flush
        // persists what the barrier wrote out. The window before it is not.
        try std.testing.expectEqual(if (platform == .darwin) Reached.data else Reached.none, proved);
    }
}

test "Darwin with barrier off: a full flush first, no window" {
    var m: Model = .init(.darwin_barrier_dropped);
    m.create("t");
    m.call(.sync_full, "t");
    _ = m.crash();
    m.call(.rename, "d");
    _ = m.crash();
    m.call(.sync_dir, null);
    try std.testing.expectEqual(Reached.data, m.proves(m.crash()));
}

test "Darwin: a writeout alone persists nothing" {
    var m: Model = .init(.darwin);
    m.create("t");
    m.call(.sync_writeout, "t");
    m.call(.rename, "d");
    m.call(.sync_writeout, null);
    try std.testing.expectEqual(Reached.none, m.proves(m.crash()));
}

test "Linux: a fence holds with a directory sync between the renames, and breaks without" {
    for ([_]bool{ true, false }) |synced| {
        var m: Model = .init(.linux);
        for ([_][]const u8{ "t0", "t1" }) |t| m.create(t);
        m.fenceAt(1);
        m.call(.sync_data, "t0");
        m.call(.sync_data, "t1");
        m.call(.rename, "a");
        _ = m.crash();
        if (synced) m.call(.sync_dir, null);
        _ = m.crash();
        m.call(.rename, "b");
        _ = m.crash();
        m.call(.sync_dir, null);
        _ = m.crash();
        try std.testing.expectEqual(synced, m.fencesHeld());
    }
}

test "a symbolic link renamed before its directory sync can tear; synced first, it cannot" {
    for ([_]bool{ true, false }) |synced| {
        var m: Model = .init(.linux);
        _ = m.destination("current");
        m.createLink("t");
        if (synced) m.call(.sync_dir, null);
        _ = m.crash();
        m.call(.rename, "current");
        _ = m.crash();
        m.call(.sync_dir, null);
        try std.testing.expectEqual(if (synced) Reached.data else Reached.none, m.proves(m.crash()));
    }
}
