const std = @import("std");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/types.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);
const AtomicU64 = std.atomic.Value(u64);
const Mutex = std.Io.Mutex;
const Condition = std.Io.Condition;

const VERSION = "2.0.0";
const READ_BUFFER_SIZE = 128 * 1024;
const OUTPUT_FLUSH_THRESHOLD = 128 * 1024;
const TASK_BATCH_SIZE = 64;

var global_io: std.Io = undefined;
var signal_seen: c.sig_atomic_t = 0;

const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

const LinuxDirent64 = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [0]u8,
};

const WalkMode = enum {
    bfs,
    dfs,
};

const StorageMode = enum {
    auto,
    hdd,
    ssd,
};

const CaseMode = enum {
    smart,
    sensitive,
    insensitive,
};

const ColorMode = enum {
    auto,
    always,
    never,
};

const Options = struct {
    pattern: ?[]const u8 = null,
    glob: bool = false,
    full_path: bool = false,
    case_mode: CaseMode = .smart,

    extensions: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    prunes: []const []const u8 = &.{},

    min_depth: i32 = 0,
    max_depth: i32 = std.math.maxInt(i32),
    type_mask: u16 = 0,
    executable_only: bool = false,
    empty_only: bool = false,

    uid: c.uid_t = 0,
    gid: c.gid_t = 0,
    inode: c.ino_t = 0,
    perm: c.mode_t = 0,
    uid_set: bool = false,
    gid_set: bool = false,
    inode_set: bool = false,
    perm_set: bool = false,

    size_min: ?u64 = null,
    size_max: ?u64 = null,
    newer_than: ?Timespec = null,
    age_max_ns: ?u64 = null,
    age_min_ns: ?u64 = null,

    threads: i32 = 0,
    hidden: bool = false,
    xdev: bool = false,
    skip_vfs: bool = false,
    strip_dot_slash: bool = true,
    absolute: bool = false,

    print0: bool = false,
    noprint: bool = false,
    quiet_errors: bool = false,
    stats: bool = false,
    timing: bool = false,
    long: bool = false,
    human_readable: bool = false,
    classify: bool = false,
    limit: u64 = 0,

    color_mode: ColorMode = .auto,
    use_color: bool = false,

    walk_mode: WalkMode = .bfs,
    walk_set: bool = false,
    storage_mode: StorageMode = .auto,
};

const Timing = struct {
    real_start: Timespec,
    real_end: Timespec,
    cpu_start: Timespec,
    cpu_end: Timespec,

    fn start() Timing {
        var out: Timing = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, @ptrCast(&out.real_start));
        _ = c.clock_gettime(c.CLOCK_PROCESS_CPUTIME_ID, @ptrCast(&out.cpu_start));
        out.real_end = .{ .tv_sec = 0, .tv_nsec = 0 };
        out.cpu_end = .{ .tv_sec = 0, .tv_nsec = 0 };
        return out;
    }

    fn stop(self: *Timing) void {
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, @ptrCast(&self.real_end));
        _ = c.clock_gettime(c.CLOCK_PROCESS_CPUTIME_ID, @ptrCast(&self.cpu_end));
    }

    fn print(self: *const Timing) void {
        const real_ns = timespecDiff(self.real_end, self.real_start);
        const cpu_ns = timespecDiff(self.cpu_end, self.cpu_start);
        const real_u: u64 = if (real_ns > 0) @intCast(real_ns) else 0;
        const cpu_u: u64 = if (cpu_ns > 0) @intCast(cpu_ns) else 0;
        const pct = if (real_u > 0)
            @as(f64, @floatFromInt(cpu_u)) / @as(f64, @floatFromInt(real_u)) * 100.0
        else
            0.0;

        std.debug.print(
            "real\t{d}.{d:03}s\ncpu\t{d}.{d:03}s\nCPU\t{d:.1}%\n",
            .{
                real_u / 1_000_000_000,
                (real_u % 1_000_000_000) / 1_000_000,
                cpu_u / 1_000_000_000,
                (cpu_u % 1_000_000_000) / 1_000_000,
                pct,
            },
        );
    }
};

const Task = struct {
    pathz: []u8,
    depth: i32,
    root_dev: c.dev_t,
    next: ?*Task = null,
    prev: ?*Task = null,
};

const TaskBatch = struct {
    first: ?*Task = null,
    last: ?*Task = null,
    count: usize = 0,

    fn append(self: *TaskBatch, task: *Task) void {
        task.next = null;
        task.prev = self.last;
        if (self.last) |last| {
            last.next = task;
        } else {
            self.first = task;
        }
        self.last = task;
        self.count += 1;
    }

    fn reset(self: *TaskBatch) void {
        self.* = .{};
    }
};

const TaskQueue = struct {
    head: ?*Task = null,
    tail: ?*Task = null,
    queued: usize = 0,
    pending_dirs: usize = 0,
    done: bool = false,
    mu: Mutex = .init,
    cv: Condition = .init,

    fn pushBatch(self: *TaskQueue, batch: *TaskBatch) bool {
        if (batch.count == 0) return true;

        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);

        if (self.done) return false;

        if (self.tail) |tail| {
            tail.next = batch.first;
            batch.first.?.prev = tail;
        } else {
            self.head = batch.first;
        }
        self.tail = batch.last;
        self.queued += batch.count;
        self.pending_dirs += batch.count;

        if (batch.count == 1) {
            self.cv.signal(global_io);
        } else {
            self.cv.broadcast(global_io);
        }
        return true;
    }

    fn pop(self: *TaskQueue, mode: WalkMode) ?*Task {
        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);

        while (!self.done and self.head == null) {
            self.cv.wait(global_io, &self.mu) catch unreachable;
        }

        if (self.done or self.head == null) return null;

        const task: *Task = switch (mode) {
            .bfs => blk: {
                const item = self.head.?;
                self.head = item.next;
                if (self.head) |head| {
                    head.prev = null;
                } else {
                    self.tail = null;
                }
                break :blk item;
            },
            .dfs => blk: {
                const item = self.tail.?;
                self.tail = item.prev;
                if (self.tail) |tail| {
                    tail.next = null;
                } else {
                    self.head = null;
                }
                break :blk item;
            },
        };

        task.next = null;
        task.prev = null;
        self.queued -= 1;
        return task;
    }

    fn taskDone(self: *TaskQueue) void {
        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);

        if (self.pending_dirs > 0) self.pending_dirs -= 1;
        if (self.pending_dirs == 0 and self.queued == 0) {
            self.done = true;
            self.cv.broadcast(global_io);
        }
    }

    fn finalizeIfIdle(self: *TaskQueue) void {
        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);

        if (self.pending_dirs == 0 and self.queued == 0) {
            self.done = true;
            self.cv.broadcast(global_io);
        }
    }

    fn abort(self: *TaskQueue) void {
        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);
        self.done = true;
        self.cv.broadcast(global_io);
    }

    fn drain(self: *TaskQueue, allocator: Allocator) void {
        var current = self.head;
        while (current) |task| {
            const next = task.next;
            allocator.free(task.pathz);
            allocator.destroy(task);
            current = next;
        }
        self.head = null;
        self.tail = null;
        self.queued = 0;
        self.pending_dirs = 0;
    }
};

const Output = struct {
    mu: Mutex = .init,
    failed: AtomicBool = AtomicBool.init(false),

    fn write(self: *Output, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        if (self.failed.load(.acquire)) return false;

        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);

        if (self.failed.load(.monotonic)) return false;
        const written = c.fwrite(bytes.ptr, 1, bytes.len, c.stdout);
        if (written != bytes.len) {
            self.failed.store(true, .release);
            return false;
        }
        return true;
    }

    fn reportErrno(self: *Output, progname: []const u8, operation: []const u8, path: []const u8, err_no: c_int) void {
        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);

        const message_ptr = c.strerror(err_no);
        const message = if (message_ptr == null) "unknown error" else std.mem.span(message_ptr);
        std.debug.print("{s}: {s} '{s}': {s}\n", .{ progname, operation, path, message });
    }

    fn reportMessage(self: *Output, progname: []const u8, message: []const u8) void {
        self.mu.lock(global_io) catch unreachable;
        defer self.mu.unlock(global_io);
        std.debug.print("{s}: {s}\n", .{ progname, message });
    }
};

