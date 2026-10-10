# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

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
- airlock imports aegis (`aegis.id`, `aegis.handle` and `aegis.assert`) and is no
  longer `std` only. A consumer's build fetches aegis with airlock and wires
  nothing.

### Added

- `airlock.testing` takes a `Gate`: `Options.gate` stands a task still at the first
  raw call of a kind at a name, until the test releases it, for a test that
  races something else against one step of a publish. `Seam.reopen` arms it again.

### Fixed

- On macOS a publish whose file no sync reached (every sync refused) reports
  `.none`, not `.full`: the directory's `F_FULLFSYNC` persists only what was
  handed to the device.

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

### Added

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

[Unreleased]: https://github.com/pedronaugusto/airlock/commits/main
