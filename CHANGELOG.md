# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-10-27

### Breaking

- `Blocking` is an interface a runner embeds, with nothing erased: `run(self: *Blocking, io, job: *Blocking.Job)`. A runner with state finds itself from `self` with `@fieldParentPtr`; one without ignores it. The job is a `Blocking.Job` the raw call embeds; the runner calls `job.execute()` on the thread it chooses. `Blocking.context` and the erased function and argument are gone. The options that take one (`SyncOptions.blocking`, `Batch.Options.blocking`, `Pending.CommitOptions.blocking`) hold a `?*Blocking`. Before: `.blocking = .{ .context = e, .run = run }` with `fn run(io, context: ?*anyopaque, function: *const fn (*anyopaque) void, argument: *anyopaque)`. After: a field `blocking: airlock.Blocking = .{ .run = run }` in the runner, `.blocking = &runner.blocking`, with `fn run(self: *airlock.Blocking, io: Io, job: *airlock.Blocking.Job)`.
- `Pending.file()` lends the temp file, an `aegis.own.Lent(Io.File)`: `p.file().get()` is the file, still the pending's to close.

### Changed

- Under the aegis pack on aegis 0.2.1: a file's times are read as aegis instants on the real clock; the contention backoff measures its deadline and waits as aegis instants and spans; std's `Io` userdata, which the hooked layer's sync is handed, and the system's declarations carry their contract where they are.
- The walks over a caller's path (where its base starts, its parent, the components `makePath` creates) are in one place, `paths.zig`, and fuzzed: three shakedown properties, seeded in `zig build test` and searched by the hardened gate's `--fuzz` campaign, hold that any path gives indexes and slices inside it and the names a plain split would.

## [0.5.5] - 2026-10-25

### Added

- `Temp.in_place`: no temp. The file is created exclusively under its own name (`O_EXCL`, so a link there is never followed and a taken name is `error.PathAlreadyExists`), and its commit renames nothing. The name holds a partial file while it is written and after a crash, so it is for `level = .none` only: a commit or batch at another level stops as a caller's bug. For an extraction that asked for no crash guarantee, where the rename was the largest cost (hold's many small files).

## [0.5.4] - 2026-10-24

### Changed

- Pins aegis 0.1.17.

## [0.5.3] - 2026-10-22

### Fixed

- On Linux with a C library linked, airlock opened and closed descriptors with the kernel's own calls, past the library. ThreadSanitizer keeps a record per descriptor and forgets it only at a close it sees, so a descriptor airlock closed and another thread then got under the same number read as a data race "in close" (every report in relic's ThreadSanitizer job on 2026-10-22, 15 of them). Opens and closes now go through the C library wherever one is linked, as std's do; without one they stay the kernel's calls.

## [0.5.2] - 2026-10-21

### Fixed

- `Volume.name` was empty on Linux where `statx` gives no usable mount id (a kernel before 5.8; QEMU's user mode, which sets `STATX_MNT_ID` and gives 0, the riscv64 leg's red since 2026-10-18): the mount is then found in `/proc/self/mountinfo` by the device its file system is on.
- The scan test expected seven entries on Windows, where its fixture makes no symbolic link and holds six (its red on every Windows leg since 2026-10-18); it expects each platform's count.

## [0.5.1] - 2026-10-21

### Changed