const Stats = struct {
    files_seen: AtomicU64 = AtomicU64.init(0),
    dirs_seen: AtomicU64 = AtomicU64.init(0),
    links_seen: AtomicU64 = AtomicU64.init(0),
    others_seen: AtomicU64 = AtomicU64.init(0),
    matched: AtomicU64 = AtomicU64.init(0),
    errors: AtomicU64 = AtomicU64.init(0),
    dirs_enqueued: AtomicU64 = AtomicU64.init(0),
    bytes_emitted: AtomicU64 = AtomicU64.init(0),
};

const WorkerCtx = struct {
    allocator: Allocator,
    opt: *const Options,
    queue: *TaskQueue,
    output: *Output,
    stats: *Stats,
    progname: []const u8,
    now: Timespec,
    fatal: *AtomicBool,
};

const WorkerLocal = struct {
    path_buf: std.ArrayList(u8) = .empty,
    out_buf: std.ArrayList(u8) = .empty,
    task_batch: TaskBatch = .{},

    fn init(self: *WorkerLocal, allocator: Allocator) !void {
        try self.path_buf.ensureTotalCapacity(allocator, 4096);
        try self.out_buf.ensureTotalCapacity(allocator, OUTPUT_FLUSH_THRESHOLD);
    }

    fn deinit(self: *WorkerLocal, allocator: Allocator) void {
        self.path_buf.deinit(allocator);
        self.out_buf.deinit(allocator);
    }
};

fn errnoLocation() *c_int {
    return c.__errno_location();
}

fn currentErrno() c_int {
    return errnoLocation().*;
}

fn onSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    signal_seen = 1;
}

const SignalHandler = *const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: SignalHandler) SignalHandler;

fn installSignalHandlers() void {
    _ = signal(c.SIGINT, &onSignal);
    _ = signal(c.SIGTERM, &onSignal);
}

fn interrupted() bool {
    return signal_seen != 0;
}

fn timespecDiff(a: Timespec, b: Timespec) i64 {
    return (a.tv_sec - b.tv_sec) * 1_000_000_000 + (a.tv_nsec - b.tv_nsec);
}

fn pathSlice(pathz: []u8) []const u8 {
    return pathz[0 .. pathz.len - 1];
}

fn dupeZ(allocator: Allocator, input: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, input.len + 1);
    std.mem.copyForwards(u8, out[0..input.len], input);
    out[input.len] = 0;
    return out;
}

fn normalizeRoot(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn buildChildPath(local: *WorkerLocal, allocator: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    const needs_slash = dir.len > 0 and dir[dir.len - 1] != '/';
    const total = dir.len + @as(usize, if (needs_slash) 1 else 0) + name.len;
    try local.path_buf.ensureTotalCapacity(allocator, total + 1);
    local.path_buf.items.len = total + 1;

    var offset: usize = 0;
    std.mem.copyForwards(u8, local.path_buf.items[offset .. offset + dir.len], dir);
    offset += dir.len;
    if (needs_slash) {
        local.path_buf.items[offset] = '/';
        offset += 1;
    }
    std.mem.copyForwards(u8, local.path_buf.items[offset .. offset + name.len], name);
    local.path_buf.items[total] = 0;
    return local.path_buf.items[0..total];
}

fn visiblePath(opt: *const Options, path: []const u8) []const u8 {
    if (!opt.strip_dot_slash) return path;
    var out = path;
    while (std.mem.startsWith(u8, out, "./") and out.len > 2) out = out[2..];
    return out;
}

fn hasUpperAscii(text: []const u8) bool {
    for (text) |ch| {
        if (ch >= 'A' and ch <= 'Z') return true;
    }
    return false;
}

fn matchingIsInsensitive(opt: *const Options) bool {
    return switch (opt.case_mode) {
        .sensitive => false,
        .insensitive => true,
        .smart => if (opt.pattern) |pattern| !hasUpperAscii(pattern) else true,
    };
}

fn foldAscii(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + ('a' - 'A') else ch;
}

fn charsEqual(a: u8, b: u8, insensitive: bool) bool {
    return if (insensitive) foldAscii(a) == foldAscii(b) else a == b;
}

fn containsText(haystack: []const u8, needle: []const u8, insensitive: bool) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and charsEqual(haystack[i + j], needle[j], insensitive)) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

const ClassResult = struct {
    matched: bool,
    next_index: usize,
    valid: bool,
};

fn matchClass(pattern: []const u8, start: usize, ch: u8, insensitive: bool) ClassResult {
    var i = start + 1;
    if (i >= pattern.len) return .{ .matched = false, .next_index = start + 1, .valid = false };

    var negate = false;
    if (pattern[i] == '!' or pattern[i] == '^') {
        negate = true;
        i += 1;
    }

    var any = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) {
            return .{ .matched = if (negate) !any else any, .next_index = i + 1, .valid = true };
        }
        first = false;

        var lo = pattern[i];
        if (lo == '\\' and i + 1 < pattern.len) {
            i += 1;
            lo = pattern[i];
        }

        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            var hi = pattern[i + 2];
            if (insensitive) {
                lo = foldAscii(lo);
                hi = foldAscii(hi);
            }
            const value = if (insensitive) foldAscii(ch) else ch;
            if (value >= lo and value <= hi) any = true;
            i += 3;
        } else {
            if (charsEqual(lo, ch, insensitive)) any = true;
            i += 1;
        }
    }

    return .{ .matched = false, .next_index = start + 1, .valid = false };
}

fn tokenMatches(pattern: []const u8, index: usize, ch: u8, insensitive: bool) struct { ok: bool, next: usize } {
    if (index >= pattern.len) return .{ .ok = false, .next = index };
    const token = pattern[index];
    if (token == '?') return .{ .ok = true, .next = index + 1 };
    if (token == '[') {
        const class = matchClass(pattern, index, ch, insensitive);
        if (class.valid) return .{ .ok = class.matched, .next = class.next_index };
    }
    if (token == '\\' and index + 1 < pattern.len) {
        return .{ .ok = charsEqual(pattern[index + 1], ch, insensitive), .next = index + 2 };
    }
    return .{ .ok = charsEqual(token, ch, insensitive), .next = index + 1 };
}

fn globMatches(pattern: []const u8, text: []const u8, insensitive: bool) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pattern: ?usize = null;
    var star_text: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            while (pi < pattern.len and pattern[pi] == '*') pi += 1;
            star_pattern = pi;
            star_text = ti;
            if (pi == pattern.len) return true;
            continue;
        }

        const token = tokenMatches(pattern, pi, text[ti], insensitive);
        if (token.ok) {
            pi = token.next;
            ti += 1;
            continue;
        }

        if (star_pattern) |resume_index| {
            star_text += 1;
            if (star_text > text.len) return false;
            ti = star_text;
            pi = resume_index;
            continue;
        }
        return false;
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn anyGlobMatches(patterns: []const []const u8, basename: []const u8, path: []const u8, insensitive: bool) bool {
    for (patterns) |pattern| {
        if (globMatches(pattern, basename, insensitive) or globMatches(pattern, path, insensitive)) return true;
    }
    return false;
}

fn extensionMatches(opt: *const Options, basename: []const u8, insensitive: bool) bool {
    if (opt.extensions.len == 0) return true;
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return false;
    if (dot == 0 or dot + 1 >= basename.len) return false;
    const actual = basename[dot + 1 ..];

    for (opt.extensions) |raw_ext| {
        const ext = if (raw_ext.len > 0 and raw_ext[0] == '.') raw_ext[1..] else raw_ext;
        if (ext.len != actual.len) continue;
        var i: usize = 0;
        while (i < ext.len and charsEqual(ext[i], actual[i], insensitive)) : (i += 1) {}
        if (i == ext.len) return true;
    }
    return false;
}

