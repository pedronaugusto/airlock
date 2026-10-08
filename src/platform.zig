//! What each operating system and filesystem guarantees, and the calls
//! airlock makes for each level. This file is the one source for the
//! durability tables in the READMEs of the packages that use airlock.
//!
//! Cost classes: W = writeout without flushing the device cache,
//! B = barrier, F = device cache flush.
//!
//! | Level | Linux | macOS / iOS | Windows | BSDs (not in CI) |
//! |---|---|---|---|---|
//! | `ordered`, file | `fdatasync` (F) → `.data` | `F_BARRIERFSYNC` (B) → `.ordered` | `NtFlushBuffersFileEx(DATA_SYNC_ONLY)` (F) → `.data` | `fsync` → `.full` (unverified) |
//! | `ordered`, directory | none | none | none | none |
//! | `data`, file | `fdatasync` → `.data` | `F_FULLFSYNC` → `.full` | `DATA_SYNC_ONLY` → `.data` (NTFS only) | `fsync` → `.full` (unverified) |
//! | `data`, directory | `fsync(dirfd)` → `.full` | `F_FULLFSYNC(dirfd)` → `.full` | reopen with `FILE_ADD_FILE`, `NtFlushBuffersFile` → `.full` | `fsync(dirfd)` (unverified) |
//! | `full`, file | `fsync` → `.full` | `F_FULLFSYNC` → `.full` | `NtFlushBuffersFile` → `.full` | `fsync` (unverified) |
//! | `full`, directory | as `data` | as `data` | as `data` | as `data` |
//!
//! What an operation reports is the minimum over its parts, after a later
//! device flush on the same device has upgraded the parts before it.
//! fcntl(2) for `F_FULLFSYNC`: "data that had been fsync'd on the same
//! device before is guaranteed to be persisted when this call returns". So a
//! Darwin `data` replace (B on the file, then F on the directory) reports
//! `.full`, and a Windows or Linux one `.data`.
//!
//! A replace (`Pending.commit`) costs, at `data`: Linux 2 F (`fdatasync`,
//! `fsync` of the directory); macOS 1 B + 1 F (`barrier = false`: 2 F);
//! Windows 2 F. At `ordered` it stops before the directory sync.
//!
//! Fallbacks happen only on a refusal, the codes that mean the filesystem
//! cannot be asked; any other error means the bytes did not get down and is
//! returned. A fallback is never weaker than it needs to be:
//!
//! | Call | Refusal codes | Falls back to | Reported |
//! |---|---|---|---|
//! | Darwin `F_FULLFSYNC` | `ENOTSUP`, `EOPNOTSUPP`, `EINVAL`, `ENOTTY`, `EPERM` (exFAT, SMB) | `fsync` | `.written` |
//! | Darwin `F_BARRIERFSYNC` | the same | `F_FULLFSYNC`, then `fsync` | `.full` or `.written` |
//! | Darwin, BSD `fsync` | `EINVAL`, `ENOTSUP` | nothing | `.none` |
//! | Linux `fdatasync` | `EINVAL`, `EROFS`, `ENOSYS` | `fsync` | `.full` |
//! | Linux `fsync` | `EINVAL`, `EROFS` | nothing | `.none` |
//! | Linux `fsync(dirfd)` | `EINVAL`, `EROFS`; `EBADF` on an `O_PATH` or `AT_FDCWD` handle reopens it instead | nothing | `.ordered` for the operation |
//! | Windows `DATA_SYNC_ONLY`, `NO_SYNC` | `INVALID_PARAMETER`, `NOT_SUPPORTED`, `INVALID_DEVICE_REQUEST` (FAT, exFAT, ReFS, redirectors) | `NtFlushBuffersFile` | `.full` |
//! | Windows directory flush | `NOT_SUPPORTED`, `INVALID_DEVICE_REQUEST` | nothing | `.ordered` for the operation |
//! | `renameat2(NOREPLACE)`, `renameatx_np(RENAME_EXCL)` | `EINVAL`, `ENOSYS`, `ENOTSUP` | `linkat` + `unlinkat` | unchanged |
//!
//! EINTR is retried after a cancel check for syncs, opens, renames and
//! stats; `close` is never retried. A call that refuses (`commitOrRefuse`,
//! `writeFileOrRefuse`, `Batch.commitOrRefuse`, `symLinkOrRefuse`) returns
//! `error.LevelUnavailable` for a result below the level asked for; a
//! fallback to a stronger call is not a refusal.
//!
//! Limits stated rather than tested: macOS and Windows have no block-level
//! crash replay, so their rows rest on the man pages and Microsoft's
//! documentation. What APFS does with `F_BARRIERFSYNC` on a third-party
//! drive without barrier support is not documented; `barrier = false`
//! closes that window. Raw syncs run inline unless the caller supplies
//! `options.blocking`, an executor hook for its runtime's sync lane.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Blocking = @import("Blocking.zig");
const sys = @import("sys.zig");
const level_mod = @import("level.zig");
const Level = level_mod.Level;
const Reached = level_mod.Reached;
const SyncOptions = level_mod.SyncOptions;

