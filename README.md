# raid

Low-level recursive file system traversal.

## What is this?

raid is a file finder focused on directory traversal. It does not try to be a desktop search tool, indexer, or shell plugin. It walks trees, applies filters, and prints paths.

The name comes from thinking of directories as a raid structure to explore - not the most creative, but it stuck.

> and yes, raid works well on RAID storage devices. youre welcome.

## Why?

Some tools are built around nice defaults: ignore files, hidden-file skipping, colors, config, git awareness. raid is more literal. If a directory can be read, it gets walked. If an error happens, you see it unless you ask not to.

## What changed in raid 2.0?

raid 2.0 is still the same tool and the same idea. it just stopped doing a few stupid things internally and got a lot more features.

The traversal core was rewritten around Linux `getdents64` instead of `readdir`. It avoids creating metadata syscalls when a filter does not need them, reuses worker buffers, batches directory queue operations, buffers output, and uses a reclaiming allocator instead of pretending an arena allocator frees things when it obviously does not.

It also now has:

* smart-case substring matching
* glob matching with `*`, `?`, ranges, and character classes
* repeatable extension filters
* repeatable exclude and prune patterns
* executable and empty-file filters
* exact, minimum, and maximum size filters
* modification age filters
* colored output
* long listing output
* human-readable sizes
* file type classification suffixes
* absolute output paths
* explicit multiple search roots
* exact result limits during parallel traversal
* proper Ctrl+C and SIGTERM cancellation
* queue draining instead of leaving abandoned work sitting around
* worker-local reusable path and output buffers
* direct directory reads with a much smaller syscall and allocation footprint

The goal was not to turn raid into fd with a different name. The goal was to keep raid literal and low-level while making it less likely to eat your ram, mix output from multiple threads together, or ignore Ctrl+C like a possessed process.

## How to build

```bash
zig build-exe raid.zig -O ReleaseFast -lc -fstrip
```

The full project build also works:

```bash
zig build -Doptimize=ReleaseFast
```

The binary will be placed at:

```bash
./zig-out/bin/raid
```

Install it system-wide:

```bash
sudo install -m755 zig-out/bin/raid /usr/local/bin/raid
```

Or build the rewritten source directly:

```bash
zig build-exe src/main.zig -O ReleaseFast -lc -fstrip -femit-bin=raid
```

### Zig version note

raid now targets **Zig 0.16+**.

Zig 0.16 introduced breaking changes to:

* process argument handling (`std.process.Init`)
* synchronization primitives (`std.Io.Mutex`, `std.Io.Condition`)

If you're building with an older Zig version, it will not compile without modification.
Use Zig 0.16 or newer, then compile this.

### Platform note

The modern traversal core is Linux-first.

It uses `getdents64`, `fstatat`, `openat`, Linux directory entry types, and other low-level Linux behavior on purpose. Portability is nice, but pretending every operating system exposes the same fast traversal path is how you end up with twelve abstraction layers and a file finder that needs therapy.

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

### What the rewrite optimizes

The newer traversal path is mostly trying to avoid doing work in the first place:

* it uses directory entry type information when the filesystem provides it
* it only calls `fstatat` when a selected filter or output mode needs metadata
* it does not allocate a permanent path object for every file it sees
* each worker reuses its own path, directory, stat, and output buffers
* discovered directories are pushed to the shared queue in batches
* output is flushed in complete records so two workers cannot splice filenames together
* `--no-print` avoids formatting and output work entirely
* `--max-results` uses one shared parallel limit instead of every worker overshooting it independently
* cancellation stops new queue work and drains anything already waiting

None of that makes storage physics stop existing. A cold HDD scan is still a cold HDD scan. raid cannot threaten the platters into seeking faster. unfortunately.

### Benchmarking it without lying

Compare equivalent behavior:

```bash
hyperfine --warmup 3 \
  './zig-out/bin/raid -e zig -t f .' \
  'fd --extension zig --type f .'
```

For traversal-only testing:

```bash
hyperfine --warmup 3 \
  './zig-out/bin/raid --no-print --stats --time "" /usr' \
  'fd --no-ignore --hidden . /usr >/dev/null'
```

Make sure both tools agree on hidden files, ignore files, symlinks, output, color, file types, and search roots. Otherwise you are not benchmarking two implementations of the same job. you are benchmarking two different jobs and acting surprised when the numbers are different.

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

## New command style

The modern CLI also supports an fd-style positional form:

```bash
raid [OPTIONS] [PATTERN] [PATH ...]
```

Examples:

