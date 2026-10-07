# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Level`, `Reached` and `Fallback`: a durability level per call, what the call
  reached, and whether a filesystem's refusal degrades and reports or fails.
- `syncFile`, `syncDir` and `syncPath`, through the platform's fallback chain:
  `fdatasync` and `fsync` on Linux, `F_BARRIERFSYNC` and `F_FULLFSYNC` on
  macOS, `NtFlushBuffersFileEx` and `NtFlushBuffersFile` on Windows, where
  directories are flushed too. An `O_PATH` handle or `cwd()` is reopened for a
  directory sync.
- `Pending`, `create` and `writeFile`: a temp next to the destination with a
  random or exact name, permissions set on the open handle (by default those
  of the file it replaces), a writer with optional early writeback whose
  failed write poisons the pending, and `commit` as replace, create-new or
  keep-existing, with the Windows rename by handle and its retry. `file()`,
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
- `sys`, the test seam every raw call goes through.

[Unreleased]: https://github.com/pedronaugusto/airlock/commits/main
