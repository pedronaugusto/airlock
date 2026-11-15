//! Where a call puts what its result hides: the error of a sync after a
//! name changed, and a name airlock made and could not remove. Below
//! `Staged` and `names`, which both tell it.
const platform = @import("platform.zig");
const sys = @import("sys.zig");

/// The errors behind `error.PublishedNotDurable`: the name changed, and the
/// sync that would make the change durable failed.
pub const SyncAfterError = platform.DirSyncError || sys.StatIdError;

/// Where a call puts what its result hides: the error behind
/// `error.PublishedNotDurable`, and a name airlock made and could not remove.
pub const Diagnostics = struct {
    /// The error of the sync after the name changed.
    cause: ?SyncAfterError = null,
    /// Why a name airlock made is still there, the first such removal that
    /// failed: a symbolic link's temp, left by a `symLink` that failed after
    /// making it; a pending's temp, left by a create, a sync or a write that
    /// failed, or by `discard`, and the temp a no-replace publish by hard
    /// link leaves as a second name for the file it published; a clone a
    /// copy made beside its temp; a lock's holder file. A random temp is
    /// `pruneTemps`'s to remove. An exact one is the caller's: a lock file
    /// left behind holds the lock.
    left: ?LeftError = null,
};

/// What a removal of a name airlock made can fail with.
pub const LeftError = sys.UnlinkError;

/// Records in `diagnostics`, where the caller gave one, that a name airlock
/// made is still there and why: the first such failure is kept.
pub fn noteLeft(diagnostics: ?*Diagnostics, err: LeftError) void {
    const d = diagnostics orelse return;
    if (d.left == null) d.left = err;
}
