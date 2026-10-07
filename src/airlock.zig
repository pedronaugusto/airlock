//! Durable files: sync a file or a directory at a chosen level and learn
//! what was reached, publish a file atomically, put many files under one
//! barrier, and tell files apart by identity.
//!
//! Every call that may block takes `io: Io` first and never stores it;
//! nothing allocates; buffers and slot storage belong to the caller.

const level = @import("level.zig");
const platform = @import("platform.zig");
const names = @import("names.zig");
const sys_impl = @import("sys.zig");

/// What a caller asks a call to make durable.
pub const Level = level.Level;
/// What a call reached, weakest first.
pub const Reached = level.Reached;
/// Degrade and report, or refuse, when a filesystem refuses a level.
pub const Fallback = level.Fallback;
/// The level, the fallback and the Darwin barrier choice of one sync.
pub const SyncOptions = level.SyncOptions;

/// `std.Io.File.SyncError` plus `error.LevelUnavailable`.
pub const SyncError = platform.SyncError;
/// Syncs an open file at a level and reports what was reached.
pub const syncFile = platform.syncFile;
/// `SyncError` plus the errors of reopening a directory for its sync.
pub const DirSyncError = platform.DirSyncError;
/// Syncs a directory's entries: the names created, renamed and removed in it.
pub const syncDir = platform.syncDir;
/// `SyncError` plus the errors of opening the file.
pub const SyncPathError = platform.SyncPathError;
/// Opens a file by path and syncs it; weaker than `syncFile` on the writing handle.
pub const syncPath = platform.syncPath;

/// A file written under a temp name and published by `commit`.
pub const Pending = @import("Pending.zig");
/// The temp name of a `Pending`: random with a prefix, or exact.
pub const Temp = Pending.Temp;
/// The permissions a `Pending` gets.
pub const Mode = Pending.Mode;
/// How `create` names, opens and sets up the temp.
pub const CreateOptions = Pending.CreateOptions;
/// What `create` can fail with.
pub const CreateError = Pending.CreateError;
/// Creates the temp for a destination, in the destination's directory.
pub const create = Pending.create;
/// `create`, a write of a whole buffer and `commit`, as one call.
pub const writeFile = Pending.writeFile;
/// The create and commit options of `writeFile`.
pub const WriteFileOptions = Pending.WriteFileOptions;
/// What `writeFile` can fail with.
pub const WriteFileError = Pending.WriteFileError;

/// The directory syncs and the Windows retry of `rename` and `remove`.
pub const RenameOptions = names.RenameOptions;
/// What `rename` can fail with.
pub const RenameError = names.RenameError;
/// Renames, replacing, and syncs the directories involved.
pub const rename = names.rename;
/// What `remove` can fail with.
pub const RemoveError = names.RemoveError;
/// Removes a file and syncs its directory.
pub const remove = names.remove;

/// Many files, publishes and directories under the fewest barriers.
pub const Batch = @import("Batch.zig");

/// Which file a handle or path is, by volume and file number.
pub const FileId = @import("FileId.zig");

/// The test seam: every raw call airlock makes can be decided by a hook
/// carried in the `Io`. A test builds that `Io` as a layer whose state is
/// a `HookedState` and whose `fileSync` is `hookedSync`.
pub const sys = struct {
    /// Every raw call airlock makes.
    pub const Call = sys_impl.Call;
    /// An errno on POSIX, an NTSTATUS on Windows.
    pub const Code = sys_impl.Code;
    /// What a hook makes of a call instead.
    pub const Result = sys_impl.Result;
    /// The hook: a context, its decision function and the base `Io`.
    pub const Hook = sys_impl.Hook;
    /// The hooked layer's state.
    pub const HookedState = sys_impl.HookedState;
    /// The hooked layer's `fileSync`, by which a raw call finds the hook.
    pub const hookedSync = sys_impl.hookedSync;
};

test {
    _ = level;
    _ = platform;
    _ = names;
    _ = Pending;
    _ = Batch;
    _ = FileId;
}
