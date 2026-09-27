const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const loose_mod = @import("../git/loose.zig");
const paths_mod = @import("paths.zig");

pub const GrowthError = error{
    OutOfMemory,
    CorruptRepository,
    Unexpected,
};

pub const MonthBucket = struct {
    year: i32,
    /// 1-12.
    month: u8,
    /// Logical bytes of blobs whose introducing commit falls in this month.
    introduced_bytes: u64,
    /// Running total of introduced bytes through this month.
    cumulative_bytes: u64,
};

pub const GrowthReport = struct {
    /// Ascending by month; sliced to the most recent `months` buckets when
    /// requested (total_introduced_bytes still covers all history).
    buckets: []MonthBucket,
    /// Logical bytes introduced across all reachable history.
    total_introduced_bytes: u64,

    pub fn deinit(self: *GrowthReport, allocator: std.mem.Allocator) void {
        allocator.free(self.buckets);
    }
};

/// Calendar month of a committer timestamp as `year * 12 + month - 1`.
/// Negative timestamps clamp to the epoch, like explain.formatDate.
pub fn monthKey(timestamp: i64) i32 {
    const secs: u64 = if (timestamp < 0) 0 else @intCast(timestamp);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return @as(i32, @intCast(year_day.year)) * 12 + @as(i32, @intCast(month_day.month.numeric())) - 1;
}

/// "YYYY-MM" for a monthKey. `buf` must be at least 8 bytes.
pub fn formatMonth(buf: []u8, key: i32) []const u8 {
    const year = @divFloor(key, 12);
    const month: u8 = @intCast(key - year * 12 + 1);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ @as(u32, @intCast(year)), month }) catch unreachable;
}

/// Introducing commit attributed to a blob: the earliest by committer time,
/// ties broken by earliest walk index (DFS pop order).
const Candidate = struct {
    time: i64,
    index: u32,
};

/// Strictly-better comparison, independent of processing order.
pub fn betterCandidate(a: Candidate, b: Candidate) bool {
    if (a.time != b.time) return a.time < b.time;
    return a.index < b.index;
}

const CommitInfo = struct {
    id: object_id.ObjectId,
    time: i64,
    /// Arena-owned.
    parents: []const object_id.ObjectId,
    tree: object_id.ObjectId,
};

const max_workers = 64;

/// Collect every commit reachable from any ref (including HEAD), in DFS pop
/// order, with committer time, parents, and root tree. Mirrors
/// explain.collectCommits: the commit-graph fast path preserves the same
/// parent push order as the payload parse, so ordering is deterministic.
fn collectCommits(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    arena: std.mem.Allocator,
) GrowthError!struct { commits: std.ArrayList(CommitInfo), by_id: std.HashMapUnmanaged(object_id.ObjectId, u32, object_id.ObjectId.Context, 80) } {
    var commits: std.ArrayList(CommitInfo) = .empty;
    errdefer commits.deinit(arena);
    var by_id: std.HashMapUnmanaged(object_id.ObjectId, u32, object_id.ObjectId.Context, 80) = .empty;
    errdefer by_id.deinit(arena);

    var visited: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer visited.deinit(arena);
    var stack: std.ArrayList(object_id.ObjectId) = .empty;
    defer stack.deinit(arena);
    var graph_parent_buf: std.ArrayList(u32) = .empty;
    defer graph_parent_buf.deinit(arena);

    for (refs.refs.items) |r| {
        const tip = paths_mod.peelToCommit(store, &r.target, 0) orelse continue;
        if (visited.contains(tip)) continue;
        try visited.put(arena, tip, {});
        try stack.append(arena, tip);
    }

    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();

    while (stack.pop()) |id| {
        if (store.graph) |*g| {
            if (g.lookup(&id)) |pos| {
                const resolved = g.entry(pos, arena, &graph_parent_buf) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidGraph => null,
                };
                if (resolved) |ent| {
                    const parents = try arena.alloc(object_id.ObjectId, ent.parents.len);
                    for (ent.parents, 0..) |pp, i| parents[i] = g.oidAt(pp);
                    try by_id.put(arena, id, @intCast(commits.items.len));
                    try commits.append(arena, .{ .id = id, .time = ent.time, .parents = parents, .tree = ent.tree });
                    for (parents) |p| {
                        if (visited.contains(p)) continue;
                        try visited.put(arena, p, {});
                        try stack.append(arena, p);
                    }
                    continue;
                }
            }
        }
        _ = scratch.reset(.retain_capacity);
        const payload = store.readPayload(scratch.allocator(), &id) catch continue;
        defer payload.release();
        if (payload.object_type != .commit) continue;
        const c = commit_mod.parse(payload.data, id.algorithm, scratch.allocator()) catch continue;
        const parents = try arena.dupe(object_id.ObjectId, c.parents);
        try by_id.put(arena, id, @intCast(commits.items.len));
        try commits.append(arena, .{
            .id = id,
            .time = if (c.committer) |cm| cm.timestamp else 0,
            .parents = parents,
            .tree = c.tree,
        });
        for (c.parents) |p| {
            if (visited.contains(p)) continue;
            try visited.put(arena, p, {});
            try stack.append(arena, p);
        }
    }
    return .{ .commits = commits, .by_id = by_id };
}

