const std = @import("std");

const CLOCK_MONOTONIC = 1;
const CLOCK_PROCESS_CPUTIME_ID = 2;

const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const c_clock = struct {
    extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
};

extern "c" fn readdir(dirp: ?*anyopaque) ?*anyopaque;
extern "c" fn fdopendir(fd: c_int) ?*anyopaque;
extern "c" fn closedir(dirp: ?*anyopaque) c_int;

const DIRENT = extern struct {
    d_ino: c.ino_t,
    d_off: c.off_t,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8,
};

const POSIX_FADV_SEQUENTIAL = 2;

const c_io = struct {
    extern "c" fn signal(sig: c_int, handler: *anyopaque) *anyopaque;
};

var interrupted: bool = false;

fn setSignalHandler() void {
    const handler_fn = struct {
        fn f(sig: c_int) void {
            _ = sig;
            interrupted = true;
        }
    }.f;
    _ = c_io.signal(2, @as(*anyopaque, @ptrFromInt(@intFromPtr(&handler_fn))));
}

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("fnmatch.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
    @cInclude("dirent.h");
});

const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;
const DT_LNK: u8 = 10;
const DT_BLK: u8 = 6;
const DT_CHR: u8 = 2;
const DT_FIFO: u8 = 1;
const DT_SOCK: u8 = 12;

const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const AtomicU64 = std.atomic.Value(u64);

const WalkMode = enum {
    bfs,
    dfs,
};

const Options = struct {
    name_pat: ?[]u8 = null,
    path_pat: ?[]u8 = null,
    exclude_pat: ?[]u8 = null,
    exclude_path_pat: ?[]u8 = null,
    prune_pat: ?[]u8 = null,
    prune_path_pat: ?[]u8 = null,
    mindepth: i32 = 0,
    maxdepth: i32 = std.math.maxInt(i32),
    type_filter: u8 = 0,
    uid: c.uid_t = 0,
    gid: c.gid_t = 0,
    inode: c.ino_t = 0,
    perm: c.mode_t = 0,
    uid_set: bool = false,
    gid_set: bool = false,
    inode_set: bool = false,
    perm_set: bool = false,
    newer: Timespec = std.mem.zeroes(Timespec),
    newer_set: bool = false,
    threads: i32 = 0,
    print0: bool = false,
    quiet_errors: bool = false,
    stats: bool = false,
    timing: bool = false,
    xdev: bool = false,
    skip_vfs: bool = false,
    noprint: bool = false,
    hidden: bool = false,
    walk_mode: WalkMode = .bfs,
};

const Timing = struct {
    real_start: Timespec,
    real_end: Timespec,
    cpu_start: Timespec,
    cpu_end: Timespec,

    fn captureStart() Timing {
        var t: Timing = undefined;
        _ = c_clock.clock_gettime(CLOCK_MONOTONIC, &t.real_start);
        _ = c_clock.clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t.cpu_start);
        t.real_end = std.mem.zeroes(Timespec);
        t.cpu_end = std.mem.zeroes(Timespec);
        return t;
    }

    fn captureEnd(self: *Timing) void {
        _ = c_clock.clock_gettime(CLOCK_MONOTONIC, &self.real_end);
        _ = c_clock.clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &self.cpu_end);
    }

    fn print(self: *const Timing) void {
        const real: u64 = @intCast(timespecDiff(self.real_end, self.real_start));
        const cpu: u64 = @intCast(timespecDiff(self.cpu_end, self.cpu_start));
        const pct = if (real > 0) @as(f64, @floatFromInt(cpu)) / @as(f64, @floatFromInt(real)) * 100.0 else 0.0;
        std.debug.print("real\t{d}.{d:03}s\ncpu\t{d}.{d:03}s\n%\t{d:.1}\n", .{
            real / 1_000_000_000, (real % 1_000_000_000) / 1_000_000,
            cpu / 1_000_000_000,  (cpu % 1_000_000_000) / 1_000_000,
            pct,
        });
    }
};

fn timespecDiff(a: Timespec, b: Timespec) i64 {
    return @as(i64, a.tv_sec - b.tv_sec) * 1_000_000_000 + @as(i64, a.tv_nsec - b.tv_nsec);
}

