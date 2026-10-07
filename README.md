# airlock

airlock makes files durable in Zig. It syncs a file or a directory at a level
you choose and tells you what was reached, publishes a file atomically (replace,
create or keep) and a symbolic link too, creates directories durably, puts many
files under the fewest barriers, removes the temps a crash left behind, and
tells files apart by identity rather than by path.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/airlock` and add the `airlock` module to
your module's imports. It depends on `std` only.

## Usage

[examples/usage.zig](examples/usage.zig) replaces a file durably, creates a
directory durably, streams an object into a temp and publishes it only if the
name is free, and compares two paths by identity.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const airlock = @import("airlock");

const io = init.io;

// Replace a file: readers see the old contents or the new ones, and
// once this returns the new ones survive a power cut.
const config = try airlock.writeFile(io, dir, "config.json", "{\"v\":2}\n", .{});
std.debug.assert(config.reached.atLeast(.data));

// Create the directories an object goes into, each new one's entry
// synced in the directory that received it.
_ = try airlock.makePath(io, dir, "objects/ab", .{});

// Stream into a temp next to the destination, and publish it only if
// the name is free: an object that already exists is kept as it is.
var object = try airlock.create(io, dir, "objects/ab/cdef", .{ .temp = .{ .random = "tmp_obj_" } });
defer object.discard(io);
var buffer: [4096]u8 = undefined;
const w = object.writer(io, &buffer);
try w.writeAll("blob 5\x00hello");

// A batch syncs each file cheaply, flushes each volume once, renames
// in the order the files were added, then syncs each directory once.
var slots: [8]airlock.Batch.Slot = undefined;
var batch: airlock.Batch = .init(&slots);
defer batch.reset(io);
try batch.addPending(io, &object, .keep_existing);
const reached = try batch.commit(io, .{ .level = .data });
std.debug.assert(reached.atLeast(.data));

// Identity, not spelling: two paths to one file are one file.
const a = try airlock.FileId.ofPath(io, dir, "objects/ab/cdef", .{});
const b = try airlock.FileId.ofPath(io, cwd, ".zig-cache/airlock-example/objects/ab/cdef", .{});
std.debug.assert(a.eql(b));
```
<!-- END GENERATED -->

## Design

Every call takes a `Level`: `none`, `ordered` (after a power cut, the old file
or the complete new one, never a torn one), `data` (contents, length and any
name changed are durable) or `full` (all metadata too). Every call returns
`Reached`, what actually happened, because filesystems refuse calls: `exFAT`
and SMB on macOS refuse `F_FULLFSYNC`, ReFS and FAT refuse the data-only flush
on Windows. With `Fallback.report`, the default, airlock falls back to the
strongest call the filesystem accepts and says so; with `Fallback.refuse` it
returns `error.LevelUnavailable` instead. A fallback happens only on the codes
that mean the filesystem cannot be asked. Any other error means the bytes did
not get down: it is returned, never retried and never answered with a weaker
call, since the kernel may already have dropped the pages and cleared the
error. Only `EINTR` is retried, after a cancel check, and never for `close`.

The calls per level and platform:

| Level | Linux | macOS | Windows |
|---|---|---|---|
| `ordered`, file | `fdatasync` | `F_BARRIERFSYNC` | `NtFlushBuffersFileEx(DATA_SYNC_ONLY)` |
| `data`, file | `fdatasync` | `F_FULLFSYNC` | `DATA_SYNC_ONLY` |
| `full`, file | `fsync` | `F_FULLFSYNC` | `NtFlushBuffersFile` |
| `data`, directory | `fsync` | `F_FULLFSYNC` | reopened with `FILE_ADD_FILE`, `NtFlushBuffersFile` |

[src/platform.zig](src/platform.zig) holds the full table, the fallback
chains and what each one reports. `Reached.expected(level)` gives what this
platform reaches when no filesystem refuses, so a caller can pin its own
documentation to it.

`create` opens a temp next to the destination, never in a system temp
directory: a random name (a prefix and 128 random bits in lowercase base32) or
an exact one, such as a git `.lock` file. A nested destination has its
directory opened once and held, so the create, the rename and the directory
sync all work relative to one handle. Permissions are set on the open handle:
by default the temp takes those of the file it replaces, so replacing a `0600`
file never leaves it readable by others. A write through `writer` that fails
poisons the pending, since what reached the file is unknown. `commit` syncs the
temp through the handle that wrote it, publishes it, and syncs the directory
that received the name. A replace costs two flushes on
Linux and Windows, and one barrier and one flush on macOS, where the
directory's `F_FULLFSYNC` persists everything handed to the device before it.
A failed sync poisons the pending and removes the temp at once; its contents
are unknown. A rename that fails and leaves the temp intact can be retried
without a second sync, at the level of the first or below. A directory sync
that fails after the rename is `error.PublishedNotDurable`, with the cause
kept; `rename` and `remove` say the same for a failure after the name changed,
with the cause in `Diagnostics`. On Windows the rename is made through the
temp's own handle with POSIX semantics, retried with jittered backoff while a
scanner holds the target, and a delete removes the name even while another
process has the file open.

