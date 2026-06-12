# raid

Low-level recursive file system traversal.

## What is this?

raid is a file finder focused on directory traversal. It does not try to be a desktop search tool, indexer, or shell plugin. It walks trees, applies filters, and prints paths.

The name comes from thinking of directories as a raid structure to explore - not the most creative, but it stuck.

> and yes, raid works well on RAID storage devices. youre welcome.

## Why?

Some tools are built around nice defaults: ignore files, hidden-file skipping, colors, config, git awareness. raid is more literal. If a directory can be read, it gets walked. If an error happens, you see it unless you ask not to.

## How to build

```bash
zig build-exe raid.zig -O ReleaseFast -lc -fstrip
```

### Zig version note

raid now targets **Zig 0.16+**.

Zig 0.16 introduced breaking changes to:

* process argument handling (`std.process.Init`)
* synchronization primitives (`std.Io.Mutex`, `std.Io.Condition`)

If you're building with an older Zig version, it will not compile without modification.
Use Zig 0.16 or newer, then compile this.

## How fast?

Fast enough to be worth using, but filesystem benchmarks are easy to lie with. Here is one cached local `/usr -maxdepth 4` run from this machine:

| Tool / mode | Time |
| ----------- | ---- |
| raid auto   | ~10.6 ms |
| raid raid   | ~10.9 ms |
| raid hdd    | ~15.1 ms |
| fd          | ~17.8 ms |

`-storage hdd` is supposed to be boring. It uses fewer workers and DFS so it does not hammer a spinning disk with random seeks. That can make it slower in cached SSD tests.

On a previous full system scan of `/` (average of 3 runs):

| Tool | Time   | Files found |
| ---- | ------ | ----------- |
| raid | ~0.45s | ~1,394,000  |
| fd   | ~0.45s | ~1,391,000  |

raid found slightly more files (~3,000 more in this test) because it walks more literally. Do not treat these numbers as universal. Cache state, mount options, permissions, hardware, and the chosen storage profile all matter.

## Quick start

```bash
# Find everything from here
raid .

# Find C source files
raid . -name "*.c"

# Literal extension filter
raid . -ext c

# Find paths containing a literal string
raid . -contains include

# Find files owned by root
raid / -type f -uid 0

# Include hidden files
raid / -H

# Stop at first level of subdirectories
raid / -maxdepth 2

# Stop after the first 10 matches
raid /usr -limit 10

# HDD-friendly traversal: fewer seeks, fewer workers
raid /mnt/archive -storage hdd

# RAID/SSD-style traversal: keep workers busy
raid /mnt/array -storage raid
```

## Options

```
-name PAT          Match basename against glob pattern
-path PAT          Match full path against glob pattern
-exclude PAT       Exclude basenames from results (but still traverse)
-exclude-path PAT  Exclude full paths from results (but still traverse)
-prune PAT         Skip directories matching pattern from descent
-prune-path PAT    Skip directories by full path
-ext EXT           Match file extension (dot optional)
-extension EXT     Alias for -ext
-contains TEXT     Match paths containing literal text
-type C            File type: f (regular), d (directory), l (symlink),
                   b (block), c (char), p (pipe), s (socket)
-uid N             Only files with this uid
-gid N             Only files with this gid
-inode N           Only this inode number
-perm MODE         Only files with exact permissions (octal)
-newer PATH        Only files newer than this file's mtime
-mindepth N        Minimum depth to report
-maxdepth N        Maximum depth to traverse or report
-xdev              Don't cross filesystem boundaries
-one-file-system   Alias for -xdev
-skip-vfs          Skip /proc /sys /dev /run (useful when scanning /)
-H, --hidden       Include hidden files (files starting with .)
-walk bfs|dfs      Breadth-first or depth-first traversal
-storage MODE      Storage profile: auto, hdd, ssd, raid
-j N               Number of worker threads (default: storage-tuned)
-0, -print0        Use NUL byte instead of newline to separate results
-noprint           Count matches but don't output them
-limit N           Stop after N matches
-q, -quiet         Suppress error messages
-stats             Print statistics at the end (files, dirs, errors, etc)
-time              Print wall clock and CPU time at the end
-h, --help         Show this message
-V, --version      Show version number
```

## Storage Profiles

`raid` defaults to `-storage auto`: CPU-count workers and breadth-first traversal. That is usually fine for SSDs, warm cache, and storage that handles parallel metadata reads well.

Use `-storage hdd` for spinning disks. It uses fewer workers and depth-first traversal to avoid turning a scan into a seek storm.

Use `-storage raid` for arrays and other multi-device storage. It keeps parallelism high so the device has enough work in flight.

You can always override the profile defaults with `-j N` and `-walk bfs|dfs`.

## Exit codes

```
0   Success - files were found (or at least traversal completed)
1   Errors occurred during traversal (but traversal continued)
2   Fatal error - bad arguments or similar
130 Interrupted (Ctrl+C)
```

Compatible with `find` for the most part.

## Design notes

* Storage profiles only set defaults; `-j N` and `-walk bfs|dfs` override them
* Default traversal is BFS because it exposes more parallel work
* HDD mode uses DFS and fewer workers to reduce seek pressure
* RAID mode keeps high parallelism for arrays and fast storage
* Directory reads use `posix_fadvise` sequential hints
* Directory opens try `O_NOATIME` and fall back if the kernel or permissions reject it
* Permission errors are reported but don't stop traversal
* Symlinks are followed to their target for type detection, not traversed
* The traversal is exhaustive - it won't skip directories due to heuristics

## Compared to other tools

* **fd**: More polished defaults, colors, regex, ignore-file support
* **find**: More portable, slower, different filter syntax
* **locate**: Instant but requires database, misses recent files

Pick the tool that matches the job. raid is for fast literal traversal, not for pretty output or project-aware search.

---

**raid is called raid because it doesn’t tiptoe around your filesystem trying to “find” shit, it kicks the door in and violently fucking raids everything like the swat finding your methlab**

> *By yours truly, obviously, RobertFlexx. enjoy my 6 hours of torture of writing zig code*