const Task = struct {
    pathz: []u8,
    depth: i32,
    root_dev: c.dev_t,
    next: ?*Task = null,
    prev: ?*Task = null,
};

const TaskQueue = struct {
    head: ?*Task = null,
    tail: ?*Task = null,
    queued: usize = 0,
    pending_dirs: usize = 0,
    done: bool = false,
    mu: Mutex = .{},
    cv: Condition = .{},

    fn push(self: *TaskQueue, task: *Task) void {
        task.next = null;
        task.prev = null;
        self.mu.lock();
        defer self.mu.unlock();
        task.prev = self.tail;
        if (self.tail) |tail| {
            tail.next = task;
        } else {
            self.head = task;
        }
        self.tail = task;
        self.queued += 1;
        self.pending_dirs += 1;
        self.cv.signal();
    }

    fn pop(self: *TaskQueue, mode: WalkMode) ?*Task {
        self.mu.lock();
        defer self.mu.unlock();
        while (!self.done and self.head == null) {
            self.cv.wait(&self.mu);
        }
        if (self.head == null) return null;

        var task: *Task = undefined;
        switch (mode) {
            .bfs => {
                task = self.head.?;
                self.head = task.next;
                if (self.head) |head| head.prev = null else self.tail = null;
            },
            .dfs => {
                task = self.tail.?;
                self.tail = task.prev;
                if (self.tail) |tail| tail.next = null else self.head = null;
            },
        }
        task.next = null;
        task.prev = null;
        self.queued -= 1;
        return task;
    }

    fn taskDone(self: *TaskQueue) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.pending_dirs > 0) self.pending_dirs -= 1;
        if (self.pending_dirs == 0 and self.queued == 0) {
            self.done = true;
            self.cv.broadcast();
        }
    }

    fn finalizeIfIdle(self: *TaskQueue) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.pending_dirs == 0 and self.queued == 0) {
            self.done = true;
            self.cv.broadcast();
        }
    }

    fn abort(self: *TaskQueue) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.done = true;
        self.cv.broadcast();
    }
};

const Output = struct {
    mu: Mutex = .{},
    use_lock: bool = false,
};

const Stats = struct {
    files_seen: AtomicU64 = AtomicU64.init(0),
    dirs_seen: AtomicU64 = AtomicU64.init(0),
    links_seen: AtomicU64 = AtomicU64.init(0),
    others_seen: AtomicU64 = AtomicU64.init(0),
    matched: AtomicU64 = AtomicU64.init(0),
    errors: AtomicU64 = AtomicU64.init(0),
    dirs_enqueued: AtomicU64 = AtomicU64.init(0),
};

const WorkerCtx = struct {
    allocator: Allocator,
    opt: *const Options,
    queue: *TaskQueue,
    out: *Output,
    stats: *Stats,
    progname: []const u8,
};

const VERSION = "1.0.0";

fn usage(progname: []const u8) void {
    std.debug.print(
        "usage: {s} [path ...] [options]\n\n" ++
            "raid: low-level rigorous recursive file traversal utility\n\n" ++
            "options:\n" ++
            "  -name PAT             basename glob filter\n" ++
            "  -path PAT             full-path glob filter\n" ++
            "  -exclude PAT          exclude basenames from matching\n" ++
            "  -exclude-path PAT     exclude full paths from matching\n" ++
            "  -prune PAT            prune basenames from descent\n" ++
            "  -prune-path PAT       prune full paths from descent\n" ++
            "  -type C               file type: f d l b c p s\n" ++
            "  -uid N                exact uid filter\n" ++
            "  -gid N                exact gid filter\n" ++
            "  -inode N              exact inode filter\n" ++
            "  -perm MODE            exact octal permission match\n" ++
            "  -newer PATH           only match files newer than PATH\n" ++
            "  -mindepth N           minimum depth to match\n" ++
            "  -maxdepth N           maximum depth to descend or match\n" ++
            "  -xdev                 do not cross filesystem boundaries\n" ++
            "  -one-file-system      alias for -xdev\n" ++
            "  -skip-vfs             prune /proc /sys /dev /run when traversing /\n" ++
            "  -H, --hidden          include hidden files\n" ++
            "  -walk bfs|dfs         traversal queue mode\n" ++
            "  -j N                  worker threads (default: all cores)\n" ++
            "  -0, -print0           NUL-delimited output\n" ++
            "  -noprint              do not emit matches\n" ++
            "  -q, -quiet            suppress traversal errors\n" ++
            "  -stats                print counters to stderr\n" ++
            "  -time                 print timing info\n" ++
            "  -h, --help            show this help\n" ++
            "  -V, --version         show version\n",
        .{progname},
    );
}

