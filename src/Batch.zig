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
//! | 3b. `keep_existing` found the name taken | the existing file is synced | W | W |
//! | 4. each distinct directory | `fsync`, `parallel` at once | W | W |
//! | 5. each volume | none | `F_FULLFSYNC` (F) | `NtFlushBuffersFile` (F) |
//!
//! At `ordered` a batch stops after the renames; at `none` it only renames.
//! Directories are told apart by their `FileId`, and volumes by their
//! device (on Windows, the serial and the NT device name: a serial alone
//! is not unique across cloned volumes). A false split costs one flush; a
//! false merge would skip one, so keys never merge two volumes.
//!
//! airlock never allocates: the slots are the caller's. A full batch
//! returns `error.BatchFull`; commit it and start the next one. The batch
//! holds at most one descriptor per slot plus `parallel`.
//!
//! Any failure poisons the batch: pending publishes not yet renamed are
//! discarded, renames already made are reported as
//! `error.PublishedNotDurable`, `failure` names the slot (in add order) and
//! its error, and `reset` is the only valid next call. A cancel before the
//! first rename publishes nothing; after it, it is `PublishedNotDurable`
//! with `cause` `Canceled`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");
const platform = @import("platform.zig");
const level_mod = @import("level.zig");
const Pending = @import("Pending.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const Fallback = level_mod.Fallback;

const Batch = @This();

const native_os = builtin.os.tag;
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
    /// Private: the pending, for a pending slot.
    pending: ?*Pending = null,
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
pub fn addPending(b: *Batch, io: Io, p: *Pending, publish: Pending.Publish) AddError!void {
    std.debug.assert(p.state == .open or p.state == .synced);
    try b.push(.{ .kind = .pending, .pending = p, .publish = publish });
    p.dropParent(io);
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
    fallback: Fallback = .report,
    /// Linux: how many syncs run at once; 1 = one after another.
    parallel: u8 = 16,
    /// Windows: how long to retry a rename a scanner is blocking.
    busy_deadline: Io.Duration = .fromMilliseconds(2000),
    /// As `SyncOptions.barrier`.
    barrier: bool = true,
};

pub const Error = Pending.CommitError || platform.SyncPathError || platform.DirSyncError || Io.File.StatError || error{BatchFull};

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
            if (p.state == .open or p.state == .synced or p.state == .poisoned) p.discard(io) else p.finishPublished(io);
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
/// above says, and reports what was reached. Empties the batch on success.
// ziglint-ignore: Z015 the set is a public merge; ziglint counts only error{} literals as types
pub fn commit(b: *Batch, io: Io, options: Options) Error!Reached {
    b.failed = null;
    var run: Run = .{ .batch = b, .options = options, .io = io };
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
    /// directory (Windows reopens one for the flush).
    handle: sys.Handle,
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

/// The state of one commit.
const Run = struct {
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

    fn slots(r: *Run) []Slot {
        return r.batch.slots[0..r.batch.len];
    }

    /// Records a failure at `s` (the first one wins) and returns `err`.
    fn fail(r: *Run, s: *const Slot, err: Error) Error {
        if (r.batch.failed == null) r.batch.failed = .{ .slot = s.index, .cause = err };
        if (s.pending) |p| if (p.state == .open) p.markFailed(r.io, err);
        return err;
    }

    /// Folds in what one part reached, refusing below the level if asked.
    fn part(r: *Run, s: *const Slot, reached: Reached) Error!void {
        if (r.options.fallback == .refuse and !reached.atLeast(r.options.level)) return r.fail(s, error.LevelUnavailable);
        r.reached = Reached.min(r.reached, reached);
    }

    fn go(r: *Run) Error!Reached {
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

    /// Opens each `addDirPath` directory and each distinct pending parent
    /// once. `cwd()` is reopened as `"."`, which a sync can use.
    fn openDirs(r: *Run) Error!void {
        const all = r.slots();
        for (all, 0..) |*s, i| switch (s.kind) {
            .dir_path => {
                s.handle = sys.openDir(r.io, s.root, s.path) catch |err| return r.fail(s, err);
                s.owned = true;
                s.open = true;
            },
            .dir => try r.ownCwd(s),
            .pending => {
                const p = s.pending.?;
                s.root = p.root.handle;
                s.path = p.parentSubPath() orelse "";
                if (findParent(all[0..i], s)) |shared| {
                    s.handle = shared;
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
            },
            else => {},
        };
    }

    /// A slot whose directory is `cwd()` gets its own handle on `"."`.
    fn ownCwd(r: *Run, s: *Slot) Error!void {
        if (is_windows or s.handle != sys.at_fdcwd) return;
        s.handle = sys.openDir(r.io, sys.at_fdcwd, ".") catch |err| return r.fail(s, err);
        s.owned = true;
        s.open = true;
    }

    /// The handle an earlier pending already holds on the same parent.
    fn findParent(earlier: []const Slot, s: *const Slot) ?sys.Handle {
        for (earlier) |e| {
            if (e.kind == .pending and e.root == s.root and std.mem.eql(u8, e.path, s.path)) return e.handle;
        }
        return null;
    }

    // -- step 1: files ----------------------------------------------------

    fn syncFiles(r: *Run) Error!void {
        if (is_linux and r.options.parallel > 1) return r.syncFilesConcurrently();
        for (r.slots()) |*s| switch (s.kind) {
            .file, .path, .pending => {
                syncOne(r, s);
                if (s.err) |err| return r.fail(s, err);
                try r.part(s, s.reached);
            },
            else => {},
        };
    }

    /// Linux: `parallel` syncs at once; the journal merges concurrent
    /// commits into a few. One after another where the `Io` has no
    /// concurrency.
    fn syncFilesConcurrently(r: *Run) Error!void {
        const all = r.slots();
        var start: usize = 0;
        while (start < all.len) {
            var group: Io.Group = .init;
            var started: usize = 0;
            var i = start;
            while (i < all.len and started < r.options.parallel) : (i += 1) {
                const s = &all[i];
                if (s.kind != .file and s.kind != .path and s.kind != .pending) continue;
                group.concurrent(r.io, syncOne, .{ r, s }) catch syncOne(r, s);
                started += 1;
            }
            group.await(r.io) catch |err| {
                group.cancel(r.io);
                return err;
            };
            start = i;
        }
        for (all) |*s| switch (s.kind) {
            .file, .path, .pending => {
                if (s.err) |err| return r.fail(s, err);
                try r.part(s, s.reached);
            },
            else => {},
        };
    }

    /// One file's step 1, its result left in the slot.
    fn syncOne(r: *Run, s: *Slot) void {
        s.err = null;
        if (s.pending) |p| p.prepare(r.io) catch |err| {
            s.err = err;
            return;
        };
        const handle = r.fileHandle(s) catch |err| {
            s.err = err;
            return;
        };
        s.reached = r.syncHandle(s, handle) catch |err| blk: {
            s.err = err;
            break :blk .none;
        };
        if (s.kind == .path and is_linux) {
            sys.release(r.io, handle);
            s.open = false;
            s.owned = false;
        }
    }

    /// The handle a file slot syncs through, opening a path slot.
    fn fileHandle(r: *Run, s: *Slot) Error!sys.Handle {
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
    /// a handle that stays open: the file's own, or a pending's parent.
    fn syncHandle(r: *Run, s: *Slot, handle: sys.Handle) Error!Reached {
        const subject = if (s.pending) |p| p.tempName() else s.path;
        if (!is_darwin and !is_windows) return platform.syncChain(r.io, handle, r.options.level, true, subject);
        const reached = try platform.writeout(r.io, handle, subject);
        if (reached != .written) return reached;
        const id = try sys.statId(r.io, handle);
        const device = if (is_windows) try sys.volumeName(r.io, handle) else 0;
        const rep = if (s.kind == .pending) s.handle else handle;
        const v = r.volume(id.volume, device, rep, s.kind == .pending, s.index) orelse
            return platform.volumeFlush(r.io, handle, subject);
        v.needs_flush = true;
        if (s.kind == .pending and s.pending.?.state == .open and v.temp == null) {
            v.temp = handle;
            v.temp_name = subject;
        }
        return .full;
    }

    /// The volume with this key, added with `handle` if new; null once the
    /// table is full (the caller then flushes at its own handle).
    fn volume(r: *Run, key: u64, device: u64, handle: sys.Handle, is_dir: bool, slot: u32) ?*Volume {
        for (r.volumes[0..r.volume_count]) |*v| {
            if (v.volume == key and v.device == device) {
                if (is_dir and !v.is_dir) {
                    v.handle = handle;
                    v.is_dir = true;
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

    // -- step 2: one barrier per volume -----------------------------------

    fn barrier(r: *Run) Error!void {
        if (!is_darwin and !is_windows) return;
        for (r.volumes[0..r.volume_count]) |v| {
            const temp = v.temp orelse continue;
            const slot = &r.batch.slots[v.slot];
            const reached = (if (is_windows)
                platform.volumeFlush(r.io, temp, v.temp_name)
            else
                platform.volumeBarrier(r.io, temp, r.options.barrier, v.temp_name)) catch |err| return r.fail(slot, err);
            // A barrier or a flush keeps the order; a refused one leaves
            // only what the fallback reached.
            if (!reached.atLeast(.ordered)) try r.part(slot, reached);
        }
    }

    /// POSIX: each temp closed once, its error a failed sync.
    fn closeTemps(r: *Run) Error!void {
        for (r.slots()) |*s| {
            const p = s.pending orelse continue;
            if (p.state != .open) continue;
            p.markSynced(r.io, r.options.level, s.reached) catch |err| return r.fail(s, err);
        }
    }

    // -- step 3: renames --------------------------------------------------

    fn publish(r: *Run) Error!void {
        var segment: usize = 0;
        const all = r.slots();
        for (all, 0..) |*s, i| switch (s.kind) {
            .pending => {
                r.io.checkCancel() catch |err| return r.fail(s, err);
                const p = s.pending.?;
                const renamed = p.renameSynced(r.io, s.publish, r.options.busy_deadline) catch |err| return r.fail(s, err);
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
    /// been written by someone who never synced it; a batch that reports
    /// `.data` must not hold such a file.
    fn syncKept(r: *Run, s: *Slot) Error!void {
        const p = s.pending.?;
        const handle = sys.openFile(r.io, s.handle, p.baseName()) catch |err| return r.fail(s, err);
        defer sys.release(r.io, handle);
        const reached = r.syncHandle(s, handle) catch |err| return r.fail(s, err);
        try r.part(s, reached);
    }

    /// A fence: every directory renamed into since the last fence is synced
    /// (Darwin and Windows: written out, then one barrier or flush on the
    /// last), so the renames after it reach the disk after these.
    fn fenceDirs(r: *Run, segment: []Slot, at: *const Slot) Error!void {
        var last: ?*Slot = null;
        for (segment, 0..) |*s, i| {
            if (s.kind != .pending or !s.touched) continue;
            if (seenHandle(segment[0..i], s.handle)) continue;
            last = s;
            if (is_darwin or is_windows) {
                const reached = r.writeoutDir(s.handle) catch |err| return r.fail(s, err);
                if (reached == .none) try r.part(s, .ordered);
            } else {
                try r.syncDirSlot(s);
            }
        }
        const s = last orelse return;
        if (!is_darwin and !is_windows) return;
        const reached = r.flushDir(s.handle, true) catch |err| return r.fail(at, err);
        if (!reached.atLeast(.ordered)) try r.part(s, reached);
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

    fn syncDirs(r: *Run) Error!void {
        const all = r.slots();
        for (all) |*s| if (isDirSlot(s)) {
            const id = sys.statId(r.io, s.handle) catch |err| return r.fail(s, err);
            s.id = id;
            s.device = if (is_windows) sys.volumeName(r.io, s.handle) catch |err| return r.fail(s, err) else 0;
        };
        // The rename order is spent: sort by directory key, in place.
        std.sort.pdq(Slot, all, {}, dirOrder);
        for (all, 0..) |*s, i| {
            if (!isDirSlot(s)) continue;
            if (i > 0 and isDirSlot(&all[i - 1]) and sameDir(&all[i - 1], s)) continue;
            if (is_darwin or is_windows) {
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
            } else {
                try r.syncDirSlot(s);
            }
        }
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

    /// Linux and the BSDs: one directory's sync; a refusal leaves the
    /// operation ordered.
    fn syncDirSlot(r: *Run, s: *Slot) Error!void {
        const outcome = platform.dirSync(r.io, s.handle, r.options.busy_deadline, null) catch |err| return r.fail(s, err);
        if (outcome.refused) {
            if (r.options.fallback == .refuse) return r.fail(s, error.LevelUnavailable);
            r.reached = Reached.min(r.reached, .ordered);
            return;
        }
        try r.part(s, outcome.reached);
    }

    /// Darwin `fsync` (W) of a directory; Windows `NO_SYNC` on a handle
    /// reopened for it.
    fn writeoutDir(r: *Run, handle: sys.Handle) Error!Reached {
        if (!is_windows) return platform.writeout(r.io, handle, null);
        const flush = try platform.openDirFlush(r.io, handle, r.options.busy_deadline);
        defer sys.release(r.io, flush);
        return platform.writeout(r.io, flush, null);
    }

    /// One device flush through a directory: Darwin `F_FULLFSYNC`, Windows
    /// `NtFlushBuffersFile` on a handle reopened for it.
    fn flushDir(r: *Run, handle: sys.Handle, barrier_ok: bool) Error!Reached {
        if (is_windows) {
            const flush = try platform.openDirFlush(r.io, handle, r.options.busy_deadline);
            defer sys.release(r.io, flush);
            return platform.flushFull(r.io, flush, .sync_full, null);
        }
        if (barrier_ok) return platform.volumeBarrier(r.io, handle, r.options.barrier, null);
        return platform.volumeFlush(r.io, handle, null);
    }

    fn flushVolumes(r: *Run) Error!void {
        if (!is_darwin and !is_windows) return;
        for (r.volumes[0..r.volume_count]) |v| {
            if (!v.needs_flush) continue;
            const slot = r.findSlot(v.slot);
            const reached = (if (v.is_dir)
                r.flushDir(v.handle, false)
            else
                platform.volumeFlush(r.io, v.handle, null)) catch |err| return r.fail(slot, err);
            try r.part(slot, reached);
        }
    }

    /// The slot added `index`-th, wherever the sort put it.
    fn findSlot(r: *Run, index: u32) *Slot {
        for (r.slots()) |*s| if (s.index == index) return s;
        unreachable; // unreachable: every index names a slot of this batch
    }
};