`makePath` creates the missing directories of a path and syncs the directory
each new one went into, so a file published into the deepest one is not lost
with a parent nobody synced; when a directory vanishes under it (a concurrent
prune), it starts again. `symLink` points a name at a target in one rename: a
temp link next to it, made durable before it replaces the name. `pruneTemps`
removes the random temps a crash or a kill left, by prefix and age, and nothing
else: only names a random temp can have, last modified long enough ago that no
other process is still writing them.

`Batch` takes files, pending publishes, directories and fences. It syncs each
file cheaply (Linux runs its `fdatasync`s concurrently; macOS and Windows write
each one out), puts one barrier per volume before the renames, renames in the
order the entries were added, syncs each distinct directory once, then flushes
each volume once. A hundred files on macOS cost one barrier and one flush
instead of a hundred flushes. A `fence` makes the renames after it reach the
disk after those before it; a fence the filesystem cannot keep, because it
refuses a directory's sync, leaves the batch `.written` at best. A publish that
finds its name taken under `keep_existing` syncs the existing file and its
directory inside the batch, so a batch that reports `.data` holds no file
nobody synced; on Windows a read-only file (a loose object) has its attribute
cleared for the open and put back. A pending a failed rename left synced joins
a batch without a second sync. The slots are the caller's storage. Each pending
holds its temp until its sync, the batch opens each distinct parent when it
first renames into it, and `addPath` files are opened `parallel` at a time and
closed after their sync, so a batch holds at most one descriptor per slot plus
`parallel`, and a batch of 3,000 paths about `parallel`.

`FileId` is a volume and a 128-bit file number, from the handle or from a path
without opening it. On Windows, two volumes cloned from one image keep both
the serial and the file ids, so a batch tells volumes apart by the NT device
name as well.

Every raw call goes through one file, `src/sys.zig`, behind a test seam: when
the `Io` a call is given is a layer whose `fileSync` is `sys.hookedSync`, a
hook decides the call first. Production pays one function-pointer compare per
call. Nothing allocates.

## Scope

- No locks or lock protocols. `Temp.exact` is the exclusive create a lock file
  needs; the protocol (pid, staleness, backoff) belongs to its user, and
  advisory locks are in `std.Io.File.Lock`.
- No write-ahead log, group commit or record framing: airlock syncs, it does
  not decide when.
- No `O_TMPFILE`, no copy-on-write clones, and no `msync`. A replace keeps
  the permissions it replaces, not extended attributes, ACLs or ownership.
- A replace or a link swap replaces the name, a symbolic link included; it
  does not write through it.
- No identity that survives a remount.
- Its raw calls block the calling thread, as `Io.Threaded` does. Under an
  evented `Io`, run them through `io.concurrent`.

## Platforms

Linux, macOS and Windows are tested in CI. The BSDs compile and use plain
`fsync` for every level; their rows are not verified. `symLink` returns
`error.OperationUnsupported` on Windows, where creating a symbolic link needs a
privilege or developer mode. On macOS, what APFS does
with `F_BARRIERFSYNC` on a third-party drive without barrier support is not
documented; `barrier = false` makes every replace two full flushes. macOS and
Windows have no block-level crash replay, so their tables rest on the man
pages and Microsoft's documentation, and on the crash model below.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing else is
  linked into the module.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.
- [shakedown](https://github.com/pedronaugusto/shakedown) is the `FaultIo`,
  clock and single-fault sweep the tests run on, fetched only for them.

## Testing

`zig build test` runs the unit suite and the example. Every raw call is a step
of a [shakedown](https://github.com/pedronaugusto/shakedown) `FaultIo`, so the
tests assert the exact calls each level makes on each platform, which fixes
the barrier counts above. They fault each call with each class of error: a
refusal, `EIO`, `ENOSPC`, `EINTR`, a cancel and, on Windows, a sharing
violation and a pending delete. The single-fault sweep runs every one of those
at every step of a sync, a replace in each publish mode, a rename, a remove,
a link swap, a `makePath` and a batch with a fence, and checks that the
destination is old or new and never torn, that no temp is left, that a failed
sync is never followed by another sync of that file, that what was reported is
no more than a crash model proves, and that no crash state shows a rename after
a fence without those before it. The model replays a run's calls against each
platform's documented persistence rules and enumerates every state a crash
could leave; on macOS it runs with the barrier honoured and dropped, and shows
the window `barrier = false` closes. A batch's descriptors are counted at every
raw call, so the budget above is measured at its peak, and the Windows retry
deadlines run on shakedown's clock. `zig build bench` runs the benchmarks by hand
(`-- --dir <path>` puts the files on the disk to measure): each level's sync
cost, replaces and batches per level and size, the raw calls and barriers of
each operation counted through the seam, and the code airlock replaces beside
it on the same work. CI compiles them and never times them.

[CI](.github/workflows/ci.yml) runs the source checks and the Linux Debug suite
on every push it is asked for, and before a merge the Debug suite on macOS and
Windows as well. `zig build check` cross-compiles for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl`, `x86_64-windows-gnu`,
`aarch64-windows-gnu`, `x86_64-macos` and `aarch64-macos`.

## Licence

MIT. See [LICENSE](LICENSE).