- Over a simulation, a stat (`airlock.stat`, `scan`) carries the device, owner and group the simulated disk keeps for the file (shakedown's `Sim.Fs.ownership`), where it said the routed volume and no owner: the seam's route asks its file system through an `ownership` callback beside `flush`. A file the disk does not know still says the routed volume and no owner.
- Development pins shakedown 0.4.15; pins aegis 0.1.12.

## [0.5.0] - 2026-10-18

### Breaking

- `airlock.testing.Call` gains `scan`, Darwin's batch call.

### Added

- `airlock.scan(dir, buffer)` (`airlock.Scan`): a directory's entries, each with its whole stat (`airlock.Stat`), read into a buffer the caller owns. Darwin reads them in batches through `getattrlistbulk`, the device, owner and group included; a volume that refuses the call, and every other platform, reads the directory and stats each entry, so on Windows an entry's kind is its attributes' and reparse tag's, not the listing's. A directory's size is zero on both arms. Over a simulation it reads and stats through the `Io`. Moved from relic's working-tree scan.

## [0.4.0] - 2026-10-18

### Breaking

- `airlock.testing.Call` gains `stat` and `statfs`, the raw calls of the two below.

### Added

- `airlock.stat(io, dir, sub_path, .{ .follow_symlinks })`: one platform stat of a path (`statx`, `fstatat`; on Windows an open for its attributes) with what `std.Io.File.Stat` leaves out: the device, the owner and group, the mode's bits, a creation time where kept, and on Windows the attributes and a reparse point's tag (`Stat`). `FileNotFound` and `NotDir` are apart, where std's macOS stat reads ENOTDIR as `FileNotFound`. Over a simulation it is the `Io`'s stat.
- `airlock.Volume.of(io, dir)`: whether a directory's volume is another machine's (Darwin's `MNT_LOCAL`; on Linux the network file systems' magic numbers and FUSE; a Windows remote device) and its file system's type name (`f_fstypename`, the mount table's type, Windows' file system name).

### Fixed

- A batch orders slots that share a device and file by `Index.compare`, aegis's
  order for indices, not by their raw values.

## [0.3.5] - 2026-10-14

### Changed

- Pins aegis 0.1.8.

## [0.3.4] - 2026-10-14

### Changed

- Pins aegis 0.1.7.

## [0.3.3] - 2026-10-14

### Changed

- Pins aegis 0.1.6.

## [0.3.2] - 2026-10-13

### Changed

- The README names reactor's adapter for `Blocking`: `reactor.syncLane`, which runs each raw sync on a runtime's `sync` lane.

## [0.3.1] - 2026-10-13

### Added

- airlock runs inside a shakedown `Sim`. A seam over a simulation's `Io`
  routes every raw call into it: opens, creates, renames, links,
  removes, stats and closes through the `Io`, and each sync onto
  `Sim.Fs.flush` at the strength the platform's call has (a writeout, a
  barrier, a data or a full flush). The hook still decides each call first,
  one for one with the raw call it stands for, so plans, traces and counts are
  the same; the calls only stop failing with `EBADF` on simulated handles.
  The tests run every operation through shakedown's `everyCrash`: a power loss
  at every step, every state the disk could come back in.

### Fixed

- A device failure, a full disk and a name whose file awaits deletion are named
  errors, where Windows (and POSIX for `EIO` on a mkdir and `ENOSPC` on a
  chmod) reported `error.Unexpected`: `InputOutput` and `NoSpaceLeft` join the
  error sets of the calls that can meet them, and `FileId` and `Batch` gain
  `InputOutput`.
- On Windows a call a simulation answers no longer converts its names to NT's
  form, which took several 64 KiB buffers of a simulated task's stack.

## [0.3.0] - 2026-10-13

### Breaking

- `aegis(dependency)` is gone. It gave a project the aegis to bind its shakedown to, and bay gives a graph one aegis, so nothing binds it: `testing` takes the project's shakedown as it is.

### Changed

- The tests take shakedown as bay gives it, with no `.aegis = .consumer` or `useAegis` binding: bay gives a graph one aegis, so shakedown's is this package's.

## [0.2.1] - 2026-10-12

### Changed

- Pins aegis 0.1.1, shakedown 0.2.6 and preflight 0.3.4.

## [0.2.0] - 2026-10-12

### Breaking