fn patternMatches(opt: *const Options, basename: []const u8, path: []const u8) bool {
    const pattern = opt.pattern orelse return true;
    const target = if (opt.full_path) path else basename;
    const insensitive = matchingIsInsensitive(opt);
    return if (opt.glob)
        globMatches(pattern, target, insensitive)
    else
        containsText(target, pattern, insensitive);
}

fn typeBit(type_char: u8) u16 {
    return switch (type_char) {
        'f' => 1 << 0,
        'd' => 1 << 1,
        'l' => 1 << 2,
        'b' => 1 << 3,
        'c' => 1 << 4,
        'p' => 1 << 5,
        's' => 1 << 6,
        else => 1 << 7,
    };
}

fn typeCharFromMode(mode: c.mode_t) u8 {
    if ((mode & c.S_IFMT) == c.S_IFREG) return 'f';
    if ((mode & c.S_IFMT) == c.S_IFDIR) return 'd';
    if ((mode & c.S_IFMT) == c.S_IFLNK) return 'l';
    if ((mode & c.S_IFMT) == c.S_IFBLK) return 'b';
    if ((mode & c.S_IFMT) == c.S_IFCHR) return 'c';
    if ((mode & c.S_IFMT) == c.S_IFIFO) return 'p';
    if ((mode & c.S_IFMT) == c.S_IFSOCK) return 's';
    return '?';
}

fn typeCharFromDirent(dtype: u8) u8 {
    return switch (dtype) {
        8 => 'f',
        4 => 'd',
        10 => 'l',
        6 => 'b',
        2 => 'c',
        1 => 'p',
        12 => 's',
        else => '?',
    };
}

fn noteType(stats: *Stats, type_char: u8) void {
    switch (type_char) {
        'f' => _ = stats.files_seen.fetchAdd(1, .monotonic),
        'd' => _ = stats.dirs_seen.fetchAdd(1, .monotonic),
        'l' => _ = stats.links_seen.fetchAdd(1, .monotonic),
        else => _ = stats.others_seen.fetchAdd(1, .monotonic),
    }
}

fn needsStat(opt: *const Options, type_char: u8) bool {
    return type_char == '?' or
        opt.uid_set or
        opt.gid_set or
        opt.inode_set or
        opt.perm_set or
        opt.size_min != null or
        opt.size_max != null or
        opt.newer_than != null or
        opt.age_max_ns != null or
        opt.age_min_ns != null or
        opt.executable_only or
        opt.empty_only or
        opt.long or
        opt.classify or
        (opt.xdev and type_char == 'd');
}

fn timespecGreater(a: Timespec, b: Timespec) bool {
    return a.tv_sec > b.tv_sec or (a.tv_sec == b.tv_sec and a.tv_nsec > b.tv_nsec);
}

fn metadataMatches(opt: *const Options, st: ?*const c.struct_stat, now: Timespec) bool {
    const requires = opt.uid_set or opt.gid_set or opt.inode_set or opt.perm_set or
        opt.size_min != null or opt.size_max != null or opt.newer_than != null or
        opt.age_max_ns != null or opt.age_min_ns != null or opt.executable_only or
        opt.empty_only;
    if (!requires) return true;
    if (st == null) return false;

    const value = st.?;
    if (opt.uid_set and value.st_uid != opt.uid) return false;
    if (opt.gid_set and value.st_gid != opt.gid) return false;
    if (opt.inode_set and value.st_ino != opt.inode) return false;
    if (opt.perm_set and (value.st_mode & 0o7777) != opt.perm) return false;

    const size: u64 = if (value.st_size > 0) @intCast(value.st_size) else 0;
    if (opt.size_min) |minimum| if (size < minimum) return false;
    if (opt.size_max) |maximum| if (size > maximum) return false;

    const modified = Timespec{ .tv_sec = value.st_mtim.tv_sec, .tv_nsec = value.st_mtim.tv_nsec };
    if (opt.newer_than) |reference| {
        if (!timespecGreater(modified, reference)) return false;
    }

    const age_i = timespecDiff(now, modified);
    const age: u64 = if (age_i > 0) @intCast(age_i) else 0;
    if (opt.age_max_ns) |maximum_age| if (age > maximum_age) return false;
    if (opt.age_min_ns) |minimum_age| if (age < minimum_age) return false;

    if (opt.executable_only and (value.st_mode & 0o111) == 0) return false;
    if (opt.empty_only and value.st_size != 0) return false;
    return true;
}