const native_os = builtin.target.os.tag;
const is_windows = native_os == .windows;
const is_linux = native_os == .linux;
const is_darwin = native_os.isDarwin();

pub const Os = enum { linux, darwin, windows, bsd };

/// The platform this build targets, as the table's columns name it.
pub const os: Os = if (is_linux) .linux else if (is_darwin) .darwin else if (is_windows) .windows else .bsd;

/// The file sync `level` asks for, through its fallback chain, without the
/// refuse check. `subject` names the file for the test seam.
pub fn syncChain(io: Io, blocking: ?Blocking, handle: sys.Handle, level: Level, barrier: bool, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (level == .none) return .none;
    return switch (os) {
        .linux => linuxChain(io, blocking, handle, level, subject),
        .darwin => darwinChain(io, blocking, handle, level, barrier, subject),
        .windows => windowsChain(io, blocking, handle, level, subject),
        .bsd => plain(io, blocking, handle, .sync_plain, subject, .full),
    };
}

fn linuxChain(io: Io, blocking: ?Blocking, fd: sys.Handle, level: Level, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (level != .full) {
        if (sys.dataFsync(io, blocking, fd, subject)) |_| return .data else |err| switch (err) {
            error.Refused => {},
            else => |e| return e,
        }
    }
    sys.linuxFsync(io, blocking, fd, .sync_full, subject) catch |err| return switch (err) {
        error.Refused => .none,
        error.BadHandle => error.Unexpected,
        else => |e| e,
    };
    return .full;
}

fn darwinChain(io: Io, blocking: ?Blocking, fd: sys.Handle, level: Level, barrier: bool, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (level == .ordered and barrier) {
        if (sys.barrierFsync(io, blocking, fd, subject)) |_| return .ordered else |err| switch (err) {
            error.Refused => {},
            else => |e| return e,
        }
    }
    return full(io, blocking, fd, .sync_full, subject);
}

/// Darwin `F_FULLFSYNC` as `call`, then `fsync` on a refusal.
fn full(io: Io, blocking: ?Blocking, fd: sys.Handle, call: sys.Call, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (sys.fullFsync(io, blocking, fd, call, subject)) |_| return .full else |err| switch (err) {
        error.Refused => {},
        else => |e| return e,
    }
    return plain(io, blocking, fd, .sync_plain, subject, .written);
}

/// Plain `fsync` as `call`, reaching `reached`; `.none` on a refusal.
fn plain(io: Io, blocking: ?Blocking, fd: sys.Handle, call: sys.Call, subject: ?[]const u8, reached: Reached) Io.File.SyncError!Reached {
    sys.plainFsync(io, blocking, fd, call, subject) catch |err| return switch (err) {
        error.Refused => .none,
        else => |e| e,
    };
    return reached;
}

fn windowsChain(io: Io, blocking: ?Blocking, handle: sys.Handle, level: Level, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (level != .full) {
        if (sys.flushExWindows(io, blocking, handle, .data_sync_only, subject)) |_| return .data else |err| switch (err) {
            error.Refused => {},
            else => |e| return e,
        }
    }
    return flushFull(io, blocking, handle, .sync_full, subject);
}