```bash
# Smart-case basename substring search
raid config src

# Find regular Zig files
raid -e zig -t f .

# Use an actual glob instead of substring matching
raid -g "*.png" ~/Pictures

# Match the full path instead of only the basename
raid -p cache /var

# Force a directory-looking string to be treated as the pattern
raid --pattern build --path .

# Search more than one explicit root
raid config --path /etc --path /usr

# Find files larger than 100 MiB
raid --size +100M --type f /mnt/storage

# Find files smaller than 4 KiB
raid --size -4K --type f .

# Find files modified in the last 2 hours
raid --changed-within 2h --type f ~/Downloads

# Find files older than 30 days
raid --changed-before 30d --type f /var/log

# Find executables
raid --type x /usr/local/bin

# Find empty files and directories
raid --type e .

# Exclude as many patterns as needed
raid package . -E node_modules -E target -E .git

# Prune matching directories from traversal
raid config . --prune node_modules --prune .git

# Colored long listing
raid log /var --long --human-readable --color always

# Add type suffixes like /, @, *, |, and =
raid --classify .

# Print absolute paths
raid --absolute config .

# Keep the leading ./ prefix
raid --no-strip-prefix config .

# Measure traversal without printing every match
raid --no-print --stats --time "" /
```

A single positional argument that currently names a directory is treated as a search root. This keeps `raid .` doing the obvious thing.

Use `--pattern` when the pattern itself happens to look like a directory and you do not want raid trying to be clever for once.

## Matching behavior

The default pattern mode is a basename substring search.

It uses smart case:

* `raid config .` matches `Config`, `CONFIG`, and `config`
* `raid Config .` is case-sensitive because the pattern contains an uppercase letter
* `--ignore-case` always ignores case
* `--case-sensitive` always respects case
* `--smart-case` puts it back to the default

Use `--glob` when you actually want a glob:

```bash
raid --glob "*.zig" .
raid -g "src/??in.[ch]" -p .
raid -g "*.[Pp][Nn][Gg]" ~/Pictures
```

`--full-path` makes the main pattern run against the full path instead of only the basename.

Extensions, excludes, and prunes are repeatable:

```bash
raid -e c -e h -e cpp -e hpp .
raid -E node_modules -E target -E .git .
raid --prune proc --prune sys --prune dev /
```

An exclude suppresses matching output and prevents descent when the excluded entry is a directory.

A prune only controls descent. The directory itself may still be printed if it matches the result filters. This is useful when you want to see that the directory exists without letting raid disappear into it for the next eleven years.

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

### raid 2.0 options

The newer CLI spellings are:

```
-g, --glob                 Treat PATTERN as a glob instead of a substring
-p, --full-path            Match PATTERN against the full path
-i, --ignore-case          Always use case-insensitive matching
-s, --case-sensitive       Always use case-sensitive matching
--smart-case               Ignore case unless PATTERN contains uppercase letters
-e, --extension EXT        Match an extension; repeatable
-E, --exclude GLOB         Exclude matching names or paths; repeatable
--prune GLOB               Do not descend into matching directories; repeatable
-t, --type TYPE            f, d, l, b, c, p, s, x (executable), e (empty)
--size SIZE                Exact, +minimum, or -maximum size
--changed-within DUR       Modified within a duration
--changed-before DUR       Modified more than a duration ago
--newer FILE               Modified more recently than FILE
--uid N                    Exact user id
--gid N                    Exact group id
--inode N                  Exact inode number
--perm MODE                Exact octal permission bits
--min-depth N              Minimum result depth
-d, --max-depth N          Maximum traversal and result depth
-H, --hidden               Include hidden entries
--one-file-system          Do not cross filesystem boundaries
--skip-vfs                 Skip /proc, /sys, /dev, and /run
-j, --threads N            Worker count; 0 uses a storage-tuned default
--storage MODE             Storage mode: auto, hdd, or ssd
--walk MODE                Traversal order: bfs or dfs
--path PATH                Add an explicit search root; repeatable
--pattern PATTERN          Force an explicit search pattern
-a, --absolute             Canonicalize roots to absolute paths
-l, --long                 Print permissions, size, timestamp, and path
-h, --human-readable       Use human-readable sizes with --long
--classify                 Append /, @, *, |, or = indicators
--color WHEN               Color mode: auto, always, or never
--no-color                 Disable colors
-0, --print0               Separate results with NUL bytes
--no-strip-prefix          Keep a leading ./ in output
--max-results N            Stop after N matches
--no-print                 Traverse and count without printing matches
-q, --quiet                Suppress traversal errors
--stats                    Print traversal counters
--time                     Print wall and CPU time
--help                     Show the colored help screen
-V, --version              Show version
```

### Size syntax

`--size` accepts bytes by default and the suffixes `K`, `KB`, `M`, `MB`, `G`, `GB`, `T`, and `TB`.

```bash
raid --size 4096 .       # exactly 4096 bytes
raid --size +100M .      # larger than 100 MiB
raid --size -4K .        # smaller than 4 KiB
```

A leading `+` means greater than the value. A leading `-` means less than the value. No prefix means exact.

### Duration syntax

Modification age filters accept:

