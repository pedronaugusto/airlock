//! Durable files: sync a file or a directory at a chosen level and learn
//! what was reached, publish a file or a symbolic link atomically, create
//! directories durably, put many files under one barrier, remove the temps
//! a crash left, and tell files apart by identity.
//!
//! Every call that may block takes `io: Io` first and never stores it;
//! nothing allocates; buffers and slot storage belong to the caller.

const level = @import("level.zig");
const platform = @import("platform.zig");
const names = @import("names.zig");

/// What a caller asks a call to make durable.
pub const Level = level.Level;
/// What a call reached, weakest first.
pub const Reached = level.Reached;
/// The level and the Darwin barrier choice of one sync.
pub const SyncOptions = level.SyncOptions;

/// Syncs an open file at a level and reports what was reached.
pub const syncFile = platform.syncFile;
/// `std.Io.File.SyncError` plus the errors of reopening a directory for
/// its sync.
pub const DirSyncError = platform.DirSyncError;
/// Syncs a directory's entries: the names created, renamed and removed in it.
pub const syncDir = platform.syncDir;
/// `std.Io.File.SyncError` plus the errors of opening the file.
pub const SyncPathError = platform.SyncPathError;
/// Opens a file by path and syncs it; weaker than `syncFile` on the writing handle.
pub const syncPath = platform.syncPath;

/// A file written under a temp name and published by `commit`.
pub const Pending = @import("Pending.zig");
/// The temp name of a `Pending`: random with a prefix, or exact.
pub const Temp = Pending.Temp;
/// The permissions a `Pending` gets: by default the destination's.
pub const Mode = Pending.Mode;
/// How `create` names, opens and sets up the temp.
pub const CreateOptions = Pending.CreateOptions;
/// What `create` can fail with.
pub const CreateError = Pending.CreateError;
/// Creates the temp for a destination, in the destination's directory.
pub const create = Pending.create;
/// `create`, a write of a whole buffer and `commit`, as one call.
pub const writeFile = Pending.writeFile;
/// `writeFile` that refuses a level the filesystem cannot keep.
pub const writeFileOrRefuse = Pending.writeFileOrRefuse;
/// The create and commit options of `writeFile`.
pub const WriteFileOptions = Pending.WriteFileOptions;
/// What `writeFile` can fail with.
pub const WriteFileError = Pending.WriteFileError;
/// What `writeFileOrRefuse` can fail with.
pub const WriteFileOrRefuseError = Pending.WriteFileOrRefuseError;

/// Where a call puts the error behind `error.PublishedNotDurable`.
pub const Diagnostics = names.Diagnostics;
/// The errors a sync after a name changed can fail with.
pub const SyncAfterError = names.SyncAfterError;
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
/// The syncs of `makePath`.
pub const MakePathOptions = names.MakePathOptions;
/// What `makePath` can fail with.
pub const MakePathError = names.MakePathError;
/// What `makePath` created and reached.
pub const Made = names.Made;
/// Creates the missing directories of a path and syncs each new entry.
pub const makePath = names.makePath;
/// The syncs and the temp prefix of `symLink`.
pub const SymLinkOptions = names.SymLinkOptions;
/// What `symLink` can fail with.
pub const SymLinkError = names.SymLinkError;
/// What `symLinkOrRefuse` can fail with.
pub const SymLinkOrRefuseError = names.SymLinkOrRefuseError;
/// Points a name at a target atomically: a temp link renamed over it.
pub const symLink = names.symLink;
/// `symLink` that refuses a level the filesystem cannot keep.
pub const symLinkOrRefuse = names.symLinkOrRefuse;
/// How old a leftover temp must be for `pruneTemps`.
pub const PruneOptions = names.PruneOptions;
/// What `pruneTemps` can fail with.
pub const PruneError = names.PruneError;
/// Removes the random temps a crash left behind, by prefix and age.
pub const pruneTemps = names.pruneTemps;

/// Many files, publishes and directories under the fewest barriers.
pub const Batch = @import("Batch.zig");

/// Which file a handle or path is, by volume and file number.
pub const FileId = @import("FileId.zig");

test {
    _ = level;
    _ = platform;
    _ = names;
    _ = Pending;
    _ = Batch;
    _ = FileId;
}
