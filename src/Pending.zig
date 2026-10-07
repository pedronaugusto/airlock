//! A file being written under a temporary name in its destination's
//! directory, published by `commit` as a replace, a create or a keep.
//!
//! The temp is created exclusively next to the destination, never in a
//! system temp directory: a rename across filesystems is a copy, and tmp
//! cleaners remove what they do not know. Writes go to `file()` directly or
//! through `writer`. `commit` syncs the temp through the handle that wrote
//! it, publishes it, then syncs the directory that received the name.
//! `discard` removes the temp; it is idempotent and meant for `defer`.
const std = @import("std");
const Io = std.Io;
const Staged = @import("Staged.zig");

const Pending = @This();

/// Private: the temp and where it is in its publish. A `Batch` drives it
/// as well.
staged: Staged,

/// The name of the temp file in the destination's directory.
pub const Temp = Staged.Temp;
/// The permissions the temp gets: by default the destination's.
pub const Mode = Staged.Mode;
/// How `create` names, opens and sets up the temp.
pub const CreateOptions = Staged.CreateOptions;
/// What `create` can fail with.
pub const CreateError = Staged.CreateError;
/// Replace, create new, or keep an existing destination.
pub const Publish = Staged.Publish;
/// The level and publish mode of a `commit`.
pub const CommitOptions = Staged.CommitOptions;
/// What a `commit` reached, and whether it kept an existing file.
pub const Committed = Staged.Committed;
/// What `commit` can fail with.
pub const CommitError = Staged.CommitError;
/// What `commitOrRefuse` can fail with: `CommitError` and
/// `error.LevelUnavailable`.
pub const CommitOrRefuseError = Staged.CommitOrRefuseError;
/// Where a pending is in its publish.
pub const State = Staged.State;

/// Creates the temp for `dest_sub_path`, relative to `dir`. A nested
/// destination ("refs/heads/main") has its directory opened once here and
/// held, so the create, the rename and the directory sync all work relative
/// to one handle. `dest_sub_path` is borrowed until commit or discard.
pub fn create(io: Io, dir: Io.Dir, dest_sub_path: []const u8, options: CreateOptions) CreateError!Pending {
    return .{ .staged = try .create(io, dir, dest_sub_path, options) };
}

/// The temp file, to write to directly. Valid until `commit` or `discard`.
pub fn file(p: *const Pending) Io.File {
    return p.staged.file;
}

/// The error behind `error.PublishedNotDurable` or `error.Poisoned`.
pub fn cause(p: *const Pending) ?anyerror {
    return p.staged.cause;
}

/// Where the pending is in its publish.
pub fn state(p: *const Pending) State {
    return p.staged.state;
}

/// A buffered writer onto the temp. `commit` flushes it, so bytes still in
/// `buffer` are written before the sync. With `writeback_bytes`, writeback
/// starts every that many bytes. A failed write poisons the pending: what
/// reached the file is unknown, and `commit` returns the write's error. The
/// pending must not move while the writer is in use.
pub fn writer(p: *Pending, io: Io, buffer: []u8) *Io.Writer {
    return p.staged.writer(io, buffer);
}

/// Syncs the temp at `options.level`, publishes it, and syncs the
/// directory that received the name. A filesystem that refuses a call the
/// level needs gets the strongest call it accepts, and `reached` says what
/// that was.
///
/// A failed sync poisons the pending and removes the temp at once: its
/// contents are unknown and must never be renamed into place. Write the
/// bytes from your own copy into a new `Pending`. A rename that fails and
/// leaves the temp intact (`AccessDenied`, a deadline) leaves the pending
/// `synced`, and a second `commit` retries only the rename: the temp keeps
/// what its first sync reached, whatever level the second asks for. A
/// cancel before the rename returns `error.Canceled` with the state
/// unchanged; after it, `error.PublishedNotDurable` with `cause`
/// `Canceled`.
pub fn commit(p: *Pending, io: Io, options: CommitOptions) CommitError!Committed {
    return p.staged.commit(.report, io, options);
}

/// `commit`, but a filesystem that cannot keep `options.level` is
/// `error.LevelUnavailable` rather than a weaker `reached`. Darwin and
/// Windows decide everything before the rename, so nothing is published
/// and the pending stays as it was. Linux learns that a filesystem refuses
/// `fsync` on a directory only after it, and then returns
/// `PublishedNotDurable` with `cause` `LevelUnavailable` (ext4, xfs and
/// btrfs accept it). A retry after a failed rename is refused when the
/// first sync reached less than the level asked for now.
pub fn commitOrRefuse(p: *Pending, io: Io, options: CommitOptions) CommitOrRefuseError!Committed {
    return p.staged.commit(.refuse, io, options);
}

/// Idempotent; meant for `defer`. Before the publish it closes the temp and
/// removes its name; after, it closes whatever is still open and never
/// unlinks, so it cannot remove a name someone else now owns.
pub fn discard(p: *Pending, io: Io) void {
    p.staged.discard(io);
}

pub const WriteFileOptions = struct {
    create: CreateOptions = .{},
    commit: CommitOptions = .{},
};

pub const WriteFileError = CreateError || CommitError || Io.File.WritePositionalError;

/// `WriteFileError` and `error.LevelUnavailable`.
pub const WriteFileOrRefuseError = WriteFileError || CommitOrRefuseError;

/// Create, write and `commit`, for a whole buffer.
pub fn writeFile(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8, options: WriteFileOptions) WriteFileError!Committed {
    var p = try create(io, dir, sub_path, options.create);
    defer p.discard(io);
    try p.file().writePositionalAll(io, bytes, 0);
    return p.commit(io, options.commit);
}

/// Create, write and `commitOrRefuse`, for a whole buffer: a filesystem
/// that cannot keep the level is `error.LevelUnavailable`, and on Darwin
/// and Windows the destination is left as it was.
pub fn writeFileOrRefuse(io: Io, dir: Io.Dir, sub_path: []const u8, bytes: []const u8, options: WriteFileOptions) WriteFileOrRefuseError!Committed {
    var p = try create(io, dir, sub_path, options.create);
    defer p.discard(io);
    try p.file().writePositionalAll(io, bytes, 0);
    return p.commitOrRefuse(io, options.commit);
}