fn parseInt(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, s, 10);
}

fn parseMode(s: []const u8) !c.mode_t {
    return @as(c.mode_t, @intCast(try std.fmt.parseInt(u32, s, 8)));
}

fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn isVfsPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/proc") or
        std.mem.eql(u8, path, "/sys") or
        std.mem.eql(u8, path, "/dev") or
        std.mem.eql(u8, path, "/run") or
        std.mem.startsWith(u8, path, "/proc/") or
        std.mem.startsWith(u8, path, "/sys/") or
        std.mem.startsWith(u8, path, "/dev/") or
        std.mem.startsWith(u8, path, "/run/");
}

fn fileTypeCharFromMode(mode: c.mode_t) u8 {
    if ((mode & c.S_IFMT) == c.S_IFREG) return 'f';
    if ((mode & c.S_IFMT) == c.S_IFDIR) return 'd';
    if ((mode & c.S_IFMT) == c.S_IFLNK) return 'l';
    if ((mode & c.S_IFMT) == c.S_IFBLK) return 'b';
    if ((mode & c.S_IFMT) == c.S_IFCHR) return 'c';
    if ((mode & c.S_IFMT) == c.S_IFIFO) return 'p';
    if ((mode & c.S_IFMT) == c.S_IFSOCK) return 's';
    return '?';
}

fn direntTypeChar(dtype: u8) u8 {
    return switch (dtype) {
        c.DT_REG => 'f',
        c.DT_DIR => 'd',
        c.DT_LNK => 'l',
        c.DT_BLK => 'b',
        c.DT_CHR => 'c',
        c.DT_FIFO => 'p',
        c.DT_SOCK => 's',
        else => '?',
    };
}

fn noteType(stats: *Stats, t: u8) void {
    switch (t) {
        'f' => _ = stats.files_seen.fetchAdd(1, .monotonic),
        'd' => _ = stats.dirs_seen.fetchAdd(1, .monotonic),
        'l' => _ = stats.links_seen.fetchAdd(1, .monotonic),
        else => _ = stats.others_seen.fetchAdd(1, .monotonic),
    }
}

fn reportError(ctx: *const WorkerCtx, path: []const u8) void { // bullshit ass function
    _ = ctx.stats.errors.fetchAdd(1, .monotonic);
    if (!ctx.opt.quiet_errors) {
        std.debug.print("{s}: {s}: error\n", .{ ctx.progname, path });
    }
}

fn noteMatch(stats: *Stats) void {
    _ = stats.matched.fetchAdd(1, .monotonic);
}

fn outputPath(out: *Output, opt: *const Options, path: []const u8) void {
    if (out.use_lock) out.mu.lock();
    defer if (out.use_lock) out.mu.unlock();
    _ = c.fwrite(path.ptr, 1, path.len, c.stdout);
    _ = c.fputc(if (opt.print0) 0 else '\n', c.stdout);
}

fn timespecGt(a: Timespec, b: Timespec) bool {
    if (a.tv_sec > b.tv_sec) return true;
    if (a.tv_sec < b.tv_sec) return false;
    return a.tv_nsec > b.tv_nsec;
}

fn filtersRequireStat(opt: *const Options) bool {
    return opt.uid_set or opt.gid_set or opt.inode_set or opt.perm_set or opt.newer_set;
}

fn baseNameZ(pathz: []u8) [*:0]const u8 {
    const p = pathSlice(pathz);
    const b = baseName(p);
    const off = p.len - b.len;
    return @ptrCast(pathz.ptr + off);
}