/// Per-commit diff state threaded through the recursive tree walk.
const DiffCtx = struct {
    alloc: std.mem.Allocator,
    /// Worker-lifetime best candidate per blob.
    candidates: *std.HashMapUnmanaged(object_id.ObjectId, Candidate, object_id.ObjectId.Context, 80),
    /// Per-commit dedupe set (cleared between commits).
    seen: *std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80),
    time: i64,
    index: u32,
};

fn addCandidate(ctx: *DiffCtx, id: *const object_id.ObjectId) GrowthError!void {
    const gop = try ctx.seen.getOrPut(ctx.alloc, id.*);
    if (gop.found_existing) return;
    const cand: Candidate = .{ .time = ctx.time, .index = ctx.index };
    const gop2 = try ctx.candidates.getOrPut(ctx.alloc, id.*);
    if (!gop2.found_existing or betterCandidate(cand, gop2.value_ptr.*)) {
        gop2.value_ptr.* = cand;
    }
}

/// Git's tree-entry name order: names compare bytewise, with directories
/// comparing as if suffixed by '/'.
fn treeNameCompare(a: *const tree_mod.TreeEntry, b: *const tree_mod.TreeEntry) std.math.Order {
    const min_len = @min(a.name.len, b.name.len);
    const c = std.mem.order(u8, a.name[0..min_len], b.name[0..min_len]);
    if (c != .eq) return c;
    const ca: u8 = if (a.name.len > min_len) a.name[min_len] else if (a.entryMode() == .tree) '/' else 0;
    const cb: u8 = if (b.name.len > min_len) b.name[min_len] else if (b.entryMode() == .tree) '/' else 0;
    return std.math.order(ca, cb);
}

/// Record blobs present in tree `a_oid` but not at the same path in tree
/// `b_oid` (null = absent parent: everything under `a_oid` is added).
/// Unreadable trees count as absent. `scratch` must not be reset for the
/// duration of the recursion.
fn diffTrees(
    store: *const object_store.ObjectStore,
    scratch: std.mem.Allocator,
    a_oid: *const object_id.ObjectId,
    b_oid: ?*const object_id.ObjectId,
    ctx: *DiffCtx,
) GrowthError!void {
    const pa = store.readPayload(scratch, a_oid) catch return;
    defer pa.release();
    if (pa.object_type != .tree) return;

    var pb: ?object_store.ObjectStore.Payload = null;
    defer if (pb) |*p| p.release();
    var it_b: ?tree_mod.TreeIterator = null;
    if (b_oid) |bo| {
        if (store.readPayload(scratch, bo)) |p| {
            if (p.object_type == .tree) {
                pb = p;
                it_b = tree_mod.TreeIterator.init(p.data, bo.algorithm);
            } else {
                p.release();
            }
        } else |_| {}
    }

    var it_a = tree_mod.TreeIterator.init(pa.data, a_oid.algorithm);
    var cur_a = it_a.next() catch null;
    var cur_b: ?tree_mod.TreeEntry = if (it_b) |*ib| (ib.next() catch null) else null;
    while (cur_a != null or cur_b != null) {
        if (cur_b == null or (cur_a != null and treeNameCompare(&cur_a.?, &cur_b.?) == .lt)) {
            const a = cur_a.?;
            if (a.entryMode() == .tree) {
                try diffTrees(store, scratch, &a.id, null, ctx);
            } else if (a.entryMode() != .submodule) {
                try addCandidate(ctx, &a.id);
            }
            cur_a = it_a.next() catch null;
        } else if (cur_a == null or treeNameCompare(&cur_b.?, &cur_a.?) == .lt) {
            cur_b = if (it_b) |*ib| (ib.next() catch null) else null;
        } else {
            const a = cur_a.?;
            const b = cur_b.?;
            const a_tree = a.entryMode() == .tree;
            const b_tree = b.entryMode() == .tree;
            if (a_tree and b_tree) {
                try diffTrees(store, scratch, &a.id, &b.id, ctx);
            } else if (a_tree) {
                try diffTrees(store, scratch, &a.id, null, ctx);
            } else if (a.entryMode() != .submodule) {
                // Blob vs blob (changed) or blob vs tree (file replaced a
                // directory): the blob is new content at this path.
                if (b_tree or !a.id.eql(&b.id)) try addCandidate(ctx, &a.id);
            }
            cur_a = it_a.next() catch null;
            cur_b = if (it_b) |*ib| (ib.next() catch null) else null;
        }
    }
}

