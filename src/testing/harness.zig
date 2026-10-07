//! airlock's own test fixtures, beside the seam its tests run on
//! (`airlock.testing`): a scratch directory, and the calls a test expects.
const std = @import("std");
const Io = std.Io;
const seam = @import("airlock.testing");

/// A scratch directory for one test, removed by `cleanup`.
pub const Scratch = struct {
    tmp: std.testing.TmpDir,

    pub fn init() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{ .iterate = true }) };
    }

    pub fn dir(s: *Scratch) Io.Dir {
        return s.tmp.dir;
    }

    pub fn cleanup(s: *Scratch) void {
        s.tmp.cleanup();
    }

    /// The contents of `name`, or null if it does not exist.
    pub fn read(s: *Scratch, name: []const u8, buffer: []u8) ?[]const u8 {
        return s.tmp.dir.readFile(std.testing.io, name, buffer) catch null;
    }

    pub fn write(s: *Scratch, name: []const u8, bytes: []const u8) !void {
        try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
    }

    /// How many entries the directory holds, and whether any starts with
    /// `prefix`.
    pub fn entries(s: *Scratch, prefix: []const u8) !struct { count: usize, prefixed: usize } {
        var it = s.tmp.dir.iterate();
        var count: usize = 0;
        var prefixed: usize = 0;
        while (try it.next(std.testing.io)) |e| {
            count += 1;
            if (std.mem.startsWith(u8, e.name, prefix)) prefixed += 1;
        }
        return .{ .count = count, .prefixed = prefixed };
    }
};

/// Asserts that airlock made exactly `expected`, in order.
pub fn expectCalls(s: *seam.Seam, expected: []const seam.Call) !void {
    var buffer: [64]seam.Call = undefined;
    const got = s.calls(&buffer);
    std.testing.expectEqualSlices(seam.Call, expected, got) catch |err| {
        std.debug.print("calls: {any}\n", .{got});
        return err;
    };
}
