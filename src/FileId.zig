//! Which file a handle or a path is, as the filesystem numbers it and not as
//! a path spells it.
//!
//! On POSIX a file is its device and its inode; on Windows its volume's
//! serial number and its 128-bit file id. Both are read from the handle, so
//! nothing is allocated and no path is resolved. A directory is a file here
//! like any other.
//!
//! Two files that exist at once have different ids, with one exception:
//! on Windows, two volumes cloned from one image (VHDs, VM images, restored
//! partitions) keep the serial number and the file ids both, so a file on
//! one can share an id with a file on the other. Ids are not stable across
//! a remount (NFS and FUSE device numbers change, and overlayfs without
//! `xino` changes inodes at copy-up), and a number can be reused once its
//! file is gone.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

const FileId = @This();

/// The device on POSIX (Linux: `major << 32 | minor`); the volume's serial
/// number on Windows.
volume: u64,
/// The inode on POSIX; the file id on Windows, which is 128 bits on ReFS.
file: u128,

pub const Error = Io.File.StatError;

/// The identity of what `file` is open on.
pub fn of(io: Io, file: Io.File) Error!FileId {
    const id = try sys.statId(io, file.handle);
    return .{ .volume = id.volume.raw(), .file = id.file };
}

pub const PathOptions = struct {
    /// Follow a symbolic link, as opening it would.
    follow_symlinks: bool = true,
};

pub const PathError = Io.Dir.StatFileError;

/// The identity of what `sub_path` names relative to `dir` (which an
/// absolute `sub_path` ignores). On POSIX this reads the path without
/// opening it, so a socket has one too; on Windows the file is opened for
/// its attributes only.
pub fn ofPath(io: Io, dir: Io.Dir, sub_path: []const u8, options: PathOptions) PathError!FileId {
    const id = try sys.statIdPath(io, dir.handle, sub_path, options.follow_symlinks);
    return .{ .volume = id.volume.raw(), .file = id.file };
}

pub fn eql(a: FileId, b: FileId) bool {
    return a.volume == b.volume and a.file == b.file;
}

/// A total order: by volume, then by file.
pub fn order(a: FileId, b: FileId) std.math.Order {
    const by_volume = std.math.order(a.volume, b.volume);
    if (by_volume != .eq) return by_volume;
    return std.math.order(a.file, b.file);
}

pub fn hash(id: FileId) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    std.hash.autoHash(&hasher, id.volume);
    std.hash.autoHash(&hasher, id.file);
    return hasher.final();
}

test "order is by volume, then by file, and agrees with eql" {
    const a: FileId = .{ .volume = 1, .file = 9 };
    const b: FileId = .{ .volume = 2, .file = 1 };
    const c: FileId = .{ .volume = 2, .file = 3 };
    try std.testing.expectEqual(std.math.Order.lt, order(a, b));
    try std.testing.expectEqual(std.math.Order.lt, order(b, c));
    try std.testing.expectEqual(std.math.Order.eq, order(c, c));
    try std.testing.expect(eql(c, c) and !eql(b, c));
    try std.testing.expectEqual(hash(c), hash(.{ .volume = 2, .file = 3 }));
}

test "a volume number and a device hash are different types, and a file id is read from either" {
    comptime std.debug.assert(sys.VolumeId != sys.DeviceId);
    const id: sys.Id = .{ .volume = .fromRaw(7), .file = 9 };
    try std.testing.expectEqual(@as(u64, 7), id.volume.raw());
}

test "a Linux device number keeps its major and its minor apart" {
    try std.testing.expect(sys.linuxVolume(1, 2) != sys.linuxVolume(2, 1));
    try std.testing.expect(sys.linuxVolume(1, 1) != sys.linuxVolume(1, 2));
}