```
s   seconds
m   minutes
h   hours
d   days
w   weeks
```

Examples:

```bash
raid --changed-within 30m .
raid --changed-within 2h .
raid --changed-before 7d .
raid --changed-before 12w .
```

## Storage Profiles

`raid` defaults to `-storage auto`: CPU-count workers and breadth-first traversal. That is usually fine for SSDs, warm cache, and storage that handles parallel metadata reads well.

Use `-storage hdd` for spinning disks. It uses fewer workers and depth-first traversal to avoid turning a scan into a seek storm.

Use `-storage raid` for arrays and other multi-device storage. It keeps parallelism high so the device has enough work in flight.

You can always override the profile defaults with `-j N` and `-walk bfs|dfs`.

### Modern storage spellings

The rewritten CLI uses:

```bash
raid --storage auto
raid --storage hdd
raid --storage ssd
```

`auto` and `ssd` use breadth-first traversal and keep more work available for parallel workers.

`hdd` uses fewer workers and defaults to depth-first traversal to reduce random seeking.

`--threads N` and `--walk bfs|dfs` always override the defaults. Worker counts above 256 are rejected because spawning 4,096 threads does not make your SATA SSD experience spiritual enlightenment.

## Color and output

Color defaults to `auto`.

That means raid colors results only when stdout is a terminal. Redirected output stays clean.

```bash
raid --color auto .
raid --color always .
raid --color never .
raid --no-color .
```

The `NO_COLOR` environment variable is respected.

`--print0` disables color automatically because ANSI escape sequences inside NUL-delimited machine output would be impressively stupid.

Current colors are:

* directories: blue
* symlinks: cyan
* executables: green
* pipes: yellow
* sockets: magenta
* block and character devices: bright yellow
* normal files: terminal default

Long output includes permissions, size, modification time, and path:

```bash
raid --long .
raid --long --human-readable .
```

Classification suffixes are:

```
/   directory
@   symlink
*   executable
|   named pipe
=   socket
```

## Exit codes

```
0   Success - files were found (or at least traversal completed)
1   Errors occurred during traversal (but traversal continued)
2   Fatal error - bad arguments or similar
130 Interrupted (Ctrl+C)
```

Compatible with `find` for the most part.

SIGTERM is handled like an actual request to stop instead of a vague suggestion.

Broken output pipes also stop traversal. This matters for commands like:

```bash
raid . | head
```

raid does not need to finish scanning the observable universe after the receiving command has already left.

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

### raid 2.0 design notes

* Linux directory entries are read directly through `getdents64`
* Metadata is loaded lazily and only when a filter or output mode needs it
* Symlinks in the rewritten traversal path are reported but never followed
* Worker allocations use `std.heap.smp_allocator`
* Temporary paths and tasks are reclaimed instead of living until process exit
* Each worker keeps reusable buffers instead of repeatedly allocating tiny objects
* Directories are added to the shared work queue in batches
* Queue shutdown refuses new work and drains tasks that were already queued
* Ctrl+C and SIGTERM request cancellation without doing unsafe work inside the signal handler
* Parallel output is buffered and written as complete records
* NUL output stays binary-safe and disables color
* Exact parallel result limits stop the queue once the requested number is reserved
* Errors include the failed operation, path, and operating system error message
* Out-of-memory failures abort loudly instead of silently skipping results
* Root paths are normalized so trailing slashes do not corrupt basename matching
* Pruning applies to directory descent instead of randomly deleting matching regular files from reality

## Statistics

`--stats` prints counters after traversal.

The exact list can change as the implementation grows, but it includes the useful stuff: matches, files, directories, links, other entry types, queued directories, errors, worker count, traversal mode, storage mode, and emitted bytes.

Use it with `--no-print` for traversal measurements:

```bash
raid --no-print --stats .
```

Use `--time` to include wall time and CPU time:

```bash
raid --no-print --stats --time .
```

The CPU percentage can exceed 100% because raid is parallel. That is not a mathematical emergency. It means more than one core was working.

## Compared to other tools

* **fd**: More polished defaults, colors, regex, ignore-file support
* **find**: More portable, slower, different filter syntax
* **locate**: Instant but requires database, misses recent files

Pick the tool that matches the job. raid is for fast literal traversal, not for pretty output or project-aware search.

raid 2.0 now has colors and prettier output, but it still does not read `.gitignore`, invent project boundaries, silently hide half the filesystem, or act like a shell plugin. The literal traversal behavior is still the point.

`fd` is still the nicer default for many project searches.

raid is for when you want the tree walked exactly because you asked for the tree to be walked.

---

**raid is called raid because it doesn’t tiptoe around your filesystem trying to “find” shit, it kicks the door in and violently fucking raids everything like the swat finding your methlab**

> *By yours truly, obviously, RobertFlexx. enjoy my 6 hours of torture of writing zig code*