fn fnmatchOk(patz: ?[]const u8, zstr: [*:0]const u8) bool {
    if (patz == null) return true;
    const pptr: [*:0]const u8 = @ptrCast(patz.?.ptr);
    return c.fnmatch(pptr, zstr, 0) == 0;
}

fn matchesFiltersZ(opt: *const Options, pathz: []u8, st: ?*const c.struct_stat, type_char: u8, depth: i32) bool {
    if (depth < opt.mindepth or depth > opt.maxdepth) return false;

    if (opt.type_filter != 0 and type_char != opt.type_filter) return false;

    const path_ptr: [*:0]const u8 = @ptrCast(pathz.ptr);
    const base_ptr = baseNameZ(pathz);

    if (opt.exclude_pat != null and fnmatchOk(opt.exclude_pat, base_ptr)) return false;
    if (opt.exclude_path_pat != null and fnmatchOk(opt.exclude_path_pat, path_ptr)) return false;

    if (opt.name_pat != null and !fnmatchOk(opt.name_pat, base_ptr)) return false;
    if (opt.path_pat != null and !fnmatchOk(opt.path_pat, path_ptr)) return false;

    if (opt.uid_set or opt.gid_set or opt.inode_set or opt.perm_set or opt.newer_set) {
        if (st == null) return false;
        const s = st.?;
        if (opt.uid_set and s.st_uid != opt.uid) return false;
        if (opt.gid_set and s.st_gid != opt.gid) return false;
        if (opt.inode_set and s.st_ino != opt.inode) return false;
        if (opt.perm_set and ((s.st_mode & 0o7777) != opt.perm)) return false;
        if (opt.newer_set) {
            const st_mtim = Timespec{ .tv_sec = s.st_mtim.tv_sec, .tv_nsec = s.st_mtim.tv_nsec };
            if (!timespecGt(st_mtim, opt.newer)) return false;
        }
    }

    return true;
}

fn shouldPruneZ(opt: *const Options, pathz: []u8) bool {
    const path = pathSlice(pathz);
    if (opt.skip_vfs and isVfsPath(path)) return true;
    const path_ptr: [*:0]const u8 = @ptrCast(pathz.ptr);
    const base_ptr = baseNameZ(pathz);
    if (opt.prune_pat != null and fnmatchOk(opt.prune_pat, base_ptr)) return true;
    if (opt.prune_path_pat != null and fnmatchOk(opt.prune_path_pat, path_ptr)) return true;
    return false;
}

fn dupeZ(allocator: Allocator, s: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, s.len + 1);
    std.mem.copyForwards(u8, out[0..s.len], s);
    out[s.len] = 0;
    return out;
}

fn joinPathZ(allocator: Allocator, dir: []const u8, name: [*]const u8, name_len: usize) ![]u8 {
    const need_slash = dir.len > 0 and dir[dir.len - 1] != '/';
    const total = dir.len + @as(usize, if (need_slash) 1 else 0) + name_len;
    var out = try allocator.alloc(u8, total + 1);
    var off: usize = 0;
    std.mem.copyForwards(u8, out[off .. off + dir.len], dir);
    off += dir.len;
    if (need_slash) {
        out[off] = '/';
        off += 1;
    }
    std.mem.copyForwards(u8, out[off .. off + name_len], name[0..name_len]);
    out[total] = 0;
    return out;
}

fn pathSlice(pathz: []u8) []const u8 {
    return pathz[0 .. pathz.len - 1];
}

fn needStatForEntry(opt: *const Options, type_char: u8) bool {
    if (type_char == '?') return true;
    if (filtersRequireStat(opt)) return true;
    if (opt.xdev and type_char == 'd') return true;
    return false;
}