fn entryMatches(opt: *const Options, basename: []const u8, path: []const u8, st: ?*const c.struct_stat, type_char: u8, depth: i32, now: Timespec) bool {
    if (depth < opt.min_depth or depth > opt.max_depth) return false;
    if (opt.type_mask != 0 and (opt.type_mask & typeBit(type_char)) == 0) return false;

    const insensitive = matchingIsInsensitive(opt);
    if (opt.excludes.len != 0 and anyGlobMatches(opt.excludes, basename, path, insensitive)) return false;
    if (!extensionMatches(opt, basename, insensitive)) return false;
    if (!patternMatches(opt, basename, path)) return false;
    if (!metadataMatches(opt, st, now)) return false;
    return true;
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

fn shouldPruneDirectory(opt: *const Options, basename: []const u8, path: []const u8) bool {
    if (opt.skip_vfs and isVfsPath(path)) return true;
    const insensitive = matchingIsInsensitive(opt);
    if (opt.excludes.len != 0 and anyGlobMatches(opt.excludes, basename, path, insensitive)) return true;
    if (opt.prunes.len == 0) return false;
    return anyGlobMatches(opt.prunes, basename, path, insensitive);
}

fn reserveMatch(ctx: *WorkerCtx) bool {
    if (ctx.opt.limit == 0) {
        if (ctx.opt.stats) _ = ctx.stats.matched.fetchAdd(1, .monotonic);
        return true;
    }

    const old = ctx.stats.matched.fetchAdd(1, .monotonic);
    if (old >= ctx.opt.limit) return false;
    if (old + 1 >= ctx.opt.limit) ctx.queue.abort();
    return true;
}

fn colorFor(type_char: u8, st: ?*const c.struct_stat) []const u8 {
    if (type_char == 'd') return "\x1b[1;34m";
    if (type_char == 'l') return "\x1b[1;36m";
    if (type_char == 'p') return "\x1b[33m";
    if (type_char == 's') return "\x1b[1;35m";
    if (type_char == 'b' or type_char == 'c') return "\x1b[1;33m";
    if (type_char == 'f' and st != null and (st.?.st_mode & 0o111) != 0) return "\x1b[1;32m";
    return "";
}

fn classifySuffix(type_char: u8, st: ?*const c.struct_stat) []const u8 {
    return switch (type_char) {
        'd' => "/",
        'l' => "@",
        'p' => "|",
        's' => "=",
        'f' => if (st != null and (st.?.st_mode & 0o111) != 0) "*" else "",
        else => "",
    };
}

fn modeString(mode: c.mode_t, type_char: u8) [10]u8 {
    var out: [10]u8 = .{ '-', '-', '-', '-', '-', '-', '-', '-', '-', '-' };
    out[0] = switch (type_char) {
        'd' => 'd',
        'l' => 'l',
        'b' => 'b',
        'c' => 'c',
        'p' => 'p',
        's' => 's',
        else => '-',
    };
    const bits = [_]c.mode_t{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
    const chars = "rwxrwxrwx";
    for (bits, 0..) |bit, i| {
        if ((mode & bit) != 0) out[i + 1] = chars[i];
    }
    return out;
}

fn humanSizeText(buffer: *[48]u8, size: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P" };
    var value = @as(f64, @floatFromInt(size));
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }

    return if (unit == 0)
        std.fmt.bufPrint(buffer, "{d}{s}", .{ size, units[unit] })
    else
        std.fmt.bufPrint(buffer, "{d:.1}{s}", .{ value, units[unit] });
}

fn timestampText(buffer: *[32]u8, seconds: i64) []const u8 {
    var timestamp: c.time_t = @intCast(seconds);
    var tm_value: c.struct_tm = undefined;
    if (c.localtime_r(&timestamp, &tm_value) == null) return "0000-00-00 00:00";
    const length = c.strftime(buffer, buffer.len, "%Y-%m-%d %H:%M", &tm_value);
    if (length == 0) return "0000-00-00 00:00";
    return buffer[0..length];
}

fn flushOutput(ctx: *WorkerCtx, local: *WorkerLocal) bool {
    if (local.out_buf.items.len == 0) return true;
    const bytes = local.out_buf.items;
    const ok = ctx.output.write(bytes);
    if (ok) _ = ctx.stats.bytes_emitted.fetchAdd(bytes.len, .monotonic);
    local.out_buf.clearRetainingCapacity();
    if (!ok) ctx.queue.abort();
    return ok;
}

fn appendOutput(ctx: *WorkerCtx, local: *WorkerLocal, bytes: []const u8) !void {
    try local.out_buf.appendSlice(ctx.allocator, bytes);
}

fn emitMatch(ctx: *WorkerCtx, local: *WorkerLocal, raw_path: []const u8, type_char: u8, st: ?*const c.struct_stat) !void {
    if (ctx.opt.noprint) return;
    if (local.out_buf.items.len >= OUTPUT_FLUSH_THRESHOLD and !flushOutput(ctx, local)) return error.OutputFailure;

    const path = visiblePath(ctx.opt, raw_path);
    if (ctx.opt.long) {
        const value = st orelse return error.MissingStat;
        const mode = modeString(value.st_mode, type_char);
        try appendOutput(ctx, local, &mode);
        try appendOutput(ctx, local, "  ");

        var size_buffer: [48]u8 = undefined;
        const size: u64 = if (value.st_size > 0) @intCast(value.st_size) else 0;
        const size_text = if (ctx.opt.human_readable)
            try humanSizeText(&size_buffer, size)
        else
            try std.fmt.bufPrint(&size_buffer, "{d}", .{value.st_size});
        try appendOutput(ctx, local, size_text);
        try appendOutput(ctx, local, "  ");

        var time_buffer: [32]u8 = undefined;
        try appendOutput(ctx, local, timestampText(&time_buffer, value.st_mtim.tv_sec));
        try appendOutput(ctx, local, "  ");
    }

    if (ctx.opt.use_color) {
        const color = colorFor(type_char, st);
        if (color.len != 0) try appendOutput(ctx, local, color);
        try appendOutput(ctx, local, path);
        if (ctx.opt.classify) try appendOutput(ctx, local, classifySuffix(type_char, st));
        if (color.len != 0) try appendOutput(ctx, local, "\x1b[0m");
    } else {
        try appendOutput(ctx, local, path);
        if (ctx.opt.classify) try appendOutput(ctx, local, classifySuffix(type_char, st));
    }

    try appendOutput(ctx, local, if (ctx.opt.print0) "\x00" else "\n");
    if (local.out_buf.items.len >= OUTPUT_FLUSH_THRESHOLD and !flushOutput(ctx, local)) return error.OutputFailure;
}

fn noteError(ctx: *WorkerCtx, operation: []const u8, path: []const u8, err_no: c_int) void {
    _ = ctx.stats.errors.fetchAdd(1, .monotonic);
    if (!ctx.opt.quiet_errors) ctx.output.reportErrno(ctx.progname, operation, path, err_no);
}

fn markFatal(ctx: *WorkerCtx, message: []const u8) void {
    if (!ctx.fatal.swap(true, .acq_rel)) ctx.output.reportMessage(ctx.progname, message);
    ctx.queue.abort();
}

fn openDirectory(pathz: [*:0]const u8) c_int {
    const flags = c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC;
    if (comptime @hasDecl(c, "O_NOATIME")) {
        const fd = c.open(pathz, flags | c.O_NOATIME);
        if (fd >= 0) return fd;
        if (currentErrno() != c.EPERM) return fd;
    }
    return c.open(pathz, flags);
}

extern "c" fn syscall(number: c_long, ...) c_long;

fn getdents64(fd: c_int, buffer: []u8) c_long {
    return syscall(
        @as(c_long, @intCast(c.SYS_getdents64)),
        @as(c_int, fd),
        @as(*anyopaque, @ptrCast(buffer.ptr)),
        @as(usize, buffer.len),
    );
}

fn freeTaskBatch(allocator: Allocator, batch: *TaskBatch) void {
    var current = batch.first;
    while (current) |task| {
        const next = task.next;
        allocator.free(task.pathz);
        allocator.destroy(task);
        current = next;
    }
    batch.reset();
}

fn flushTaskBatch(ctx: *WorkerCtx, local: *WorkerLocal) bool {
    if (local.task_batch.count == 0) return true;
    if (!ctx.queue.pushBatch(&local.task_batch)) {
        freeTaskBatch(ctx.allocator, &local.task_batch);
        return false;
    }
    if (ctx.opt.stats) _ = ctx.stats.dirs_enqueued.fetchAdd(local.task_batch.count, .monotonic);
    local.task_batch.reset();
    return true;
}

fn queueDirectory(ctx: *WorkerCtx, local: *WorkerLocal, path: []const u8, depth: i32, root_dev: c.dev_t) !bool {
    const task = try ctx.allocator.create(Task);
    errdefer ctx.allocator.destroy(task);
    const pathz = try dupeZ(ctx.allocator, path);
    errdefer ctx.allocator.free(pathz);

    task.* = .{
        .pathz = pathz,
        .depth = depth,
        .root_dev = root_dev,
    };
    local.task_batch.append(task);
    if (local.task_batch.count >= TASK_BATCH_SIZE) return flushTaskBatch(ctx, local);
    return true;
}

fn processDirectory(ctx: *WorkerCtx, local: *WorkerLocal, task: *Task) !void {
    const dir_path = pathSlice(task.pathz);
    const dir_z: [*:0]const u8 = @ptrCast(task.pathz.ptr);
    const fd = openDirectory(dir_z);
    if (fd < 0) {
        noteError(ctx, "cannot open directory", dir_path, currentErrno());
        return;
    }
    defer _ = c.close(fd);

    var read_buffer: [READ_BUFFER_SIZE]u8 align(@alignOf(LinuxDirent64)) = undefined;

    read_loop: while (true) {
        if (interrupted()) {
            ctx.queue.abort();
            break;
        }

        const count_raw = getdents64(fd, &read_buffer);
        if (count_raw == 0) break;
        if (count_raw < 0) {
            const err_no = currentErrno();
            if (err_no == c.EINTR and !interrupted()) continue;
            noteError(ctx, "cannot read directory", dir_path, err_no);
            break;
        }

        const count: usize = @intCast(count_raw);
        var offset: usize = 0;
        while (offset < count) {
            if (interrupted()) {
                ctx.queue.abort();
                break :read_loop;
            }

            if (count - offset < @offsetOf(LinuxDirent64, "d_name")) {
                noteError(ctx, "malformed directory data for", dir_path, c.EIO);
                break :read_loop;
            }

            const entry: *const LinuxDirent64 = @ptrCast(@alignCast(read_buffer[offset..].ptr));
            const record_len: usize = entry.d_reclen;
            const name_offset = @offsetOf(LinuxDirent64, "d_name");
            if (record_len <= name_offset or offset + record_len > count) {
                noteError(ctx, "malformed directory data for", dir_path, c.EIO);
                break :read_loop;
            }

            const name_storage = read_buffer[offset + name_offset .. offset + record_len];
            const nul = std.mem.indexOfScalar(u8, name_storage, 0) orelse {
                noteError(ctx, "malformed directory name in", dir_path, c.EIO);
                break :read_loop;
            };
            const name = name_storage[0..nul];
            offset += record_len;

            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!ctx.opt.hidden and name[0] == '.') continue;

            var type_char = typeCharFromDirent(entry.d_type);
            var st: c.struct_stat = undefined;
            var have_stat = false;

            if (needsStat(ctx.opt, type_char)) {
                const name_z: [*:0]const u8 = @ptrCast(name.ptr);
                if (c.fstatat(fd, name_z, &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
                    const error_path = buildChildPath(local, ctx.allocator, dir_path, name) catch name;
                    noteError(ctx, "cannot stat", error_path, currentErrno());
                    continue;
                }
                have_stat = true;
                if (type_char == '?') type_char = typeCharFromMode(st.st_mode);
            }

            if (ctx.opt.stats) noteType(ctx.stats, type_char);

            const early_nonmatch = !ctx.opt.full_path and ctx.opt.pattern != null and !patternMatches(ctx.opt, name, name);
            const ext_nonmatch = !extensionMatches(ctx.opt, name, matchingIsInsensitive(ctx.opt));
            const is_dir = type_char == 'd';
            const must_build_path = is_dir or ctx.opt.full_path or ctx.opt.excludes.len != 0 or
                ctx.opt.prunes.len != 0 or (!early_nonmatch and !ext_nonmatch);

            var child_path: []const u8 = "";
            if (must_build_path) child_path = try buildChildPath(local, ctx.allocator, dir_path, name);

            const child_depth = task.depth + 1;
            if (!early_nonmatch and !ext_nonmatch and
                entryMatches(ctx.opt, name, child_path, if (have_stat) &st else null, type_char, child_depth, ctx.now))
            {
                if (reserveMatch(ctx)) try emitMatch(ctx, local, child_path, type_char, if (have_stat) &st else null);
                if (ctx.opt.limit != 0 and ctx.stats.matched.load(.monotonic) >= ctx.opt.limit) break :read_loop;
            }

            if (!is_dir or child_depth >= ctx.opt.max_depth) continue;
            if (shouldPruneDirectory(ctx.opt, name, child_path)) continue;

            if (ctx.opt.xdev) {
                if (!have_stat) {
                    const name_z: [*:0]const u8 = @ptrCast(name.ptr);
                    if (c.fstatat(fd, name_z, &st, c.AT_SYMLINK_NOFOLLOW) != 0) {
                        noteError(ctx, "cannot stat directory", child_path, currentErrno());
                        continue;
                    }
                    have_stat = true;
                }
                if (st.st_dev != task.root_dev) continue;
            }

            if (!try queueDirectory(ctx, local, child_path, child_depth, task.root_dev)) break :read_loop;
        }
    }

    _ = flushTaskBatch(ctx, local);
}

fn workerMain(ctx: *WorkerCtx) void {
    var local = WorkerLocal{};
    local.init(ctx.allocator) catch {
        markFatal(ctx, "out of memory while initializing worker");
        return;
    };
    defer {
        if (local.task_batch.count != 0) freeTaskBatch(ctx.allocator, &local.task_batch);
        _ = flushOutput(ctx, &local);
        local.deinit(ctx.allocator);
    }

    while (true) {
        const task = ctx.queue.pop(ctx.opt.walk_mode) orelse break;

        if (interrupted() or ctx.fatal.load(.acquire)) {
            ctx.queue.abort();
        } else {
            processDirectory(ctx, &local, task) catch |err| switch (err) {
                error.OutputFailure => ctx.queue.abort(),
                error.OutOfMemory => markFatal(ctx, "out of memory during traversal"),
                else => markFatal(ctx, "unexpected traversal failure"),
            };
        }

        ctx.allocator.free(task.pathz);
        ctx.allocator.destroy(task);
        ctx.queue.taskDone();

    }
}

fn autodetectThreads() i32 {
    const count = c.sysconf(c._SC_NPROCESSORS_ONLN);
    if (count < 1) return 1;
    if (count > 64) return 64;
    return @intCast(count);
}

fn applyStorageDefaults(opt: *Options) void {
    const cores = autodetectThreads();
    if (opt.threads == 0) {
        opt.threads = switch (opt.storage_mode) {
            .hdd => @min(cores, 2),
            .auto => @min(cores, 16),
            .ssd => @min(cores, 32),
        };
    }
    if (!opt.walk_set) {
        opt.walk_mode = switch (opt.storage_mode) {
            .hdd => .dfs,
            .auto, .ssd => .bfs,
        };
    }
}

fn parseInt(comptime T: type, value: []const u8, option: []const u8, progname: []const u8) T {
    return std.fmt.parseInt(T, value, 10) catch {
        std.debug.print("{s}: invalid value for {s}: {s}\n", .{ progname, option, value });
        std.process.exit(2);
    };
}

fn parseOctal(value: []const u8, option: []const u8, progname: []const u8) c.mode_t {
    const parsed = std.fmt.parseInt(u32, value, 8) catch {
        std.debug.print("{s}: invalid octal value for {s}: {s}\n", .{ progname, option, value });
        std.process.exit(2);
    };
    if (parsed > 0o7777) {
        std.debug.print("{s}: permission mode exceeds 07777: {s}\n", .{ progname, value });
        std.process.exit(2);
    }
    return @intCast(parsed);
}

fn checkedMul(value: u64, multiplier: u64, progname: []const u8, option: []const u8, original: []const u8) u64 {
    const result = @mulWithOverflow(value, multiplier);
    if (result[1] != 0) {
        std.debug.print("{s}: value too large for {s}: {s}\n", .{ progname, option, original });
        std.process.exit(2);
    }
    return result[0];
}

fn parseScaledU64(value: []const u8, progname: []const u8, option: []const u8) u64 {
    if (value.len == 0) {
        std.debug.print("{s}: missing numeric value for {s}\n", .{ progname, option });
        std.process.exit(2);
    }

    var split = value.len;
    while (split > 0 and ((value[split - 1] >= 'A' and value[split - 1] <= 'Z') or (value[split - 1] >= 'a' and value[split - 1] <= 'z'))) split -= 1;
    const number_text = value[0..split];
    const suffix = value[split..];
    const number = std.fmt.parseInt(u64, number_text, 10) catch {
        std.debug.print("{s}: invalid numeric value for {s}: {s}\n", .{ progname, option, value });
        std.process.exit(2);
    };

    const multiplier: u64 = if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "b"))
        1
    else if (std.ascii.eqlIgnoreCase(suffix, "k") or std.ascii.eqlIgnoreCase(suffix, "kb"))
        1024
    else if (std.ascii.eqlIgnoreCase(suffix, "m") or std.ascii.eqlIgnoreCase(suffix, "mb"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "g") or std.ascii.eqlIgnoreCase(suffix, "gb"))
        1024 * 1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "t") or std.ascii.eqlIgnoreCase(suffix, "tb"))
        1024 * 1024 * 1024 * 1024
    else {
        std.debug.print("{s}: invalid size suffix for {s}: {s}\n", .{ progname, option, suffix });
        std.process.exit(2);
    };

    return checkedMul(number, multiplier, progname, option, value);
}

