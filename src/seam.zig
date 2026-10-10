//! The seam in front of every raw call airlock makes: what a call is, what
//! a test makes of it instead, where a call it lets through is made (the
//! system, or a simulated file system behind an `Io`), and how a raw call
//! finds the test's hook in the `Io` it was given.
//!
//! A module of its own, imported by airlock and by `airlock.testing` and
//! exported by neither: production airlock asks only whether an `Io`
//! carries a hook, and the test module is the one place that builds one.
//! The `Io` carries it as a layer whose `fileSync` is `hookedSync` and
//! whose state is a `HookedState`. A layered vtable is a copy per layer
//! type, so a raw call compares the slot, never the vtable's address.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Every raw call airlock makes, one value each. A test plan names these.
pub const Call = enum(u8) {
    /// Exclusive create of a temp file or lock in the destination's directory.
    create_temp,
    /// Permissions set on the open temp (`fchmod`; the read-only attribute on Windows).
    set_mode,
    /// Linux `sync_file_range(WRITE)` from `Pending.writer`.
    writeback,
    /// `close` of a handle airlock opened. Never retried.
    close,
    /// The platform's full sync: Linux `fsync`, Darwin `F_FULLFSYNC`, Windows `NtFlushBuffersFile`.
    sync_full,
    /// Darwin `F_BARRIERFSYNC`.
    sync_barrier,
    /// A data-only durable sync: Linux `fdatasync`, Windows
    /// `NtFlushBuffersFileEx(DATA_SYNC_ONLY)`.
    sync_data,
    /// Plain `fsync` where it is the end of a fallback chain (Darwin, BSD).
    sync_plain,
    /// A writeout without a device flush, before one flush per volume:
    /// Darwin `fsync`, Windows `NtFlushBuffersFileEx(NO_SYNC)`.
    sync_writeout,
    /// A directory opened so it can be synced and named relative to.
    open_dir,
    /// A file opened by name: an existing file a batch syncs, or a rename or delete source on Windows.
    open_file,
    /// A directory's own sync.
    sync_dir,
    /// A rename that replaces.
    rename,
    /// A rename that never replaces: `renameat2(NOREPLACE)`, `renameatx_np(RENAME_EXCL)`.
    rename_noreplace,
    /// `linkat`, the no-replace fallback.
    link,
    /// `unlinkat`.
    unlink,
    /// Windows delete by handle with POSIX semantics.
    dispose,
    /// A file's identity (`statx`, `fstat`, `fstatat`, `FileIdInformation`).
    stat_id,
    /// Windows: the volume's NT device name, hashed.
    volume_name,
    /// Windows rename by handle (`FileRenameInformationEx`).
    win_rename_ex,
    /// Linux `fcntl(F_GETFL)`: is a directory handle `O_PATH`?
    getfl,
    /// A new directory: `mkdirat`; on Windows a directory created by name.
    make_dir,
    /// A new symbolic link: `symlinkat`.
    symlink,
};

/// An errno on POSIX, an NTSTATUS on Windows.
pub const Code = if (builtin.target.os.tag == .windows) std.os.windows.NTSTATUS else std.posix.E;

/// What a hook makes of a call instead of the system.
pub const Result = union(enum) {
    /// The call returns this failure code without being made. A success
    /// code runs the real call.
    code: Code,
    /// The call is interrupted and a cancel is pending: `error.Canceled`.
    canceled,
    /// The call succeeds with this value without being made. Only
    /// `volume_name` reads one; any other call runs for real.
    value: u64,
};

/// How strong a sync is, as a simulated disk models it: a writeout hands
/// the data to the device, a barrier orders what was handed before it, a
/// data or full sync makes it durable (the data alone, or with metadata).
pub const Flush = enum { writeout, barrier, data, full };

/// A file system behind an `Io`, a simulated one, where the calls a hook
/// lets through are made instead of on the system: every open, create,
/// rename, link, remove, stat and close through `io`, every sync through
/// `flush`. Each call is still decided by the hook first, one for one with
/// the raw call it stands for.
pub const Route = struct {
    io: Io,
    ctx: *anyopaque,
    /// A sync of `handle`, a file or a directory, at `kind`: the code the
    /// platform's call would return.
    flush: *const fn (ctx: *anyopaque, handle: Io.File.Handle, kind: Flush) Code,
};

/// Routes airlock's raw calls to a test. `base` is the `Io` a std-level
/// `fileSync` through the hooked layer goes to.
pub const Hook = struct {
    ctx: *anyopaque,
    /// Returns what the call does instead, or null to make the call.
    call: *const fn (ctx: *anyopaque, call: Call, path: ?[]const u8) ?Result,
    base: Io,
    /// Where a call the hook lets through is made: on the system when
    /// null, through the route otherwise.
    route: ?Route = null,
};

/// The state of the layer that carries a hook.
pub const HookedState = struct { hook: *const Hook };

/// The hooked layer's `fileSync`: a std-level sync passes through to the
/// hook's base.
pub fn hookedSync(userdata: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
    const state: *HookedState = @ptrCast(@alignCast(userdata.?)); // safe: an Io whose fileSync is hookedSync carries a HookedState as userdata
    return file.sync(state.hook.base);
}

/// The hook `io` carries, if it carries one: one compare.
pub fn hookOf(io: Io) ?*const Hook {
    if (io.vtable.fileSync != &hookedSync) return null;
    const state: *const HookedState = @ptrCast(@alignCast(io.userdata.?)); // safe: an Io whose fileSync is hookedSync carries a HookedState as userdata
    return state.hook;
}
