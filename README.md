# raid

Low-level recursive file system traversal.

## What is this?

raid is a file finder that does one thing well: traverse directories and find files. It's built to be thorough and correct, not flashy. No colors, no config files, no surprises. Just fast, predictable file traversal that works the way you expect.

The name comes from thinking of directories as a raid structure to explore - not the most creative, but it stuck.

> and yes, raid works well on RAID storage devices. youre welcome.
## Why?

Most file finders optimize for the common case and cut corners elsewhere. That's fine for 99% of uses, but sometimes you need something that doesn't skip hidden files by default, doesn't ignore permission errors silently, and doesn't make assumptions about what you actually asked for.

raid is that tool. It's rigorous where it counts, and fast because it has to be.

## How fast?

Competitive. On a full system scan of `/` (average of 3 runs):

| Tool | Time | Files found |
|------|------|-------------|
| raid | ~0.45s | ~1,394,000 |
| fd   | ~0.45s | ~1,391,000 |

They're essentially tied on speed. raid finds slightly more files (~3,000 more in this test) due to more rigorous traversal. **Your mileage will vary based on filesystem size and hardware!!**

## Building

```bash
zig build-exe -lc -O ReleaseFast raid.zig
```

You'll need Zig 0.12+ and a Linux system. The `-lc` links against libc, which is required for directory traversal syscalls.

## Quick start

```bash
# Find everything from here
raid .

# Find C source files
raid . -name "*.c"

# Find files owned by root
raid / -type f -uid 0

# Include hidden files
raid / -H

# Stop at first level of subdirectories
raid / -maxdepth 2
```

## Options

```
-name PAT       Match basename against glob pattern
-path PAT       Match full path against glob pattern
-exclude PAT    Exclude basenames from results (but still traverse)
-prune PAT      Skip directories matching pattern from descent
-prune-path PAT Skip directories by full path
-type C         File type: f (regular), d (directory), l (symlink),
                b (block), c (char), p (pipe), s (socket)
-uid N          Only files with this uid
-gid N          Only files with this gid
-inode N        Only this inode number
-perm MODE      Only files with exact permissions (octal)
-newer PATH     Only files newer than this file's mtime
-mindepth N    Minimum depth to report
-maxdepth N     Maximum depth to traverse or report
-xdev           Don't cross filesystem boundaries
-skip-vfs       Skip /proc /sys /dev /run (useful when scanning /)
-H, --hidden    Include hidden files (files starting with .)
-walk bfs|dfs   Breadth-first or depth-first traversal (default: bfs)
-j N            Number of worker threads (default: use all cores)
-0, -print0     Use NUL byte instead of newline to separate results
-noprint        Count matches but don't output them
-q, -quiet      Suppress error messages
-stats          Print statistics at the end (files, dirs, errors, etc)
-time           Print wall clock and CPU time at the end
-h, --help      Show this message
-V, --version   Show version number
```

## Exit codes

```
0   Success - files were found (or at least traversal completed)
1   Errors occurred during traversal (but traversal continued)
2   Fatal error - bad arguments or similar
130 Interrupted (Ctrl+C)
```

Compatible with `find` for the most part.

## Design notes

- Single-threaded by default, but uses multiple workers when `-j N` is specified
- Uses BFS by default (breadth-first), switch to DFS with `-walk dfs` if you prefer
- Permission errors are reported but don't stop traversal
- Symlinks are followed to their target for type detection, not traversed
- The traversal is exhaustive - it won't skip directories due to heuristics

## Compared to other tools

- **fd**: Slightly faster, more features (colored output, regex, etc)
- **find**: More portable, slower, different filter syntax
- **locate**: Instant but requires database, misses recent files

Pick the right tool for the job. raid is great when you need speed and correctness over features.

---

**raid is called raid because it doesn’t tiptoe around your filesystem trying to “find” shit, it kicks the door in and violently fucking raids everything like the swat finding your methlab**

> *By yours truly, obviously, RobertFlexx. enjoy my 6 hours of torture of writing zig code*