const WalkShared = struct {
    commits: []const CommitInfo,
    by_id: *const std.HashMapUnmanaged(object_id.ObjectId, u32, object_id.ObjectId.Context, 80),
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
};

const Worker = struct {
    store: *const object_store.ObjectStore,
    shared: *WalkShared,
    scratch: std.heap.ArenaAllocator,
    arena: std.heap.ArenaAllocator,
    candidates: std.HashMapUnmanaged(object_id.ObjectId, Candidate, object_id.ObjectId.Context, 80) = .empty,
    seen: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty,

    fn deinit(self: *Worker) void {
        self.scratch.deinit();
        self.arena.deinit();
    }
};

fn workerRun(w: *Worker) void {
    const chunk = 256;
    while (true) {
        const start = w.shared.next.fetchAdd(chunk, .monotonic);
        if (start >= w.shared.commits.len) return;
        if (w.shared.failed.load(.acquire)) return;
        const end = @min(w.shared.commits.len, start + chunk);
        for (w.shared.commits[start..end], start..) |*ci, idx| {
            _ = w.scratch.reset(.retain_capacity);
            w.seen.clearRetainingCapacity();
            var ctx: DiffCtx = .{
                .alloc = w.arena.allocator(),
                .candidates = &w.candidates,
                .seen = &w.seen,
                .time = ci.time,
                .index = @intCast(idx),
            };
            // Merge commits diff against the first parent only; the side
            // branch's own commits are walked too and win the earlier-time
            // attribution in the merge step.
            var b_oid: ?object_id.ObjectId = null;
            if (ci.parents.len > 0) {
                if (w.shared.by_id.get(ci.parents[0])) |pi| b_oid = w.shared.commits[pi].tree;
            }
            diffTrees(w.store, w.scratch.allocator(), &ci.tree, if (b_oid) |*bo| bo else null, &ctx) catch {
                w.shared.failed.store(true, .release);
                return;
            };
        }
    }
}