fn parseSizeSpec(opt: *Options, value: []const u8, progname: []const u8) void {
    if (value.len == 0) {
        std.debug.print("{s}: empty --size value\n", .{progname});
        std.process.exit(2);
    }

    const prefix = value[0];
    const body = if (prefix == '+' or prefix == '-') value[1..] else value;
    const size = parseScaledU64(body, progname, "--size");
    if (prefix == '+') {
        opt.size_min = if (size == std.math.maxInt(u64)) size else size + 1;
    } else if (prefix == '-') {
        opt.size_max = if (size == 0) 0 else size - 1;
    } else {
        opt.size_min = size;
        opt.size_max = size;
    }
}

fn parseDurationNs(value: []const u8, progname: []const u8, option: []const u8) u64 {
    if (value.len < 2) {
        std.debug.print("{s}: duration requires a suffix for {s}: {s}\n", .{ progname, option, value });
        std.process.exit(2);
    }

    var split = value.len;
    while (split > 0 and ((value[split - 1] >= 'A' and value[split - 1] <= 'Z') or (value[split - 1] >= 'a' and value[split - 1] <= 'z'))) split -= 1;
    const number = std.fmt.parseInt(u64, value[0..split], 10) catch {
        std.debug.print("{s}: invalid duration for {s}: {s}\n", .{ progname, option, value });
        std.process.exit(2);
    };
    const suffix = value[split..];
    const seconds: u64 = if (std.ascii.eqlIgnoreCase(suffix, "s"))
        1
    else if (std.ascii.eqlIgnoreCase(suffix, "m"))
        60
    else if (std.ascii.eqlIgnoreCase(suffix, "h"))
        60 * 60
    else if (std.ascii.eqlIgnoreCase(suffix, "d"))
        24 * 60 * 60
    else if (std.ascii.eqlIgnoreCase(suffix, "w"))
        7 * 24 * 60 * 60
    else {
        std.debug.print("{s}: invalid duration suffix for {s}: {s}\n", .{ progname, option, suffix });
        std.process.exit(2);
    };

    const total_seconds = checkedMul(number, seconds, progname, option, value);
    return checkedMul(total_seconds, 1_000_000_000, progname, option, value);
}

