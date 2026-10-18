//! What volume a directory is on, as the platform describes it: whether it
//! is another machine's, and its file system's type name. What a program
//! asks before it puts something there that not every volume holds, such
//! as a Unix socket.
//!
//! A raw call like airlock's others: a test's seam decides it, and over a
//! simulation the volume is local and has no name.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");

const Volume = @This();

/// Mounted from another machine. Darwin and the BSDs: the volume is not
/// `MNT_LOCAL`. Linux, by the file system's magic number: NFS, SMB and
/// CIFS, AFS, Coda, and FUSE, whose server may be anywhere. Windows: a
/// remote device.
remote: bool,
name_bytes: [32]u8,
name_len: u8,

pub const Error = sys.VolumeError;

/// The volume `dir` is on.
pub fn of(io: Io, dir: Io.Dir) Error!Volume {
    const info = try sys.volumeOf(io, dir.handle);
    return .{ .remote = info.remote, .name_bytes = info.name, .name_len = info.name_len };
}

/// The file system's type name, as the platform names it: Darwin's
/// `f_fstypename` (`apfs`, `smbfs`, `msdos`), the type Linux's mount table
/// gives the mount (`ext4`, `nfs4`, `vfat`; for a network file system
/// whose mount is not listed, its kind), Windows' file system name
/// (`NTFS`, `FAT32`). Empty where nothing names it.
pub fn name(v: *const Volume) []const u8 {
    return v.name_bytes[0..v.name_len];
}

test "the volume a temporary directory is on is local and named" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const v = try of(io, tmp.dir);
    try std.testing.expect(!v.remote);
    try std.testing.expect(v.name().len != 0);
}

test "a volume query is a raw call a seam decides" {
    const io = std.testing.io;
    const testing = @import("airlock.testing");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try testing.Seam.create(std.testing.allocator, io, .{
        .plan = &.{testing.fail(.statfs, 1, if (builtin.target.os.tag == .windows) .ACCESS_DENIED else .ACCES)},
    });
    defer s.destroy();
    try std.testing.expectError(error.AccessDenied, of(s.io(), tmp.dir));
    _ = try of(s.io(), tmp.dir);
}