/// Windows `NtFlushBuffersFile` as `call`; `.none` on a refusal.
pub fn flushFull(io: Io, blocking: ?Blocking, handle: sys.Handle, call: sys.Call, subject: ?[]const u8) Io.File.SyncError!Reached {
    sys.flushWindows(io, blocking, handle, call, subject) catch |err| return switch (err) {
        error.Refused => .none,
        else => |e| e,
    };
    return .full;
}

/// A writeout without a device flush, for a batch: Darwin `fsync`, Windows
/// `NO_SYNC`. `.written`, or `.full` where Windows refused `NO_SYNC` and a
/// full flush stood in; `.none` if that was refused too.
pub fn writeout(io: Io, blocking: ?Blocking, handle: sys.Handle, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (is_windows) {
        if (sys.flushExWindows(io, blocking, handle, .no_sync, subject)) |_| return .written else |err| switch (err) {
            error.Refused => {},
            else => |e| return e,
        }
        return flushFull(io, blocking, handle, .sync_full, subject);
    }
    return plain(io, blocking, handle, .sync_writeout, subject, .written);
}

/// One device flush on the volume `handle` is on: Darwin `F_FULLFSYNC`,
/// Windows `NtFlushBuffersFile`.
pub fn volumeFlush(io: Io, blocking: ?Blocking, handle: sys.Handle, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (is_windows) return flushFull(io, blocking, handle, .sync_full, subject);
    return full(io, blocking, handle, .sync_full, subject);
}

/// One barrier on the volume `handle` is on: Darwin `F_BARRIERFSYNC`, or a
/// full flush where there is no barrier or it is refused. Returns
/// `.ordered`, `.full`, `.written` or `.none`.
pub fn volumeBarrier(io: Io, blocking: ?Blocking, handle: sys.Handle, barrier: bool, subject: ?[]const u8) Io.File.SyncError!Reached {
    if (is_darwin and barrier) {
        if (sys.barrierFsync(io, blocking, handle, subject)) |_| return .ordered else |err| switch (err) {
            error.Refused => {},
            else => |e| return e,
        }
    }
    return volumeFlush(io, blocking, handle, subject);
}

/// Syncs an open file at `options.level`, through the fallback chain, and
/// reports what was reached.
///
/// Says nothing about the file's name: a new file also needs its directory
/// synced. Any error means the file's dirty contents are unknown; a failed
/// sync is never retried or answered with a weaker call, since the kernel
/// may already have dropped the pages and cleared the error.
pub fn syncFile(io: Io, file: Io.File, options: SyncOptions) Io.File.SyncError!Reached {
    return syncChain(io, options.blocking, file.handle, options.level, options.barrier, null);
}

pub const DirSyncError = Io.File.SyncError || Io.Dir.OpenError;

/// What a directory sync came to: what it reached, and whether the
/// filesystem refused it (which leaves an operation `.ordered`).
pub const DirOutcome = struct { reached: Reached, refused: bool };

/// How long a Windows directory open retries a sharing violation.
pub const default_busy_deadline: Io.Duration = .fromMilliseconds(2000);

/// Syncs a directory's entries: the names created, renamed and removed in
/// it. Any `Dir`: an `O_PATH` handle (Linux), `cwd()` or a read-only handle
/// (Windows) is reopened for the sync. At `ordered` or `none` there is no
/// call and the answer is `.none`.
pub fn syncDir(io: Io, dir: Io.Dir, options: SyncOptions) DirSyncError!Reached {
    if (@backingInt(options.level) <= @backingInt(Level.ordered)) return .none;
    const outcome = try dirSync(io, options.blocking, dir.handle, default_busy_deadline, null);
    return outcome.reached;
}

/// The directory sync of `handle`, at `data` or `full` (they are one call).
pub fn dirSync(io: Io, blocking: ?Blocking, handle: sys.Handle, busy: Io.Duration, subject: ?[]const u8) DirSyncError!DirOutcome {
    if (is_windows) {
        const flush = try openDirFlush(io, handle, busy);
        defer sys.release(io, flush);
        return flushDir(io, blocking, flush, subject);
    }
    if (handle == sys.at_fdcwd) return reopened(io, blocking, handle, subject);
    if (is_linux) {
        sys.linuxFsync(io, blocking, handle, .sync_dir, subject) catch |err| switch (err) {
            error.Refused => return .{ .reached = .none, .refused = true },
            error.BadHandle => {
                if (try sys.isPathOnly(io, handle)) return reopened(io, blocking, handle, subject);
                return error.Unexpected;
            },
            else => |e| return e,
        };
        return .{ .reached = .full, .refused = false };
    }
    const reached = if (is_darwin) try full(io, blocking, handle, .sync_dir, subject) else try plain(io, blocking, handle, .sync_dir, subject, .full);
    return .{ .reached = reached, .refused = reached != .full };
}