fn parseType(opt: *Options, value: []const u8, progname: []const u8) void {
    if (value.len != 1) {
        std.debug.print("{s}: --type expects one of f,d,l,b,c,p,s,x,e\n", .{progname});
        std.process.exit(2);
    }
    switch (value[0]) {
        'f', 'd', 'l', 'b', 'c', 'p', 's' => opt.type_mask |= typeBit(value[0]),
        'x' => opt.executable_only = true,
        'e' => opt.empty_only = true,
        else => {
            std.debug.print("{s}: invalid file type: {s}\n", .{ progname, value });
            std.process.exit(2);
        },
    }
}

fn requireValue(args: []const []const u8, index: *usize, option: []const u8, progname: []const u8) []const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        std.debug.print("{s}: missing value for {s}\n", .{ progname, option });
        std.process.exit(2);
    }
    return args[index.*];
}

fn parseWalk(value: []const u8, progname: []const u8) WalkMode {
    if (std.ascii.eqlIgnoreCase(value, "bfs")) return .bfs;
    if (std.ascii.eqlIgnoreCase(value, "dfs")) return .dfs;
    std.debug.print("{s}: invalid walk mode '{s}' (use bfs or dfs)\n", .{ progname, value });
    std.process.exit(2);
}

fn parseStorage(value: []const u8, progname: []const u8) StorageMode {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "hdd")) return .hdd;
    if (std.ascii.eqlIgnoreCase(value, "ssd")) return .ssd;
    std.debug.print("{s}: invalid storage mode '{s}' (use auto, hdd, or ssd)\n", .{ progname, value });
    std.process.exit(2);
}

fn parseColor(value: []const u8, progname: []const u8) ColorMode {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "always")) return .always;
    if (std.ascii.eqlIgnoreCase(value, "never")) return .never;
    std.debug.print("{s}: invalid color mode '{s}' (use auto, always, or never)\n", .{ progname, value });
    std.process.exit(2);
}

fn stdoutIsTty() bool {
    return c.isatty(c.fileno(c.stdout)) == 1;
}

fn noColorEnvironment() bool {
    return c.getenv("NO_COLOR") != null;
}

fn usage(progname: []const u8, color: bool) void {
    const bold = if (color) "\x1b[1m" else "";
    const cyan = if (color) "\x1b[1;36m" else "";
    const yellow = if (color) "\x1b[1;33m" else "";
    const reset = if (color) "\x1b[0m" else "";

    std.debug.print(
        "{s}raid{s}, {s}super fast low level file thingy for Linux{s}\n\n" ++
            "{s}USAGE{s}\n" ++
            "  {s} [OPTIONS] [PATTERN] [PATH ...]\n" ++
            "  {s} [OPTIONS] --path PATH [--path PATH ...] [PATTERN]\n\n" ++
            "{s}MATCHING{s}\n" ++
            "  -g, --glob                 Treat PATTERN as a glob instead of a substring\n" ++
            "  -p, --full-path            Match PATTERN against the full path\n" ++
            "  -i, --ignore-case          Case-insensitive matching\n" ++
            "  -s, --case-sensitive       Case-sensitive matching\n" ++
            "  -e, --extension EXT        Match an extension; repeatable\n" ++
            "  -E, --exclude GLOB         Exclude matching names or paths; repeatable\n" ++
            "      --prune GLOB           Do not descend into matching directories\n" ++
            "  -t, --type TYPE            f,d,l,b,c,p,s,x(executable),e(empty)\n\n" ++
            "{s}FILTERS{s}\n" ++
            "      --size SIZE            Exact, +minimum, or -maximum; suffix K/M/G/T\n" ++
            "      --changed-within DUR    Modified within 10s, 5m, 2h, 3d, or 1w\n" ++
            "      --changed-before DUR    Modified more than DUR ago\n" ++
            "      --newer FILE            Modified more recently than FILE\n" ++
            "      --uid N --gid N         Exact owner filters\n" ++
            "      --inode N               Exact inode filter\n" ++
            "      --perm MODE             Exact octal permission bits\n" ++
            "      --min-depth N           Minimum result depth\n" ++
            "  -d, --max-depth N           Maximum traversal depth\n\n" ++
            "{s}TRAVERSAL{s}\n" ++
            "  -H, --hidden                Include hidden entries\n" ++
            "      --one-file-system       Do not cross filesystem boundaries\n" ++
            "      --skip-vfs              Skip /proc, /sys, /dev, and /run\n" ++
            "  -j, --threads N             Worker count; 0 selects a tuned default\n" ++
            "      --storage MODE          auto, hdd, or ssd\n" ++
            "      --walk MODE             bfs or dfs\n" ++
            "      --path PATH             Add an explicit search root; repeatable\n" ++
            "  -a, --absolute              Canonicalize roots to absolute paths\n\n" ++
            "{s}OUTPUT{s}\n" ++
            "  -l, --long                  Permissions, size, timestamp, and path\n" ++
            "  -h, --human-readable        Human-readable sizes with --long\n" ++
            "      --classify              Append /, @, *, |, or = indicators\n" ++
            "      --color WHEN            auto, always, or never\n" ++
            "  -0, --print0                NUL-delimit results\n" ++
            "      --no-strip-prefix       Keep a leading ./ in output\n" ++
            "      --max-results N         Stop after N matches\n" ++
            "      --no-print              Traverse without printing matches\n" ++
            "  -q, --quiet                 Suppress traversal errors\n" ++
            "      --stats                 Print counters\n" ++
            "      --time                  Print wall and CPU time\n\n" ++
            "{s}GENERAL{s}\n" ++
            "      --help                  Show this help\n" ++
            "  -V, --version               Show version\n\n" ++
            "{s}Examples{s}\n" ++
            "  {s} config src\n" ++
            "  {s} -e zig -t f .\n" ++
            "  {s} -g '*.png' ~/Pictures --color always\n" ++
            "  {s} --size +100M --type f /mnt/storage\n",
        .{
            cyan,
            reset,
            yellow,
            reset,
            bold,
            reset,
            progname,
            progname,
            bold,
            reset,
            bold,
            reset,
            bold,
            reset,
            bold,
            reset,
            bold,
            reset,
            bold,
            reset,
            progname,
            progname,
            progname,
            progname,
        },
    );
}

