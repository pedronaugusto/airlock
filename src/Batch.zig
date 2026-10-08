//! Many files, publishes and directories made durable under the fewest
//! barriers: a cheap writeout per file, one barrier per volume, the renames
//! in the order they were added, then each distinct directory once and one
//! device flush per volume.
//!
//! | Step | Linux | Darwin | Windows |
//! |---|---|---|---|
//! | 1. each file | `fdatasync` (`fsync` at `full`), `parallel` at once | `fsync` (W) | `NO_SYNC` (W) |
//! | 2. each volume, if there are renames | none | `F_BARRIERFSYNC` (B) | `NtFlushBuffersFile` (F) |
//! | 3. renames, in add order | `fence`: `fsync` of every directory touched since the last fence | `fence`: W of those, then one B | `fence`: W of those, then one F |
//! | 3b. `keep_existing` found the name taken | the existing file is synced, and its directory in step 4 | W, and its directory in step 4 | W, and its directory in step 4 |
//! | 4. each distinct directory | `fsync`, `parallel` at once | W | W |
//! | 5. each volume | none | `F_FULLFSYNC` (F) | `NtFlushBuffersFile` (F) |
//!
//! At `ordered` a batch stops after the renames; at `none` it only renames.
//! A fence the filesystem cannot keep (it refuses a directory's sync)
//! leaves the batch `.written` at best.
//! Directories are told apart by their `FileId`, and volumes by their
//! device (on Windows, the serial and the NT device name: a serial alone
//! is not unique across cloned volumes). A false split costs one flush; a
//! false merge would skip one, so keys never merge two volumes.
//!
//! airlock never allocates: the slots are the caller's. A full batch
//! returns `error.BatchFull`; commit it and start the next one.
//!
//! Descriptors: each pending holds its temp until its sync (POSIX) or its
//! rename (Windows), and the batch opens each distinct parent only when it
//! first renames into it. `addPath` files are opened `parallel` at a time
//! and closed after their sync, except one kept per volume on macOS and
//! Windows for the device flush. So a batch holds at most one descriptor
//! per slot, plus `parallel`, and a batch of paths holds about `parallel`
//! whatever its size.
//!
//! Any failure poisons the batch: pending publishes not yet renamed are
//! discarded, renames already made are reported as
//! `error.PublishedNotDurable`, `failure` names the slot (in add order) and
//! its error, and `reset` is the only valid next call. A cancel before the
//! first rename publishes nothing; after it, it is `PublishedNotDurable`
//! with `cause` `Canceled`.
const Blocking = @import("Blocking.zig");
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");
const platform = @import("platform.zig");
const level_mod = @import("level.zig");
const Pending = @import("Pending.zig");
const Staged = @import("Staged.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const Fallback = level_mod.Fallback;

const Batch = @This();

const native_os = builtin.target.os.tag;
const is_windows = native_os == .windows;
const is_linux = native_os == .linux;
const is_darwin = native_os.isDarwin();

/// Private: the caller's slot storage.
slots: []Slot,
/// Private: how many slots are in use.
len: u32 = 0,
/// Private: the failure of the last commit.
failed: ?Failure = null,

pub const Failure = struct { slot: u32, cause: anyerror };

const Kind = enum(u8) { file, path, pending, dir, dir_path, fence };

/// One entry of a batch. Opaque; the caller only provides the storage.
pub const Slot = struct {
    /// Private: the identity of a directory, for dedup.
    id: sys.Id = .{ .volume = 0, .file = 0 },
    /// Private: Windows, the hash of the volume's device name.
    device: u64 = 0,
    /// Private: a file or directory handle, or a pending's parent.
    handle: sys.Handle = undefined,
    /// Private: the pending's state, for a pending slot.
    pending: ?*Staged = null,
    /// Private: the root a path slot is relative to.
    root: sys.Handle = undefined,
    /// Private: the path of a path slot, borrowed.
    path: []const u8 = &.{},
    /// Private: the slot's place in add order.
    index: u32 = 0,
    kind: Kind = .fence,
    publish: Pending.Publish = .replace,
    /// Private: the batch opened `handle` and closes it.
    owned: bool = false,
    /// Private: `handle` is open.
    open: bool = false,
    /// Private: a name changed in the directory this slot stands for.
    touched: bool = false,
    /// Private: what this slot's own sync reached, in a commit.
    reached: Reached = .none,
    /// Private: this slot's error, in a commit.
    err: ?Error = null,
    /// Private: a directory sync the filesystem refused, in a commit.
    refused: bool = false,
    /// Private: the first slot of its directory once step 4 sorted them.
    distinct: bool = false,
    /// Private: `id.volume` and `device` name the volume a file slot's
    /// sync registered, for the parent that later stands for it.
    on_volume: bool = false,
};

pub fn init(storage: []Slot) Batch {
    return .{ .slots = storage };
}

pub const AddError = error{BatchFull};

fn push(b: *Batch, slot: Slot) AddError!void {
    if (b.len == b.slots.len) return error.BatchFull;
    var s = slot;
    s.index = b.len;
    b.slots[b.len] = s;
    b.len += 1;
}

/// A file written in place, synced through the caller's handle (which
/// sees its writeback errors). Borrowed until `commit` returns. On Windows
/// the handle needs write access.
pub fn addFile(b: *Batch, file: Io.File) AddError!void {
    return b.push(.{ .kind = .file, .handle = file.handle, .open = true });
}

/// A file opened by the batch at commit. A fresh descriptor can miss a
/// writeback error another one already saw (see `syncPath`); this is for
/// checkout-sized work, where keeping every writing handle open is not
/// possible. `sub_path` is borrowed until `commit` returns.
pub fn addPath(b: *Batch, dir: Io.Dir, sub_path: []const u8) AddError!void {
    return b.push(.{ .kind = .path, .root = dir.handle, .path = sub_path });
}

/// A pending publish: synced through its own handle, renamed in add order,
/// its directory synced. A parent airlock opened for it is closed now and
/// reopened, once per distinct directory, at commit.
/// A pending a failed rename left synced is renamed without a second sync;
/// what that first sync reached is its part of the batch.
pub fn addPending(b: *Batch, io: Io, p: *Pending, publish: Pending.Publish) AddError!void {
    const staged = &p.staged;
    std.debug.assert(staged.state == .open or staged.state == .synced);
    try b.push(.{ .kind = .pending, .pending = staged, .publish = publish });
    staged.dropParent(io);
}

/// A directory whose names changed. Borrowed until `commit` returns.
pub fn addDir(b: *Batch, dir: Io.Dir) AddError!void {
    return b.push(.{ .kind = .dir, .handle = dir.handle, .open = true, .touched = true });
}

/// A directory, opened at commit. `sub_path` is borrowed until `commit`
/// returns.
pub fn addDirPath(b: *Batch, dir: Io.Dir, sub_path: []const u8) AddError!void {
    return b.push(.{ .kind = .dir_path, .root = dir.handle, .path = sub_path, .touched = true });
}

/// Renames added after this reach the disk after those added before it.
pub fn fence(b: *Batch) AddError!void {
    return b.push(.{ .kind = .fence });
}

pub const Options = struct {
    level: Level = .data,
    /// Linux: how many syncs run at once; 1 = one after another.
    parallel: u8 = 16,
    /// Windows: how long to retry a rename a scanner is blocking.
    busy_deadline: Io.Duration = .fromMilliseconds(2000),
    /// As `SyncOptions.barrier`.
    barrier: bool = true,
    /// Optional executor for raw syncs; null runs inline. Borrowed for this call.
    blocking: ?Blocking = null,
};

pub const Error = Pending.CommitError || platform.SyncPathError || platform.DirSyncError || Io.File.StatError || error{BatchFull};

/// `Error`, and a filesystem that cannot keep the level.
pub const CommitOrRefuseError = Error || error{
    /// A part of the batch reached less than the level. Darwin and Windows
    /// know before the first rename, and nothing is published; Linux
    /// learns of a refused directory sync only after the renames, and
    /// that is `PublishedNotDurable`.
    LevelUnavailable,
};

fn ErrorOf(comptime fallback: Fallback) type {
    return if (fallback == .refuse) CommitOrRefuseError else Error;
}

/// After a failed commit: the slot (in add order) whose call failed, and
/// its error.
pub fn failure(b: *const Batch) ?Failure {
    return b.failed;
}

/// Ends the batch: discards pendings not published, closes what the batch
/// opened, and empties it for reuse.
pub fn reset(b: *Batch, io: Io) void {
    for (b.slots[0..b.len]) |*s| {
        if (s.pending) |p| {
            if (p.state == .open or p.state == .synced or p.state == .poisoned) p.discard(io) else p.finish(io);
        }
        closeSlot(io, s);
    }
    b.len = 0;
}

fn closeSlot(io: Io, s: *Slot) void {
    if (s.owned and s.open) sys.release(io, s.handle);
    s.open = false;
    s.owned = false;
}

/// Makes everything in the batch durable at `options.level`, as the table
/// above says, and reports what was reached: a filesystem that refuses a
/// call gets the strongest one it accepts, and the result says so. Empties
/// the batch on success.
pub fn commit(b: *Batch, io: Io, options: Options) Error!Reached {
    return b.commitAs(.report, io, options);
}

/// `commit`, but a part that reaches less than `options.level` is
/// `error.LevelUnavailable` rather than a weaker result.
pub fn commitOrRefuse(b: *Batch, io: Io, options: Options) CommitOrRefuseError!Reached {
    return b.commitAs(.refuse, io, options);
}

fn commitAs(b: *Batch, comptime fallback: Fallback, io: Io, options: Options) ErrorOf(fallback)!Reached {
    b.failed = null;
    var run: Run(fallback) = .{ .batch = b, .options = options, .io = io };
    const reached = run.go() catch |err| {
        b.poison(io);
        if (run.renamed and err != error.PublishedNotDurable) return error.PublishedNotDurable;
        return err;
    };
    b.reset(io);
    return reached;
}

/// After a failure: discard every pending not yet renamed.
fn poison(b: *Batch, io: Io) void {
    for (b.slots[0..b.len]) |*s| {
        if (s.pending) |p| {
            if (p.state == .open or p.state == .synced) p.discard(io);
        }
    }
}

/// A volume a batch flushes once: its key and a handle on it.
const Volume = struct {
    volume: u64,
    device: u64,
    /// A handle on the volume to flush through, and whether it is a
    /// directory (Windows reopens one for the flush). Null while the
    /// volume holds only pendings whose parents the batch has not opened
    /// yet; each pending's parent stands for it once opened.
    handle: ?sys.Handle,
    is_dir: bool,
    /// The slot `handle` came from, for `failure`.
    slot: u32,
    /// Something on the volume was only written out and needs the flush.
    needs_flush: bool = false,
    /// A pending temp on the volume, for the barrier before the renames,
    /// and its name.
    temp: ?sys.Handle = null,
    temp_name: ?[]const u8 = null,
};

const max_volumes = 16;

/// The state of one commit, refusing or reporting as `fallback` says.
fn Run(comptime fallback: Fallback) type {
    return struct {
        const Self = @This();
        /// What a step that can refuse fails with.
        const E = ErrorOf(fallback);

        batch: *Batch,
        options: Options,
        /// The commit's `Io`, for the length of the call.
        io: Io,
        volumes: [max_volumes]Volume = undefined,
        volume_count: u8 = 0,
        /// The weakest any part reached so far.
        reached: Reached = .full,
        renames: u32 = 0,
        renamed: bool = false,

        fn slots(r: *Self) []Slot {
            return r.batch.slots[0..r.batch.len];
        }

        /// Records a failure at `s` (the first one wins) and returns `err`.
        fn fail(r: *Self, s: *const Slot, err: E) E {
            if (r.batch.failed == null) r.batch.failed = .{ .slot = s.index, .cause = err };
            if (s.pending) |p| if (p.state == .open) p.markFailed(r.io, err);
            return err;
        }

        /// Folds in what one part reached, refusing below the level if asked.
        fn part(r: *Self, s: *const Slot, reached: Reached) E!void {
            if (fallback == .refuse and !reached.atLeast(r.options.level)) return r.fail(s, error.LevelUnavailable);
            r.reached = Reached.min(r.reached, reached);
        }

        fn go(r: *Self) E!Reached {
            for (r.slots()) |s| if (s.kind == .pending) {
                r.renames += 1;
            };
            const level = r.options.level;
            try r.openDirs();
            if (level != .none) try r.syncFiles();
            if (level != .none and r.renames > 0) try r.barrier();
            try r.closeTemps();
            try r.publish();
            if (@backingInt(level) < @backingInt(Level.data)) {
                return if (level == .none) .none else Reached.min(r.reached, .ordered);
            }
            try r.syncDirs();
            try r.flushVolumes();
            return r.reached;
        }

        // -- directories ------------------------------------------------------

        /// Opens each `addDirPath` directory; `cwd()` is reopened as `"."`,
        /// which a sync can use. Pending parents are opened at their renames.
        fn openDirs(r: *Self) E!void {
            for (r.slots()) |*s| switch (s.kind) {
                .dir_path => {
                    s.handle = sys.openDir(r.io, s.root, s.path) catch |err| return r.fail(s, err);
                    s.owned = true;
                    s.open = true;
                },
                .dir => try r.ownCwd(s),
                else => {},
            };
        }

        /// A slot whose directory is `cwd()` gets its own handle on `"."`.
        fn ownCwd(r: *Self, s: *Slot) E!void {
            if (is_windows or s.handle != sys.at_fdcwd) return;
            s.handle = sys.openDir(r.io, sys.at_fdcwd, ".") catch |err| return r.fail(s, err);
            s.owned = true;
            s.open = true;
        }

        /// Opens a pending's parent before its rename: the handle an earlier
        /// pending already holds on it, or a new one. On macOS and Windows it
        /// then stands for its volume's flush.
        fn openParent(r: *Self, s: *Slot, earlier: []const Slot) E!void {
            const p = s.pending.?;
            s.root = p.root.handle;
            s.path = p.parentSubPath() orelse "";
            if (findParent(earlier, s)) |shared| {
                s.handle = shared;
                s.open = true;
            } else if (s.path.len == 0) {
                s.handle = s.root;
                s.open = true;
                try r.ownCwd(s);
            } else {
                s.handle = sys.openDir(r.io, s.root, s.path) catch |err| return r.fail(s, err);
                s.owned = true;
                s.open = true;
            }
            p.adoptParent(.{ .handle = s.handle });
            if (s.on_volume) _ = r.volume(s.id.volume, s.device, s.handle, true, s.index);
        }

        /// The handle an earlier pending already holds on the same parent.
        fn findParent(earlier: []const Slot, s: *const Slot) ?sys.Handle {
            for (earlier) |e| {
                if (e.kind == .pending and e.open and e.root == s.root and std.mem.eql(u8, e.path, s.path)) return e.handle;
            }
            return null;
        }

        // -- step 1: files ----------------------------------------------------

        fn isFileSlot(s: *const Slot) bool {
            return s.kind == .file or s.kind == .path or s.kind == .pending;
        }

        fn syncFiles(r: *Self) E!void {
            if (is_linux and r.options.parallel > 1) return r.syncFilesConcurrently();
            for (r.slots()) |*s| if (isFileSlot(s)) {
                syncOne(r, s);
                if (s.err) |err| return r.fail(s, err);
                try r.part(s, s.reached);
            };
        }

        /// Linux: `parallel` syncs at once; the journal merges concurrent
        /// commits into a few. One after another where the `Io` has no
        /// concurrency.
        fn syncFilesConcurrently(r: *Self) E!void {
            try r.concurrently(isFileSlot, syncOne);
            for (r.slots()) |*s| if (isFileSlot(s)) {
                if (s.err) |err| return r.fail(s, err);
                try r.part(s, s.reached);
            };
        }

        /// Runs `step` on every slot `selected` picks, `parallel` at once, in
        /// add order (or sorted order, once sorted). Each leaves its result in
        /// its slot.
        fn concurrently(r: *Self, comptime selected: fn (*const Slot) bool, comptime step: fn (*Self, *Slot) void) E!void {
            const all = r.slots();
            var start: usize = 0;
            while (start < all.len) {
                var group: Io.Group = .init;
                var started: usize = 0;
                var i = start;
                while (i < all.len and started < r.options.parallel) : (i += 1) {
                    const s = &all[i];
                    if (!selected(s)) continue;
                    group.concurrent(r.io, step, .{ r, s }) catch step(r, s);
                    started += 1;
                }
                group.await(r.io) catch |err| {
                    group.cancel(r.io);
                    return err;
                };
                start = i;
            }
        }

        /// One file's step 1, its result left in the slot.
        fn syncOne(r: *Self, s: *Slot) void {
            s.err = null;
            if (s.pending) |p| switch (p.state) {
                .synced => {
                    syncedPending(r, s, p);
                    return;
                },
                else => p.flushWriter(r.io) catch |err| {
                    s.err = err;
                    return;
                },
            };
            const handle = r.fileHandle(s) catch |err| {
                s.err = err;
                return;
            };
            s.reached = r.syncHandle(s, handle) catch |err| blk: {
                s.err = err;
                break :blk .none;
            };
            // A path's handle is closed after its sync, unless it stands for
            // its volume's flush.
            if (s.kind == .path and s.open and !r.standsForVolume(handle)) {
                sys.release(r.io, handle);
                s.open = false;
                s.owned = false;
            }
        }

        /// A pending a failed rename left synced: its temp is not synced again
        /// (on POSIX it is closed), so what its first sync reached is its part.
        fn syncedPending(r: *Self, s: *Slot, p: *Staged) void {
            const level = r.options.level;
            // Darwin: a barrier ordered it, and the flush of its directory's
            // volume after the renames persists it.
            const flushed_later = is_darwin and p.file_reached == .ordered and @backingInt(level) >= @backingInt(Level.data);
            s.reached = if (flushed_later) .full else p.file_reached;
        }

        /// The handle a file slot syncs through, opening a path slot.
        fn fileHandle(r: *Self, s: *Slot) Error!sys.Handle {
            switch (s.kind) {
                .file => return s.handle,
                .pending => return s.pending.?.file.handle,
                .path => {
                    s.handle = try sys.openFile(r.io, s.root, s.path);
                    s.owned = true;
                    s.open = true;
                    return s.handle;
                },
                else => unreachable, // unreachable: only file slots reach here
            }
        }

        /// Linux syncs each file at the level; Darwin and Windows write each one
        /// out and leave the device flush to one call per volume, made through
        /// a handle that stays open: a pending's parent once the batch opened
        /// it, or a file's own.
        fn syncHandle(r: *Self, s: *Slot, handle: sys.Handle) Error!Reached {
            const subject = if (s.pending) |p| p.tempName() else s.path;
            if (!is_darwin and !is_windows) return platform.syncChain(r.io, r.options.blocking, handle, r.options.level, true, subject);
            const reached = try platform.writeout(r.io, r.options.blocking, handle, subject);
            if (reached != .written) return reached;
            const id = try sys.statId(r.io, handle);
            const device = if (is_windows) try sys.volumeName(r.io, handle) else 0;
            const parent_open = s.kind == .pending and s.open;
            const rep: ?sys.Handle = if (s.kind != .pending) handle else if (parent_open) s.handle else null;
            const v = r.volume(id.volume, device, rep, parent_open, s.index) orelse
                return platform.volumeFlush(r.io, r.options.blocking, handle, subject);
            v.needs_flush = true;
            if (s.kind == .pending and !parent_open) {
                s.id.volume = id.volume;
                s.device = device;
                s.on_volume = true;
            }
            if (s.kind == .pending and s.pending.?.state == .open and v.temp == null) {
                v.temp = handle;
                v.temp_name = subject;
            }
            return .full;
        }

        /// The volume with this key, added if new; `handle` stands for it if
        /// none does yet, or if it is a directory and the one there is not.
        /// Null once the table is full (the caller then flushes at its own
        /// handle).
        fn volume(r: *Self, key: u64, device: u64, handle: ?sys.Handle, is_dir: bool, slot: u32) ?*Volume {
            for (r.volumes[0..r.volume_count]) |*v| {
                if (v.volume == key and v.device == device) {
                    if (handle != null and (v.handle == null or (is_dir and !v.is_dir))) {
                        v.handle = handle;
                        v.is_dir = is_dir;
                        v.slot = slot;
                    }
                    return v;
                }
            }
            if (r.volume_count == max_volumes) return null;
            r.volumes[r.volume_count] = .{ .volume = key, .device = device, .handle = handle, .is_dir = is_dir, .slot = slot };
            r.volume_count += 1;
            return &r.volumes[r.volume_count - 1];
        }

        /// Whether `handle` is the one a volume flushes through.
        fn standsForVolume(r: *Self, handle: sys.Handle) bool {
            for (r.volumes[0..r.volume_count]) |v| if (v.handle == handle) return true;
            return false;
        }

        // -- step 2: one barrier per volume -----------------------------------

        fn barrier(r: *Self) E!void {
            if (!is_darwin and !is_windows) return;
            for (r.volumes[0..r.volume_count]) |v| {
                const temp = v.temp orelse continue;
                const slot = &r.batch.slots[v.slot];
                const reached = (if (is_windows)
                    platform.volumeFlush(r.io, r.options.blocking, temp, v.temp_name)
                else
                    platform.volumeBarrier(r.io, r.options.blocking, temp, r.options.barrier, v.temp_name)) catch |err| return r.fail(slot, err);
                // A barrier or a flush keeps the order; a refused one leaves
                // only what the fallback reached.
                if (!reached.atLeast(.ordered)) try r.part(slot, reached);
            }
        }

        /// POSIX: each temp closed once, its error a failed sync. All of them
        /// before the first rename, so a failure here publishes nothing.
        fn closeTemps(r: *Self) E!void {
            for (r.slots()) |*s| {
                const p = s.pending orelse continue;
                if (p.state != .open) continue;
                p.markSynced(r.io, s.reached) catch |err| return r.fail(s, err);
            }
        }

        // -- step 3: renames --------------------------------------------------

        fn publish(r: *Self) E!void {
            var segment: usize = 0;
            const all = r.slots();
            for (all, 0..) |*s, i| switch (s.kind) {
                .pending => {
                    r.io.checkCancel() catch |err| return r.fail(s, err);
                    const p = s.pending.?;
                    try r.openParent(s, all[0..i]);
                    const renamed = p.renameSynced(r.io, s.publish, r.options.busy_deadline) catch |err| return r.fail(s, err);
                    // Windows keeps the temp open for the rename by handle;
                    // after it the handle has no use.
                    p.finish(r.io);
                    if (renamed) {
                        s.touched = true;
                        r.renamed = true;
                    } else if (r.options.level != .none) {
                        try r.syncKept(s);
                    }
                },
                .fence => {
                    if (r.options.level != .none) try r.fenceDirs(all[segment..i], s);
                    segment = i + 1;
                },
                else => {},
            };
        }

        /// 3b: `keep_existing` found the name taken. The existing file may have
        /// been written by someone who never synced it or its name; a batch
        /// that reports `.data` must not hold such a file. Its directory is
        /// synced in step 4 with the others.
        fn syncKept(r: *Self, s: *Slot) E!void {
            const p = s.pending.?;
            const handle = sys.openFile(r.io, s.handle, p.baseName()) catch |err| return r.fail(s, err);
            defer sys.release(r.io, handle);
            const reached = r.syncHandle(s, handle) catch |err| return r.fail(s, err);
            try r.part(s, reached);
            s.touched = true;
        }

        /// A fence: every directory renamed into since the last fence is synced
        /// (Darwin and Windows: written out, then one barrier or flush on the
        /// last), so the renames after it reach the disk after these. A fence
        /// the filesystem cannot keep, because it refuses a directory's sync,
        /// leaves the batch `.written` at best: each file still ends old or
        /// new, but a crash may show a rename after the fence without those
        /// before it.
        fn fenceDirs(r: *Self, segment: []Slot, at: *const Slot) E!void {
            var last: ?*Slot = null;
            for (segment, 0..) |*s, i| {
                if (s.kind != .pending or !s.touched) continue;
                if (seenHandle(segment[0..i], s.handle)) continue;
                last = s;
                if (is_darwin or is_windows) {
                    const reached = r.writeoutDir(s.handle) catch |err| return r.fail(s, err);
                    if (reached == .none) try r.part(s, .written);
                } else {
                    syncDirOne(r, s);
                    if (s.err) |err| return r.fail(s, err);
                    try r.part(s, if (s.refused) .written else s.reached);
                }
            }
            const s = last orelse return;
            if (!is_darwin and !is_windows) return;
            const reached = r.flushDir(s.handle, true) catch |err| return r.fail(at, err);
            if (!reached.atLeast(.ordered)) try r.part(s, Reached.min(reached, .written));
        }

        fn seenHandle(earlier: []const Slot, handle: sys.Handle) bool {
            for (earlier) |e| if (e.kind == .pending and e.touched and e.handle == handle) return true;
            return false;
        }

        // -- steps 4 and 5: directories, then volumes --------------------------

        fn isDirSlot(s: *const Slot) bool {
            return switch (s.kind) {
                .dir, .dir_path => true,
                .pending => s.touched,
                else => false,
            };
        }

        fn syncDirs(r: *Self) E!void {
            const all = r.slots();
            for (all) |*s| if (isDirSlot(s)) {
                const id = sys.statId(r.io, s.handle) catch |err| return r.fail(s, err);
                s.id = id;
                s.device = if (is_windows) sys.volumeName(r.io, s.handle) catch |err| return r.fail(s, err) else 0;
            };
            // The rename order is spent: sort by directory key, in place, and
            // mark the first slot of each distinct directory.
            std.sort.pdq(Slot, all, {}, dirOrder);
            for (all, 0..) |*s, i| {
                s.err = null;
                s.refused = false;
                s.reached = .none;
                s.distinct = isDirSlot(s) and !(i > 0 and isDirSlot(&all[i - 1]) and sameDir(&all[i - 1], s));
            }
            if (!is_darwin and !is_windows) {
                if (r.options.parallel > 1) {
                    try r.concurrently(isDistinctDir, syncDirOne);
                } else {
                    for (all) |*s| if (isDistinctDir(s)) syncDirOne(r, s);
                }
                for (all) |*s| if (isDistinctDir(s)) try r.foldDir(s);
                return;
            }
            for (all) |*s| {
                if (!isDistinctDir(s)) continue;
                const reached = r.writeoutDir(s.handle) catch |err| return r.fail(s, err);
                if (reached == .none) {
                    try r.part(s, .ordered);
                    continue;
                }
                const v = r.volume(s.id.volume, s.device, s.handle, true, s.index) orelse {
                    try r.part(s, r.flushDir(s.handle, false) catch |err| return r.fail(s, err));
                    continue;
                };
                v.needs_flush = true;
            }
        }

        /// The first slot of a distinct directory, once `syncDirs` sorted them.
        fn isDistinctDir(s: *const Slot) bool {
            return s.distinct;
        }

        fn dirOrder(_: void, a: Slot, b: Slot) bool {
            const da = isDirSlot(&a);
            const db = isDirSlot(&b);
            if (da != db) return da;
            if (a.id.volume != b.id.volume) return a.id.volume < b.id.volume;
            if (a.device != b.device) return a.device < b.device;
            if (a.id.file != b.id.file) return a.id.file < b.id.file;
            return a.index < b.index;
        }

        fn sameDir(a: *const Slot, b: *const Slot) bool {
            return a.id.volume == b.id.volume and a.id.file == b.id.file and a.device == b.device;
        }

        /// Linux and the BSDs: one directory's sync, its outcome left in the
        /// slot.
        fn syncDirOne(r: *Self, s: *Slot) void {
            s.err = null;
            const outcome = platform.dirSync(r.io, r.options.blocking, s.handle, r.options.busy_deadline, null) catch |err| {
                s.err = err;
                return;
            };
            s.reached = outcome.reached;
            s.refused = outcome.refused;
        }

        /// Folds in one directory's sync: a refusal leaves the operation
        /// ordered.
        fn foldDir(r: *Self, s: *Slot) E!void {
            if (s.err) |err| return r.fail(s, err);
            if (s.refused) {
                if (fallback == .refuse) return r.fail(s, error.LevelUnavailable);
                r.reached = Reached.min(r.reached, .ordered);
                return;
            }
            try r.part(s, s.reached);
        }

        /// Darwin `fsync` (W) of a directory; Windows `NO_SYNC` on a handle
        /// reopened for it.
        fn writeoutDir(r: *Self, handle: sys.Handle) Error!Reached {
            if (!is_windows) return platform.writeout(r.io, r.options.blocking, handle, null);
            const flush = try platform.openDirFlush(r.io, handle, r.options.busy_deadline);
            defer sys.release(r.io, flush);
            return platform.writeout(r.io, r.options.blocking, flush, null);
        }

        /// One device flush through a directory: Darwin `F_FULLFSYNC`, Windows
        /// `NtFlushBuffersFile` on a handle reopened for it.
        fn flushDir(r: *Self, handle: sys.Handle, barrier_ok: bool) Error!Reached {
            if (is_windows) {
                const flush = try platform.openDirFlush(r.io, handle, r.options.busy_deadline);
                defer sys.release(r.io, flush);
                return platform.flushFull(r.io, r.options.blocking, flush, .sync_full, null);
            }
            if (barrier_ok) return platform.volumeBarrier(r.io, r.options.blocking, handle, r.options.barrier, null);
            return platform.volumeFlush(r.io, r.options.blocking, handle, null);
        }

        fn flushVolumes(r: *Self) E!void {
            if (!is_darwin and !is_windows) return;
            for (r.volumes[0..r.volume_count]) |v| {
                if (!v.needs_flush) continue;
                const slot = r.findSlot(v.slot);
                // Every pending on a volume was renamed by now, and its parent
                // stands for the volume.
                const handle = v.handle orelse unreachable; // unreachable: a volume without a handle holds only pendings, whose parents opened at their renames
                const reached = (if (v.is_dir)
                    r.flushDir(handle, false)
                else
                    platform.volumeFlush(r.io, r.options.blocking, handle, null)) catch |err| return r.fail(slot, err);
                try r.part(slot, reached);
            }
        }

        /// The slot added `index`-th, wherever the sort put it.
        fn findSlot(r: *Self, index: u32) *Slot {
            for (r.slots()) |*s| if (s.index == index) return s;
            unreachable; // unreachable: every index names a slot of this batch
        }
    };
}