/// `dirSync` of `"."` reopened relative to `handle`, once.
fn reopened(io: Io, blocking: ?Blocking, handle: sys.Handle, subject: ?[]const u8) DirSyncError!DirOutcome {
    const fresh = try sys.openDir(io, handle, ".");
    defer sys.release(io, fresh);
    if (fresh == sys.at_fdcwd) return error.Unexpected;
    return dirSync(io, blocking, fresh, default_busy_deadline, subject);
}

/// Windows: a handle on the directory `handle` with the rights a flush
/// needs, retrying a sharing violation until `busy` runs out. Opened
/// before a rename, so a refusal is known before anything is published.
pub fn openDirFlush(io: Io, handle: sys.Handle, busy: Io.Duration) Io.Dir.OpenError!sys.Handle {
    var backoff: Backoff = .start(io, busy);
    while (true) {
        return sys.openDirWindows(io, handle, "", true) catch |err| switch (err) {
            error.AccessDenied => if (try backoff.wait(io)) continue else return error.AccessDenied,
            else => |e| return e,
        };
    }
}

/// Windows: flush a handle `openDirFlush` returned.
pub fn flushDir(io: Io, blocking: ?Blocking, flush: sys.Handle, subject: ?[]const u8) Io.File.SyncError!DirOutcome {
    const reached = try flushFull(io, blocking, flush, .sync_dir, subject);
    return .{ .reached = reached, .refused = reached == .none };
}

/// Retries contention until a deadline: waits start at 1 ms and double,
/// capped at 100 ms, each scaled by a random factor in [0.5, 1.5). Sleeps
/// are `io.sleep`, so a cancel ends them and a test clock drives them.
pub const Backoff = struct {
    deadline: Io.Timestamp,
    next: Io.Duration,

    pub fn start(io: Io, limit: Io.Duration) Backoff {
        return .{ .deadline = Io.Timestamp.now(io, .awake).addDuration(limit), .next = .fromMilliseconds(1) };
    }

    /// Sleeps before the next try and returns true, or returns false once
    /// the deadline has passed.
    pub fn wait(b: *Backoff, io: Io) Io.Cancelable!bool {
        const now = Io.Timestamp.now(io, .awake);
        if (now.nanoseconds >= b.deadline.nanoseconds) return false;
        var bytes: [2]u8 = undefined;
        io.random(&bytes);
        const jitter = 500 + @as(i64, std.mem.readInt(u16, &bytes, .little) % 1000);
        const left = b.deadline.nanoseconds - now.nanoseconds;
        const nap = @min(@divTrunc(b.next.nanoseconds * jitter, 1000), left);
        try io.sleep(.fromNanoseconds(nap), .awake);
        b.next = .fromNanoseconds(@min(b.next.nanoseconds * 2, std.time.ns_per_ms * 100));
        return true;
    }
};

pub const SyncPathError = Io.File.SyncError || Io.File.OpenError;

/// Opens `sub_path` (for write on Windows, where a flush needs it;
/// read-only elsewhere) and syncs it.
///
/// Weaker than `syncFile` on the writing handle: a writeback error the
/// kernel already reported to another descriptor (Linux errseq) or dropped
/// (Darwin) is not seen here, so a lost write can come back as success.
/// Prefer the writing handle when you have it.
pub fn syncPath(io: Io, dir: Io.Dir, sub_path: []const u8, options: SyncOptions) SyncPathError!Reached {
    const handle = try sys.openFile(io, dir.handle, sub_path);
    defer sys.release(io, handle);
    return syncChain(io, options.blocking, handle, options.level, options.barrier, sub_path);
}