fn canonicalizeRoot(allocator: Allocator, root: []const u8, progname: []const u8) []const u8 {
    const rootz = dupeZ(allocator, root) catch {
        std.debug.print("{s}: out of memory\n", .{progname});
        std.process.exit(2);
    };
    defer allocator.free(rootz);

    const resolved_ptr = c.realpath(@ptrCast(rootz.ptr), null);
    if (resolved_ptr == null) {
        const err_no = currentErrno();
        const message_ptr = c.strerror(err_no);
        const message = if (message_ptr == null) "unknown error" else std.mem.span(message_ptr);
        std.debug.print("{s}: cannot resolve '{s}': {s}\n", .{ progname, root, message });
        std.process.exit(2);
    }
    defer c.free(resolved_ptr);

    const resolved = std.mem.span(resolved_ptr);
    return allocator.dupe(u8, resolved) catch {
        std.debug.print("{s}: out of memory\n", .{progname});
        std.process.exit(2);
    };
}

fn looksLikeDirectory(path: []const u8, allocator: Allocator) bool {
    const pathz = dupeZ(allocator, path) catch return false;
    defer allocator.free(pathz);
    var st: c.struct_stat = undefined;
    if (c.stat(@ptrCast(pathz.ptr), &st) != 0) return false;
    return (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

pub fn main(init: std.process.Init) !void {
    global_io = init.io;
    installSignalHandlers();

    const parse_allocator = init.arena.allocator();
    const work_allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(parse_allocator);
    if (args.len == 0) return;
    const progname = args[0];

    var opt = Options{};
    var extensions: std.ArrayList([]const u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    var prunes: std.ArrayList([]const u8) = .empty;
    var explicit_roots: std.ArrayList([]const u8) = .empty;
    var positionals: std.ArrayList([]const u8) = .empty;

    var pattern_was_explicit = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try positionals.append(parse_allocator, args[i]);
            break;
        } else if (std.mem.eql(u8, arg, "--help")) {
            usage(progname, stdoutIsTty() and !noColorEnvironment());
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("raid {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--glob")) {
            opt.glob = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--full-path")) {
            opt.full_path = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            opt.case_mode = .insensitive;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--case-sensitive")) {
            opt.case_mode = .sensitive;
        } else if (std.mem.eql(u8, arg, "--smart-case")) {
            opt.case_mode = .smart;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--extension")) {
            try extensions.append(parse_allocator, requireValue(args, &i, arg, progname));
        } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "--exclude") or std.mem.eql(u8, arg, "-exclude")) {
            try excludes.append(parse_allocator, requireValue(args, &i, arg, progname));
        } else if (std.mem.eql(u8, arg, "--prune") or std.mem.eql(u8, arg, "-prune")) {
            try prunes.append(parse_allocator, requireValue(args, &i, arg, progname));
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--type")) {
            parseType(&opt, requireValue(args, &i, arg, progname), progname);
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--hidden")) {
            opt.hidden = true;
        } else if (std.mem.eql(u8, arg, "--one-file-system") or std.mem.eql(u8, arg, "-xdev")) {
            opt.xdev = true;
        } else if (std.mem.eql(u8, arg, "--skip-vfs")) {
            opt.skip_vfs = true;
        } else if (std.mem.eql(u8, arg, "--min-depth") or std.mem.eql(u8, arg, "-mindepth")) {
            opt.min_depth = parseInt(i32, requireValue(args, &i, arg, progname), arg, progname);
            if (opt.min_depth < 0) std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--max-depth") or std.mem.eql(u8, arg, "-maxdepth")) {
            opt.max_depth = parseInt(i32, requireValue(args, &i, arg, progname), arg, progname);
            if (opt.max_depth < 0) std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--threads")) {
            opt.threads = parseInt(i32, requireValue(args, &i, arg, progname), arg, progname);
            if (opt.threads < 0) std.process.exit(2);
            if (opt.threads > 256) {
                std.debug.print("{s}: refusing more than 256 worker threads\n", .{progname});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--storage")) {
            opt.storage_mode = parseStorage(requireValue(args, &i, arg, progname), progname);
        } else if (std.mem.eql(u8, arg, "--walk")) {
            opt.walk_mode = parseWalk(requireValue(args, &i, arg, progname), progname);
            opt.walk_set = true;
        } else if (std.mem.eql(u8, arg, "--size")) {
            parseSizeSpec(&opt, requireValue(args, &i, arg, progname), progname);
        } else if (std.mem.eql(u8, arg, "--changed-within")) {
            opt.age_max_ns = parseDurationNs(requireValue(args, &i, arg, progname), progname, arg);
        } else if (std.mem.eql(u8, arg, "--changed-before")) {
            opt.age_min_ns = parseDurationNs(requireValue(args, &i, arg, progname), progname, arg);
        } else if (std.mem.eql(u8, arg, "--uid") or std.mem.eql(u8, arg, "-uid")) {
            opt.uid = parseInt(c.uid_t, requireValue(args, &i, arg, progname), arg, progname);
            opt.uid_set = true;
        } else if (std.mem.eql(u8, arg, "--gid") or std.mem.eql(u8, arg, "-gid")) {
            opt.gid = parseInt(c.gid_t, requireValue(args, &i, arg, progname), arg, progname);
            opt.gid_set = true;
        } else if (std.mem.eql(u8, arg, "--inode") or std.mem.eql(u8, arg, "-inode")) {
            opt.inode = parseInt(c.ino_t, requireValue(args, &i, arg, progname), arg, progname);
            opt.inode_set = true;
        } else if (std.mem.eql(u8, arg, "--perm") or std.mem.eql(u8, arg, "-perm")) {
            opt.perm = parseOctal(requireValue(args, &i, arg, progname), arg, progname);
            opt.perm_set = true;
        } else if (std.mem.eql(u8, arg, "--newer") or std.mem.eql(u8, arg, "-newer")) {
            const reference = requireValue(args, &i, arg, progname);
            const reference_z = try dupeZ(parse_allocator, reference);
            var st: c.struct_stat = undefined;
            if (c.stat(@ptrCast(reference_z.ptr), &st) != 0) {
                const message_ptr = c.strerror(currentErrno());
                const message = if (message_ptr == null) "unknown error" else std.mem.span(message_ptr);
                std.debug.print("{s}: cannot stat reference '{s}': {s}\n", .{ progname, reference, message });
                std.process.exit(2);
            }
            opt.newer_than = .{ .tv_sec = st.st_mtim.tv_sec, .tv_nsec = st.st_mtim.tv_nsec };
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--long")) {
            opt.long = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--human-readable")) {
            opt.human_readable = true;
        } else if (std.mem.eql(u8, arg, "--classify")) {
            opt.classify = true;
        } else if (std.mem.eql(u8, arg, "--color")) {
            opt.color_mode = parseColor(requireValue(args, &i, arg, progname), progname);
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            opt.color_mode = parseColor(arg[8..], progname);
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opt.color_mode = .never;
        } else if (std.mem.eql(u8, arg, "-0") or std.mem.eql(u8, arg, "--print0")) {
            opt.print0 = true;
        } else if (std.mem.eql(u8, arg, "--no-strip-prefix")) {
            opt.strip_dot_slash = false;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--absolute")) {
            opt.absolute = true;
        } else if (std.mem.eql(u8, arg, "--max-results") or std.mem.eql(u8, arg, "--limit") or std.mem.eql(u8, arg, "-limit")) {
            opt.limit = parseInt(u64, requireValue(args, &i, arg, progname), arg, progname);
        } else if (std.mem.eql(u8, arg, "--no-print") or std.mem.eql(u8, arg, "-noprint")) {
            opt.noprint = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            opt.quiet_errors = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            opt.stats = true;
        } else if (std.mem.eql(u8, arg, "--time")) {
            opt.timing = true;
        } else if (std.mem.eql(u8, arg, "--path")) {
            try explicit_roots.append(parse_allocator, requireValue(args, &i, arg, progname));
        } else if (std.mem.eql(u8, arg, "--pattern")) {
            opt.pattern = requireValue(args, &i, arg, progname);
            pattern_was_explicit = true;
        } else if (std.mem.eql(u8, arg, "-name")) {
            opt.pattern = requireValue(args, &i, arg, progname);
            opt.glob = true;
            pattern_was_explicit = true;
        } else if (std.mem.eql(u8, arg, "-path")) {
            opt.pattern = requireValue(args, &i, arg, progname);
            opt.glob = true;
            opt.full_path = true;
            pattern_was_explicit = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("{s}: unknown option: {s}\n", .{ progname, arg });
            std.debug.print("Try '{s} --help'.\n", .{progname});
            std.process.exit(2);
        } else {
            try positionals.append(parse_allocator, arg);
        }
    }

    opt.extensions = extensions.items;
    opt.excludes = excludes.items;
    opt.prunes = prunes.items;

    var roots: std.ArrayList([]const u8) = .empty;
    if (pattern_was_explicit) {
        for (positionals.items) |root| try roots.append(parse_allocator, root);
    } else if (explicit_roots.items.len != 0) {
        if (positionals.items.len > 0) opt.pattern = positionals.items[0];
        if (positionals.items.len > 1) {
            std.debug.print("{s}: extra positional paths are not allowed with --path\n", .{progname});
            std.process.exit(2);
        }
    } else if (positionals.items.len == 1 and looksLikeDirectory(positionals.items[0], parse_allocator)) {
        try roots.append(parse_allocator, positionals.items[0]);
    } else if (positionals.items.len > 0) {
        opt.pattern = positionals.items[0];
        for (positionals.items[1..]) |root| try roots.append(parse_allocator, root);
    }

    for (explicit_roots.items) |root| try roots.append(parse_allocator, root);
    if (roots.items.len == 0) try roots.append(parse_allocator, ".");

    if (opt.min_depth > opt.max_depth) {
        std.debug.print("{s}: --min-depth exceeds --max-depth\n", .{progname});
        std.process.exit(2);
    }

    if (opt.print0) opt.color_mode = .never;
    opt.use_color = switch (opt.color_mode) {
        .always => true,
        .never => false,
        .auto => stdoutIsTty() and !noColorEnvironment(),
    };
    applyStorageDefaults(&opt);

    _ = c.setvbuf(c.stdout, null, c._IOFBF, 1024 * 1024);

    var now_c: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &now_c);
    const now = Timespec{ .tv_sec = now_c.tv_sec, .tv_nsec = now_c.tv_nsec };

    var queue = TaskQueue{};
    defer queue.drain(work_allocator);
    var output = Output{};
    var stats = Stats{};
    var fatal = AtomicBool.init(false);
    var timing: Timing = undefined;
    if (opt.timing) timing = Timing.start();

    var ctx = WorkerCtx{
        .allocator = work_allocator,
        .opt = &opt,
        .queue = &queue,
        .output = &output,
        .stats = &stats,
        .progname = progname,
        .now = now,
        .fatal = &fatal,
    };

    var initial_batch = TaskBatch{};
    for (roots.items) |raw_root| {
        const normalized = normalizeRoot(raw_root);
        const root = if (opt.absolute) canonicalizeRoot(parse_allocator, normalized, progname) else normalized;
        if (opt.skip_vfs and isVfsPath(root)) continue;

        const rootz = dupeZ(work_allocator, root) catch {
            fatal.store(true, .release);
            output.reportMessage(progname, "out of memory while preparing roots");
            break;
        };

        var st: c.struct_stat = undefined;
        if (c.lstat(@ptrCast(rootz.ptr), &st) != 0) {
            noteError(&ctx, "cannot stat", root, currentErrno());
            work_allocator.free(rootz);
            continue;
        }

        const type_char = typeCharFromMode(st.st_mode);
        if (opt.stats) noteType(&stats, type_char);
        const basename = std.fs.path.basename(root);
        if (entryMatches(&opt, basename, root, &st, type_char, 0, now)) {
            if (reserveMatch(&ctx) and !opt.noprint) {
                var local = WorkerLocal{};
                local.init(work_allocator) catch {
                    work_allocator.free(rootz);
                    fatal.store(true, .release);
                    output.reportMessage(progname, "out of memory while formatting root");
                    break;
                };
                emitMatch(&ctx, &local, root, type_char, &st) catch {};
                _ = flushOutput(&ctx, &local);
                local.deinit(work_allocator);
            }
        }

        if (type_char == 'd' and opt.max_depth > 0 and !queue.done and !shouldPruneDirectory(&opt, basename, root)) {
            const task = work_allocator.create(Task) catch {
                work_allocator.free(rootz);
                fatal.store(true, .release);
                output.reportMessage(progname, "out of memory while queuing root");
                break;
            };
            task.* = .{ .pathz = rootz, .depth = 0, .root_dev = st.st_dev };
            initial_batch.append(task);
        } else {
            work_allocator.free(rootz);
        }
    }

    if (initial_batch.count != 0) {
        if (queue.pushBatch(&initial_batch)) {
            if (opt.stats) _ = stats.dirs_enqueued.fetchAdd(initial_batch.count, .monotonic);
            initial_batch.reset();
        } else {
            freeTaskBatch(work_allocator, &initial_batch);
        }
    }
    queue.finalizeIfIdle();

    if (!fatal.load(.acquire) and !queue.done) {
        if (opt.threads <= 1) {
            workerMain(&ctx);
        } else {
            const thread_count: usize = @intCast(opt.threads);
            const threads = try work_allocator.alloc(std.Thread, thread_count);
            defer work_allocator.free(threads);

            var created: usize = 0;
            while (created < thread_count) : (created += 1) {
                threads[created] = std.Thread.spawn(.{}, workerMain, .{&ctx}) catch {
                    queue.abort();
                    fatal.store(true, .release);
                    output.reportMessage(progname, "failed to spawn worker thread");
                    break;
                };
            }
            for (threads[0..created]) |thread| thread.join();
        }
    }

    if (opt.timing) timing.stop();
    _ = c.fflush(c.stdout);

    const matched_raw = stats.matched.load(.monotonic);
    const matched = if (opt.limit != 0) @min(matched_raw, opt.limit) else matched_raw;
    if (opt.stats) {
        std.debug.print(
            "matched={} files={} dirs={} links={} others={} queued_dirs={} errors={} bytes={} threads={} walk={s} storage={s}\n",
            .{
                matched,
                stats.files_seen.load(.monotonic),
                stats.dirs_seen.load(.monotonic),
                stats.links_seen.load(.monotonic),
                stats.others_seen.load(.monotonic),
                stats.dirs_enqueued.load(.monotonic),
                stats.errors.load(.monotonic),
                stats.bytes_emitted.load(.monotonic),
                opt.threads,
                if (opt.walk_mode == .bfs) "bfs" else "dfs",
                switch (opt.storage_mode) {
                    .auto => "auto",
                    .hdd => "hdd",
                    .ssd => "ssd",
                },
            },
        );
    }
    if (opt.timing) timing.print();

    if (interrupted()) std.process.exit(130);
    if (fatal.load(.acquire)) std.process.exit(2);
    if (stats.errors.load(.monotonic) != 0) std.process.exit(1);
}

test "substring matching supports smart ASCII case" {
    try std.testing.expect(containsText("HelloWorld", "hello", true));
    try std.testing.expect(!containsText("HelloWorld", "hello", false));
}

test "glob matching supports stars questions and classes" {
    try std.testing.expect(globMatches("*.zig", "main.zig", false));
    try std.testing.expect(globMatches("src/??in.[ch]", "src/main.c", false));
    try std.testing.expect(!globMatches("*.zig", "main.c", false));
}

test "root normalization preserves slash" {
    try std.testing.expectEqualStrings("/", normalizeRoot("////"));
    try std.testing.expectEqualStrings("/tmp", normalizeRoot("/tmp///"));
    try std.testing.expectEqualStrings(".", normalizeRoot(""));
}
