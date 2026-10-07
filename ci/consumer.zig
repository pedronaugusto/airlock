//! What a project that depends on airlock and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch, so airlock's
//! build.zig must work without any of its own CI or test dependencies.
const std = @import("std");
const airlock = @import("airlock");

pub fn main() void {
    _ = &airlock.syncFile;
    _ = &airlock.syncDir;
    _ = &airlock.writeFile;
    _ = &airlock.Batch.init;
    _ = &airlock.FileId.of;
    _ = std;
}