- `testing(dependency, shakedown)` takes the project's own shakedown module, and `aegis(dependency)` gives the aegis airlock is built on, for the project to bind its shakedown to with shakedown's `useAegis`: a project's tests link the shakedown it pins, and nothing reaches into airlock's modules for one. airlock no longer has a lazy shakedown dependency, and `testing` no longer returns `error.LazyDependencyNeeded`.
- airlock is developed with [bay](https://github.com/pedronaugusto/bay): preflight is a dev dependency, and the tests, example and benchmarks are the development build's (`bay test`, `bay bench`). shakedown stays a lazy dependency for `airlock.testing` and is also a dev dependency. What a project that depends on airlock builds is unchanged, except that `airlock.testing` takes shakedown bound to airlock's aegis, so a binary links one aegis.
- `sys` leaves the module. The test seam is `airlock.testing`, a module of its
  own that a project's build gets from `@import("airlock").testing(dependency)`:
  `Seam` does what a hand-built layer over `sys.HookedState` did, with traces,
  counts, `syncs`, `setPlan` and `everyFault`'s `FaultIo`.
- `Fallback` and the `fallback` options are gone, and so is `SyncError`. A
  call that degrades and reports cannot return `error.LevelUnavailable`, so its
  error set no longer has it: `syncFile` returns `std.Io.File.SyncError`, and
  `syncDir`, `syncPath`, `writeFile`, `Pending.commit`, `Batch.commit`,
  `rename`, `remove`, `makePath` and `symLink` lose it. A publish that refuses
  calls `commitOrRefuse`, `writeFileOrRefuse`, `Batch.commitOrRefuse` or
  `symLinkOrRefuse`; a sync, `rename`, `remove` or `makePath` reports, and a
  caller compares `Reached.atLeast`.
- A commit retried after a failed rename, alone or in a batch, keeps what its
  first sync reached: `commit` publishes and reports it, where it returned
  `error.LevelUnavailable` for a stronger level; `commitOrRefuse` refuses only
  when that is below the level.
- `Batch.Failure.slot` is a `Batch.SlotIndex`, an aegis `handle.Index`, where
  it was a `u32`. It is the place the slot was added at, whatever order the
  commit sorted the directories in; `slot.raw()` gives the number, and
  `slot.get(entries)` gives the caller's own entry or `error.OutOfBounds`.
- airlock imports aegis (its `id`, `handle` and `assert` namespaces) and is no
  longer `std` only. A consumer's build fetches aegis with airlock and wires
  nothing.

### Added

- `airlock.testing` takes a `Gate`: `Options.gate` stands a task still at the first
  raw call of a kind at a name, until the test releases it, for a test that
  races something else against one step of a publish. `Seam.reopen` arms it again.
- Optional `Blocking` executor in sync, publish and batch options: raw syncs
  can run on an application's executor while airlock needs no runtime of its own.
  Null runs inline; adapters drain started jobs before returning.
- Raw primitive probes, isolated new/overwrite rows, append comparisons and
  per-row barrier counts in `bench/`; macOS and Linux measurements with the
  design's acceptance targets. CI compiles benchmark rows without timing them.
- `Level` and `Reached`: a durability level per call, and what the call
  reached.
- `syncFile`, `syncDir` and `syncPath`, through the platform's fallback chain:
  `fdatasync` and `fsync` on Linux, `F_BARRIERFSYNC` and `F_FULLFSYNC` on
  macOS, `NtFlushBuffersFileEx` and `NtFlushBuffersFile` on Windows, where
  directories are flushed too. An `O_PATH` handle or `cwd()` is reopened for a
  directory sync.
- `Pending`, `create` and `writeFile`: a temp next to the destination with a
  random or exact name, permissions set on the open handle (by default those
  of the file it replaces), a writer with optional early writeback whose
  failed write poisons the pending, and `commit` as replace, create-new or
  keep-existing, with the Windows rename by handle and its retry.
  `commitOrRefuse` and `writeFileOrRefuse` return `error.LevelUnavailable`
  rather than publish below the level, decided before the rename on macOS and
  Windows. `file()`,
  `cause()` and `state()` read a pending; the steps a batch takes are not
  public.
- `rename` and `remove` with the directory syncs they need; a failure after
  the name changed is `error.PublishedNotDurable`, its cause in `Diagnostics`.
- `makePath`, which creates the missing directories of a path and syncs the
  entry of each new one; `symLink`, an atomic link swap made durable before
  and after its rename (POSIX); and `pruneTemps`, which removes the random
  temps a crash left, by prefix and age.
- `Batch`: files, pending publishes, directories and fences under one barrier
  and one flush per volume, in caller-owned slots, within one descriptor per
  slot plus `parallel`. A kept name's file and directory are synced, a
  pending a failed rename left synced is not synced again, and on Windows a
  read-only file is synced too.
- `FileId`, a file's volume and 128-bit number, by handle or by path.
- `airlock.testing`, the test seam every raw call goes through, on shakedown,
  for airlock's tests and its users'.

### Changed

- Using a `Pending` out of turn stops the program in every build, where it was
  undefined behaviour in `ReleaseFast`, or a write to a closed descriptor:
  `file()` and `writer()` only while it is `open` (after a sync the temp is
  closed on POSIX, and its descriptor number may belong to another file),
  `commit` and `commitOrRefuse` only until it has ended, and
  `Batch.addPending` only a pending that is `open` or `synced`.
  `Batch.init` refuses storage of more than `u32` slots, and `Seam.setPlan` a
  plan of more than 16 entries, the same way.
- A staged file's moves are checked against one table (a pending never goes
  back, only a synced temp is published or kept, `discard` follows any state),
  in every build.
- A volume's number and the hash of its device name are different types inside
  a batch, so one cannot stand for the other in a volume key; `FileId` keeps
  its `u64` and `u128` fields, which strand writes into checkpoints.
- Darwin batches overlap per-file writeouts within `parallel`, retaining writing-handle error checks and the same per-volume barriers and flushes.
- Pins aegis 0.1.0.

### Fixed

- On macOS a publish whose file no sync reached (every sync refused) reports
  `.none`, not `.full`: the directory's `F_FULLFSYNC` persists only what was
  handed to the device.

[Unreleased]: https://github.com/pedronaugusto/airlock/commits/main
