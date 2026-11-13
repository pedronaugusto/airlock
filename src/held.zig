//! The handles airlock holds, each with one owner: a file or a directory
//! airlock opened, which an aegis owner releases once, or the caller's
//! directory, lent, which airlock never releases.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const sys = @import("sys.zig");
const paths = @import("paths.zig");

/// A file airlock opened: released once, by `deinit(io)`. A failure its
/// close must report is taken out first (`take`) and closed by hand.
pub const File = aegis.own.OwnedIo(Io.File, releaseFile);

/// A directory airlock opened: released once, by `deinit(io)`.
pub const Dir = aegis.own.OwnedIo(Io.Dir, releaseDir);

fn releaseFile(f: *Io.File, io: Io) void {
    sys.release(io, f.handle);
}

fn releaseDir(d: *Io.Dir, io: Io) void {
    sys.release(io, d.handle);
}

/// The directory a name is in: one airlock opened and closes, the caller's
/// (or a batch's) lent to it, or none once it was let go. Its owner binds
/// where it is first used: one used and then returned by value goes
/// through `move`.
pub const Parent = union(enum) {
    owned: Dir,
    lent: aegis.own.Unowned(Io.Dir),
    closed,

    /// The directory that holds `sub_path`: `root` itself, lent, or the
    /// directory it names, opened.
    pub fn open(io: Io, root: Io.Dir, sub_path: []const u8) sys.OpenDirError!Parent {
        const base_start = paths.baseStart(sub_path);
        if (base_start == 0) return .{ .lent = .of(root) };
        return .{ .owned = .init(.{ .handle = try sys.openDir(io, root.handle, paths.parentPath(sub_path, base_start)) }) };
    }

    /// The directory, lent to the caller; null once it was let go.
    pub fn get(p: *Parent) ?Io.Dir {
        return switch (p.*) {
            .owned => |*d| d.borrow().*,
            .lent => |d| d.get(),
            .closed => null,
        };
    }

    /// The directory, which is still held.
    pub fn dir(p: *Parent) Io.Dir {
        return switch (p.*) {
            .owned => |*d| d.borrow().*,
            .lent => |d| d.get(),
            .closed => aegis.assert.never("held.Parent.dir: the directory was let go"),
        };
    }

    /// Closes a directory airlock opened, and lets a lent one go.
    /// Idempotent.
    pub fn close(p: *Parent, io: Io) void {
        switch (p.*) {
            .owned => |*d| d.deinit(io),
            .lent, .closed => {},
        }
        p.* = .closed;
    }

    /// The parent at its new address: an opened directory's owner moves,
    /// and binds again where it is next used.
    pub fn move(p: *Parent) Parent {
        return switch (p.*) {
            .owned => |*d| .{ .owned = d.move() },
            .lent => |d| .{ .lent = d },
            .closed => .closed,
        };
    }
};