/// Repository growth over time (spec §36): bucket every reachable commit by
/// committer calendar month; a blob's logical size is attributed to the month
/// of its introducing commit (earliest commit containing it whose parents do
/// not, by committer time with walk-order ties). Also reports the cumulative
/// introduced-bytes total at each month. Content that was later deleted still
/// counts — this measures how fast history accumulates weight.
pub fn build(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
    months: ?usize,
) GrowthError!GrowthReport {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var collected = try collectCommits(store, refs, a);
    const commits = collected.commits.items;
    if (commits.len == 0) {
        collected.commits.deinit(a);
        collected.by_id.deinit(a);
        return .{ .buckets = try allocator.alloc(MonthBucket, 0), .total_introduced_bytes = 0 };
    }

    var shared: WalkShared = .{ .commits = commits, .by_id = &collected.by_id };

    // Explicit usize: @min against a comptime bound would otherwise infer
    // a narrow type for the worker count.
    const n_workers: usize = @max(1, @min(store.threads, max_workers));
    var workers_buf: [max_workers]Worker = undefined;
    var n_init: usize = 0;
    defer for (workers_buf[0..n_init]) |*w| w.deinit();
    for (0..n_workers) |i| {
        workers_buf[i] = .{
            .store = store,
            .shared = &shared,
            .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
        n_init += 1;
    }

    if (n_workers == 1) {
        workerRun(&workers_buf[0]);
    } else {
        // Workers share the loose list; resolve lazy headers up front so the
        // write-back in readPayload is race-free (same trick as paths.zig).
        for (store.loose.objects.items) |*o| {
            _ = loose_mod.resolveHeader(o) catch continue;
        }
        var spawned: usize = 0;
        var handles: [max_workers]?std.Thread = .{null} ** max_workers;
        for (workers_buf[0 .. n_init - 1], 0..) |*w, i| {
            handles[i] = std.Thread.spawn(.{}, workerRun, .{w}) catch null;
            if (handles[i] != null) spawned += 1;
        }
        workerRun(&workers_buf[n_init - 1]);
        for (0..spawned) |i| handles[i].?.join();
    }
    if (shared.failed.load(.acquire)) return error.OutOfMemory;

    // Deterministic merge: strictly-better candidates win regardless of
    // shard scheduling.
    var best: std.HashMapUnmanaged(object_id.ObjectId, Candidate, object_id.ObjectId.Context, 80) = .empty;
    defer best.deinit(a);
    for (workers_buf[0..n_init]) |*w| {
        var it = w.candidates.iterator();
        while (it.next()) |e| {
            const gop = try best.getOrPut(a, e.key_ptr.*);
            if (!gop.found_existing or betterCandidate(e.value_ptr.*, gop.value_ptr.*)) {
                gop.value_ptr.* = e.value_ptr.*;
            }
        }
    }

    // Attribute logical sizes to introducing-commit months; seed every
    // month present in history (a month with only deletions shows 0).
    var buckets: std.AutoHashMapUnmanaged(i32, u64) = .empty;
    defer buckets.deinit(a);
    for (commits) |ci| {
        const gop = try buckets.getOrPut(a, monthKey(ci.time));
        if (!gop.found_existing) gop.value_ptr.* = 0;
    }
    var total: u64 = 0;
    var bit = best.iterator();
    while (bit.next()) |e| {
        const inf = store.info(e.key_ptr) catch return error.CorruptRepository;
        const gop = try buckets.getOrPut(a, monthKey(e.value_ptr.time));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += inf.size;
        total += inf.size;
    }

    var keys: std.ArrayList(i32) = .empty;
    defer keys.deinit(a);
    var kit = buckets.keyIterator();
    while (kit.next()) |k| try keys.append(a, k.*);
    std.mem.sort(i32, keys.items, {}, std.sort.asc(i32));

    const all = try allocator.alloc(MonthBucket, keys.items.len);
    var cumulative: u64 = 0;
    for (keys.items, all) |k, *slot| {
        cumulative += buckets.get(k).?;
        const year = @divFloor(k, 12);
        slot.* = .{
            .year = year,
            .month = @intCast(k - year * 12 + 1),
            .introduced_bytes = buckets.get(k).?,
            .cumulative_bytes = cumulative,
        };
    }

    var shown = all;
    if (months) |n| {
        if (n < all.len) shown = all[all.len - n ..];
    }
    return .{ .buckets = shown, .total_introduced_bytes = total };
}

test "monthKey and formatMonth" {
    // 2020-01-15T12:00:00Z
    const key = monthKey(1579099200);
    try std.testing.expectEqual(@as(i32, 2020 * 12), key);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("2020-01", formatMonth(&buf, key));
    try std.testing.expectEqualStrings("2021-02", formatMonth(&buf, monthKey(1613380800))); // 2021-02-15
    // Negative timestamps clamp to the epoch (1970-01).
    try std.testing.expectEqual(@as(i32, 1970 * 12), monthKey(-5));
    try std.testing.expectEqualStrings("1970-01", formatMonth(&buf, monthKey(-5)));
    // Round trip across a month boundary.
    try std.testing.expectEqualStrings("1999-12", formatMonth(&buf, monthKey(946684800 - 1)));
}

test "betterCandidate picks earliest time then earliest walk index" {
    const c1: Candidate = .{ .time = 100, .index = 5 };
    const c2: Candidate = .{ .time = 200, .index = 1 };
    const c3: Candidate = .{ .time = 100, .index = 9 };
    try std.testing.expect(betterCandidate(c1, c2));
    try std.testing.expect(!betterCandidate(c2, c1));
    try std.testing.expect(betterCandidate(c1, c3));
    try std.testing.expect(!betterCandidate(c3, c1));
    try std.testing.expect(!betterCandidate(c1, c1));
}

test "treeNameCompare sorts directories as name-slash" {
    const tree_entry: tree_mod.TreeEntry = .{ .mode = 0o040000, .name = "foo", .id = object_id.ObjectId.zero_sha1 };
    const file_entry: tree_mod.TreeEntry = .{ .mode = 0o100644, .name = "foo.txt", .id = object_id.ObjectId.zero_sha1 };
    const file2_entry: tree_mod.TreeEntry = .{ .mode = 0o100644, .name = "foo", .id = object_id.ObjectId.zero_sha1 };
    // "foo" tree vs "foo" blob: the tree compares as "foo/", after "foo".
    try std.testing.expect(treeNameCompare(&tree_entry, &file2_entry) == .gt);
    try std.testing.expect(treeNameCompare(&file2_entry, &tree_entry) == .lt);
    // "foo.txt" vs "foo" tree: '.' (0x2e) < '/' (0x2f).
    try std.testing.expect(treeNameCompare(&file_entry, &tree_entry) == .lt);
    try std.testing.expect(treeNameCompare(&tree_entry, &file_entry) == .gt);
    // Identical names and modes compare equal.
    try std.testing.expect(treeNameCompare(&file_entry, &file_entry) == .eq);
}