fn processDirectory(ctx: *WorkerCtx, task: *Task) void {
    const pathz = task.pathz;
    const path = pathSlice(pathz);
    const zpath: [*:0]const u8 = @ptrCast(pathz.ptr);
    const fd = c.open(zpath, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) {
        reportError(ctx, path);
        return;
    }

    const hidden = ctx.opt.hidden;
    const skip_vfs = ctx.opt.skip_vfs;
    const prune_pat = ctx.opt.prune_pat;
    const prune_path_pat = ctx.opt.prune_path_pat;
    const need_stat = filtersRequireStat(ctx.opt) or ctx.opt.xdev;

    const dirp = fdopendir(fd);
    if (dirp == null) {
        _ = c.close(fd);
        return;
    }
    defer _ = closedir(dirp);

    while (true) {
        const de_raw = readdir(dirp);
        if (de_raw == null) break;

        const de = @as(*const DIRENT, @ptrCast(@alignCast(de_raw.?)));
        const name_ptr: [*]const u8 = @ptrCast(&de.d_name);
        var name_len: usize = 0;
        while (name_ptr[name_len] != 0) name_len += 1;

        if (name_len == 1 and name_ptr[0] == '.') continue;
        if (name_len == 2 and name_ptr[0] == '.' and name_ptr[1] == '.') continue;
        if (!hidden and name_len > 0 and name_ptr[0] == '.') continue;

        const child_pathz = joinPathZ(ctx.allocator, path, name_ptr, name_len) catch continue;
        const child_path = pathSlice(child_pathz);
        const child_depth = task.depth + 1;

        if ((skip_vfs and isVfsPath(child_path)) or
            (prune_pat != null and fnmatchOk(prune_pat, baseNameZ(child_pathz))) or
            (prune_path_pat != null and fnmatchOk(prune_path_pat, @ptrCast(child_pathz.ptr))))
        {
            ctx.allocator.free(child_pathz);
            continue;
        }

        var type_char: u8 = switch (de.d_type) {
            DT_DIR => 'd',
            DT_REG => 'f',
            DT_LNK => 'l',
            DT_BLK => 'b',
            DT_CHR => 'c',
            DT_FIFO => 'p',
            DT_SOCK => 's',
            else => '?',
        };

        var st: c.struct_stat = undefined;
        var have_stat = false;

        if (type_char == '?' or need_stat) {
            if (c.fstatat(fd, @as([*:0]const u8, @ptrFromInt(@intFromPtr(name_ptr))), &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
                reportError(ctx, child_path);
                ctx.allocator.free(child_pathz);
                continue;
            }
            have_stat = true;
            if (type_char == '?') type_char = fileTypeCharFromMode(st.st_mode);
        }

        noteType(ctx.stats, type_char);

        if (matchesFiltersZ(ctx.opt, child_pathz, if (have_stat) &st else null, type_char, child_depth)) {
            noteMatch(ctx.stats);
            if (!ctx.opt.noprint) outputPath(ctx.out, ctx.opt, child_path);
        }

        if (type_char == 'd' and child_depth < ctx.opt.maxdepth) {
            var same_fs_ok = true;
            if (ctx.opt.xdev) {
                if (!have_stat) {
                    if (c.fstatat(fd, @as([*:0]const u8, @ptrFromInt(@intFromPtr(name_ptr))), &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
                        reportError(ctx, child_path);
                        ctx.allocator.free(child_pathz);
                        continue;
                    }
                }
                same_fs_ok = st.st_dev == task.root_dev;
            }
            if (same_fs_ok) {
                const next = ctx.allocator.create(Task) catch {
                    reportError(ctx, child_path);
                    ctx.allocator.free(child_pathz);
                    continue;
                };
                next.* = .{
                    .pathz = child_pathz,
                    .depth = child_depth,
                    .root_dev = task.root_dev,
                    .next = null,
                    .prev = null,
                };
                ctx.queue.push(next);
                _ = ctx.stats.dirs_enqueued.fetchAdd(1, .monotonic);
                continue;
            }
        }

        ctx.allocator.free(child_pathz);
    }
}

fn workerMain(ctx: *WorkerCtx) void {
    while (true) {
        const task = ctx.queue.pop(ctx.opt.walk_mode) orelse break;
        processDirectory(ctx, task);
        ctx.allocator.free(task.pathz);
        ctx.allocator.destroy(task);
        ctx.queue.taskDone();
    }
}

fn autodetectThreads() i32 {
    const n = c.sysconf(c._SC_NPROCESSORS_ONLN);
    if (n < 1) return 1;
    if (n > 64) return 64;
    return @as(i32, @intCast(n));
}

pub fn main() !void {
    setSignalHandler();
    const allocator = std.heap.c_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 0) return;
    const progname = args[0];

    var opt = Options{};
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try roots.append(allocator, args[i]);
            break;
        } else if (std.mem.eql(u8, arg, "-name")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}: missing argument for -name\n", .{progname});
                std.process.exit(2);
            }
            opt.name_pat = try dupeZ(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-path")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}: missing argument for -path\n", .{progname});
                std.process.exit(2);
            }
            opt.path_pat = try dupeZ(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-exclude")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}: missing argument for -exclude\n", .{progname});
                std.process.exit(2);
            }
            opt.exclude_pat = try dupeZ(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-exclude-path")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}: missing argument for -exclude-path\n", .{progname});
                std.process.exit(2);
            }
            opt.exclude_path_pat = try dupeZ(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-prune")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}: missing argument for -prune\n", .{progname});
                std.process.exit(2);
            }
            opt.prune_pat = try dupeZ(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-prune-path")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}: missing argument for -prune-path\n", .{progname});
                std.process.exit(2);
            }
            opt.prune_path_pat = try dupeZ(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "-type")) {
            i += 1;
            if (i >= args.len or args[i].len != 1 or std.mem.indexOfScalar(u8, "fdlbcps", args[i][0]) == null) {
                std.debug.print("{s}: invalid -type\n", .{progname});
                std.process.exit(2);
            }
            opt.type_filter = args[i][0];
        } else if (std.mem.eql(u8, arg, "-uid")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.uid = try parseInt(c.uid_t, args[i]);
            opt.uid_set = true;
        } else if (std.mem.eql(u8, arg, "-gid")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.gid = try parseInt(c.gid_t, args[i]);
            opt.gid_set = true;
        } else if (std.mem.eql(u8, arg, "-inode")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.inode = try parseInt(c.ino_t, args[i]);
            opt.inode_set = true;
        } else if (std.mem.eql(u8, arg, "-perm")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.perm = try parseMode(args[i]);
            opt.perm_set = true;
        } else if (std.mem.eql(u8, arg, "-newer")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            const refz = try dupeZ(allocator, args[i]);
            defer allocator.free(refz);
            var st: c.struct_stat = undefined;
            const refptr: [*:0]const u8 = @ptrCast(refz.ptr);
            if (c.stat(refptr, &st) != 0) {
                std.debug.print("{s}: cannot stat reference path for -newer: {s}\n", .{ progname, args[i] });
                std.process.exit(2);
            }
            opt.newer = Timespec{
                .tv_sec = st.st_mtim.tv_sec,
                .tv_nsec = st.st_mtim.tv_nsec,
            };
            opt.newer_set = true;
        } else if (std.mem.eql(u8, arg, "-mindepth")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.mindepth = try parseInt(i32, args[i]);
            if (opt.mindepth < 0) std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "-maxdepth")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.maxdepth = try parseInt(i32, args[i]);
            if (opt.maxdepth < 0) std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "-j")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            opt.threads = try parseInt(i32, args[i]);
            if (opt.threads == 0) opt.threads = autodetectThreads();
            if (opt.threads < 1) opt.threads = 1;
        } else if (std.mem.eql(u8, arg, "-xdev") or std.mem.eql(u8, arg, "-one-file-system")) {
            opt.xdev = true;
        } else if (std.mem.eql(u8, arg, "-skip-vfs")) {
            opt.skip_vfs = true;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--hidden")) {
            opt.hidden = true;
        } else if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "-print0")) {
            opt.print0 = true;
        } else if (std.mem.eql(u8, arg, "-noprint")) {
            opt.noprint = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "-quiet")) {
            opt.quiet_errors = true;
        } else if (std.mem.eql(u8, arg, "-stats")) {
            opt.stats = true;
        } else if (std.mem.eql(u8, arg, "-time")) {
            opt.timing = true;
        } else if (std.mem.eql(u8, arg, "-walk")) {
            i += 1;
            if (i >= args.len) std.process.exit(2);
            if (std.ascii.eqlIgnoreCase(args[i], "bfs")) opt.walk_mode = .bfs else if (std.ascii.eqlIgnoreCase(args[i], "dfs")) opt.walk_mode = .dfs else std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage(progname);
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("raid version {s}\n", .{VERSION});
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("{s}: unsupported option: {s}\n", .{ progname, arg });
            usage(progname);
            std.process.exit(2);
        } else {
            try roots.append(allocator, arg);
        }
    }

    if (roots.items.len == 0) try roots.append(allocator, ".");
    if (opt.mindepth > opt.maxdepth) std.process.exit(2);
    if (opt.threads == 0) opt.threads = autodetectThreads();

    _ = c.setvbuf(c.stdout, null, c._IOFBF, 1024 * 1024);

    var queue = TaskQueue{};
    var out = Output{ .use_lock = opt.threads > 1 };
    var stats = Stats{};
    var timing: Timing = undefined;
    if (opt.timing) timing = Timing.captureStart();
    var ctx = WorkerCtx{
        .allocator = allocator,
        .opt = &opt,
        .queue = &queue,
        .out = &out,
        .stats = &stats,
        .progname = progname,
    };

    var exit_code: u8 = 0;

    for (roots.items) |root| {
        if (opt.skip_vfs and isVfsPath(root)) continue;

        const rootz = try dupeZ(allocator, root);
        if (shouldPruneZ(&opt, rootz)) {
            allocator.free(rootz);
            continue;
        }
        const rootptr: [*:0]const u8 = @ptrCast(rootz.ptr);
        var st: c.struct_stat = undefined;
        if (c.lstat(rootptr, &st) != 0) {
            reportError(&ctx, root);
            allocator.free(rootz);
            exit_code = 1;
            continue;
        }

        const type_char = fileTypeCharFromMode(st.st_mode);
        noteType(&stats, type_char);

        if (matchesFiltersZ(&opt, rootz, &st, type_char, 0)) {
            noteMatch(&stats);
            if (!opt.noprint) outputPath(&out, &opt, root);
        }

        if (type_char == 'd' and opt.maxdepth > 0) {
            const task = try allocator.create(Task);
            task.* = .{
                .pathz = rootz,
                .depth = 0,
                .root_dev = st.st_dev,
                .next = null,
                .prev = null,
            };
            queue.push(task);
            _ = stats.dirs_enqueued.fetchAdd(1, .monotonic);
        } else {
            allocator.free(rootz);
        }
    }

    queue.finalizeIfIdle();

    if (opt.threads <= 1) {
        workerMain(&ctx);
    } else {
        const tcount: usize = @intCast(opt.threads);
        var threads = try allocator.alloc(std.Thread, tcount);
        defer allocator.free(threads);
        var created: usize = 0;
        while (created < tcount) : (created += 1) {
            threads[created] = std.Thread.spawn(.{}, workerMain, .{&ctx}) catch {
                queue.abort();
                var j: usize = 0;
                while (j < created) : (j += 1) threads[j].join();
                std.debug.print("{s}: failed to spawn thread\n", .{progname});
                std.process.exit(2);
            };
        }
        for (threads[0..created]) |th| th.join();
    }

    if (opt.timing) timing.captureEnd();

    _ = c.fflush(c.stdout);

    if (stats.errors.load(.monotonic) != 0) exit_code = 1;

    if (opt.stats) {
        std.debug.print(
            "matched={} files={} dirs={} links={} others={} queued_dirs={} errors={} threads={} walk={s}\n",
            .{
                stats.matched.load(.monotonic),
                stats.files_seen.load(.monotonic),
                stats.dirs_seen.load(.monotonic),
                stats.links_seen.load(.monotonic),
                stats.others_seen.load(.monotonic),
                stats.dirs_enqueued.load(.monotonic),
                stats.errors.load(.monotonic),
                opt.threads,
                if (opt.walk_mode == .bfs) "bfs" else "dfs",
            },
        );
    }

    if (opt.timing) timing.print();

    if (interrupted) {
        _ = c.fflush(c.stdout);
        std.process.exit(130);
    }
    if (exit_code != 0) std.process.exit(exit_code);
}
