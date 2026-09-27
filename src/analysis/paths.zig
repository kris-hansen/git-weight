const std = @import("std");
const object_id = @import("../git/object_id.zig");
const git_object = @import("../git/object.zig");
const object_store = @import("objects.zig");
const loose_mod = @import("../git/loose.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const tag_mod = @import("../git/tag.zig");

pub const PathError = error{
    OutOfMemory,
    CorruptRepository,
    Unexpected,
};

const max_tree_depth = 512;
const max_workers = 64;

/// Blob oid -> representative path, plus the set of blob oids present in the
/// tree at HEAD, plus the set of all objects found reachable during the
/// walk. All path strings live in a single arena.
pub const PathMap = struct {
    arena: std.heap.ArenaAllocator,
    /// Representative path per blob (may not contain every blob). Blobs in
    /// HEAD's tree always get their HEAD path; other blobs get the
    /// lexicographically smallest path seen (deterministic under
    /// parallelism). Values keep the extra distinct paths seen for blobs
    /// living at 2+ paths (see BlobPaths).
    paths: std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80),
    /// Blob oids present in HEAD's tree ("current").
    current: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80),
    /// Every object visited during the walk: all commits, trees, and blobs
    /// reachable from any ref, plus annotated tag objects on the way. Lets
    /// callers derive unreachable stats without a second graph walk.
    reachable: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80),

    pub fn deinit(self: *PathMap) void {
        self.paths.deinit(self.arena.allocator());
        self.current.deinit(self.arena.allocator());
        self.reachable.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn isCurrent(self: *const PathMap, id: *const object_id.ObjectId) bool {
        return self.current.contains(id.*);
    }

    pub fn pathOf(self: *const PathMap, id: *const object_id.ObjectId) ?[]const u8 {
        const v = self.paths.get(id.*) orelse return null;
        return v.rep;
    }
};

/// Maximum distinct paths retained per blob; beyond this the path list is
/// marked truncated (the path count becomes a lower bound).
pub const max_paths_per_blob = 32;

/// Distinct non-representative paths observed for a blob.
pub const ExtraPaths = struct {
    /// Arena-owned path strings (never freed individually).
    items: std.ArrayListUnmanaged([]const u8) = .empty,
    /// More than `max_paths_per_blob` distinct paths were seen.
    truncated: bool = false,
};

/// Per-blob path record: the representative path plus (lazily) the other
/// distinct paths the blob was seen at.
pub const BlobPaths = struct {
    /// Representative path: HEAD path when present, else smallest path.
    rep: []const u8,
    /// Additional distinct paths beyond `rep`; null until a second distinct
    /// path is seen.
    extra: ?*ExtraPaths = null,
};

/// Distinct paths observed for a blob (capped at `max_paths_per_blob`).
pub fn pathCount(v: *const BlobPaths) struct { count: u64, truncated: bool } {
    const ex = v.extra orelse return .{ .count = 1, .truncated = false };
    return .{ .count = 1 + ex.items.items.len, .truncated = ex.truncated };
}

/// Record `path` for `id`, keeping the lexicographically smallest path as
/// the representative (used by per-worker maps so merged representatives
/// stay deterministic under parallelism).
fn recordPathSmallest(
    map: *std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80),
    allocator: std.mem.Allocator,
    id: *const object_id.ObjectId,
    path: []const u8,
) PathError!void {
    const gop = try map.getOrPut(allocator, id.*);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .rep = try allocator.dupe(u8, path) };
        return;
    }
    const v = gop.value_ptr;
    if (std.mem.order(u8, path, v.rep) == .lt) {
        const old = v.rep;
        v.rep = try allocator.dupe(u8, path);
        try appendPath(v, allocator, old);
    } else {
        try appendPath(v, allocator, path);
    }
}

/// Record `path` for `id` in `map` (get-or-create semantics; first path
/// becomes the representative). Used by dupes' HEAD-only walk as well as
/// the main path walk.
pub fn recordBlobPath(
    map: *std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80),
    allocator: std.mem.Allocator,
    id: *const object_id.ObjectId,
    path: []const u8,
) PathError!void {
    const gop = try map.getOrPut(allocator, id.*);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .rep = try allocator.dupe(u8, path) };
        return;
    }
    try appendPath(gop.value_ptr, allocator, path);
}

/// Union another record's paths (its representative plus extras) into `v`.
fn mergeExtras(
    v: *BlobPaths,
    allocator: std.mem.Allocator,
    src: BlobPaths,
) PathError!void {
    try appendPath(v, allocator, src.rep);
    if (src.extra) |ex| {
        for (ex.items.items) |p| try appendPath(v, allocator, p);
        if (ex.truncated) v.extra.?.truncated = true;
    }
}

/// Add a non-representative path, keeping the list deduplicated and capped;
/// sets the truncated marker past the cap.
fn appendPath(v: *BlobPaths, allocator: std.mem.Allocator, path: []const u8) PathError!void {
    if (std.mem.eql(u8, v.rep, path)) return;
    if (v.extra == null) {
        const ex = try allocator.create(ExtraPaths);
        ex.* = .{};
        v.extra = ex;
    }
    const ex = v.extra.?;
    for (ex.items.items) |p| {
        if (std.mem.eql(u8, p, path)) return;
    }
    if (ex.items.items.len < max_paths_per_blob - 1) {
        try ex.items.append(allocator, try allocator.dupe(u8, path));
    } else {
        ex.truncated = true;
    }
}

/// Peel a ref target (possibly an annotated tag) down to a commit oid.
pub fn peelToCommit(store: *const object_store.ObjectStore, id: *const object_id.ObjectId, depth: usize) ?object_id.ObjectId {
    if (depth > 32) return null;
    const inf = store.info(id) catch return null;
    switch (inf.object_type) {
        .commit => return id.*,
        .tag => {
            var scratch = std.heap.ArenaAllocator.init(store.allocator);
            defer scratch.deinit();
            const payload = store.readPayload(scratch.allocator(), id) catch return null;
            const t = tag_mod.parse(payload.data, id.algorithm) catch return null;
            payload.release();
            return peelToCommit(store, &t.object, depth + 1);
        },
        else => return null,
    }
}

const CommitTree = struct {
    id: object_id.ObjectId,
    tree: object_id.ObjectId,
};

fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// Sharded claim set for tree oids. Each shard has its own spinlock and its
/// own arena (page-allocator backed), so concurrent claims never touch
/// shared allocator state.
const ClaimSet = struct {
    const n_shards = 64;

    const Shard = struct {
        mutex: std.atomic.Mutex = .unlocked,
        arena: std.heap.ArenaAllocator,
        set: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty,
    };

    shards: [n_shards]Shard,

    fn init() ClaimSet {
        var cs: ClaimSet = undefined;
        for (&cs.shards) |*s| {
            s.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
        }
        return cs;
    }

    fn deinit(self: *ClaimSet) void {
        for (&self.shards) |*s| s.arena.deinit();
    }

    /// True when this caller was the first to claim the tree.
    fn claim(self: *ClaimSet, id: *const object_id.ObjectId) PathError!bool {
        const s = &self.shards[id.bytes[0] & (n_shards - 1)];
        lockSpin(&s.mutex);
        defer s.mutex.unlock();
        const gop = s.set.getOrPut(s.arena.allocator(), id.*) catch return error.OutOfMemory;
        return !gop.found_existing;
    }
};

/// Shared state for the parallel tree walk: the precomputed reachable
/// commit list and an atomic chunk cursor. The commit-graph traversal that
/// builds the list is sequential and reads no trees; the expensive tree
/// walk shards perfectly over it.
const WalkShared = struct {
    commits: []const CommitTree = &.{},
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
};

/// Per-worker state for the history phase: private arenas, payload caches,
/// prefix buffer, and a local blob->path map merged deterministically after
/// the walk.
const Worker = struct {
    store: *const object_store.ObjectStore,
    shared: *WalkShared,
    claims: *ClaimSet,
    base: *const PathMap,
    /// Payload reads and commit parsing; reset per commit.
    scratch: std.heap.ArenaAllocator,
    /// Owns local_paths entries and strings.
    arena: std.heap.ArenaAllocator,
    local_paths: std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80) = .empty,
    prefix: std.ArrayList(u8) = .empty,

    fn deinit(self: *Worker) void {
        self.scratch.deinit();
        self.arena.deinit();
    }
};

const WalkTarget = union(enum) {
    /// HEAD phase (sequential): record into the shared map, mark current.
    shared: *PathMap,
    /// History phase (per worker): record into a local map, skipping blobs
    /// already present in the shared map (HEAD paths win).
    local: *Worker,
};

/// Compute representative paths, the current-blob set, and the reachable set.
///
/// HEAD's tree is walked first (sequential) so HEAD paths win. The history
/// walk then runs on `store.threads` workers pulling commits newest-first
/// from a shared queue; trees are claimed atomically so each is walked once.
/// Worker-local path maps merge into the result with a deterministic rule
/// (lexicographically smallest path).
pub fn compute(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
) PathError!PathMap {
    var map: PathMap = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .paths = .empty,
        .current = .empty,
        .reachable = .empty,
    };
    errdefer map.deinit();
    const arena = map.arena.allocator();

    var shared: WalkShared = .{};

    var bfs_scratch = std.heap.ArenaAllocator.init(allocator);
    defer bfs_scratch.deinit();

    // Ref targets the commit walk never visits: annotated tag objects on the
    // way to a commit, and tag targets that are trees or blobs directly.
    var tag_extra: std.ArrayList(object_id.ObjectId) = .empty;
    defer tag_extra.deinit(allocator);

    // Sequential commit-graph walk: collect every reachable commit and its
    // root tree. Commits covered by the commit-graph file are resolved from
    // it (no payload inflation); anything absent falls back to object
    // parsing below. Reads no trees; cheap relative to the tree walk.
    var visited: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer visited.deinit(allocator);
    var stack: std.ArrayList(object_id.ObjectId) = .empty;
    defer stack.deinit(allocator);
    var commits: std.ArrayList(CommitTree) = .empty;
    defer commits.deinit(allocator);
    var graph_parent_buf: std.ArrayList(u32) = .empty;
    defer graph_parent_buf.deinit(allocator);

    for (refs.refs.items) |r| {
        {
            var target = r.target;
            while (true) {
                const inf = store.info(&target) catch break;
                if (inf.object_type != .tag) break;
                try tag_extra.append(allocator, target);
                var tscratch = std.heap.ArenaAllocator.init(allocator);
                defer tscratch.deinit();
                const payload = store.readPayload(tscratch.allocator(), &target) catch break;
                const t = tag_mod.parse(payload.data, target.algorithm) catch break;
                payload.release();
                target = t.object;
            }
            // The final non-tag target of an annotated tag chain.
            if (!target.eql(&r.target)) try tag_extra.append(allocator, target);
        }
        const commit_oid = peelToCommit(store, &r.target, 0) orelse {
            // Tag (or other ref) pointing at a tree or blob: mark the target.
            try tag_extra.append(allocator, r.target);
            continue;
        };
        if (visited.contains(commit_oid)) continue;
        try visited.put(allocator, commit_oid, {});
        try stack.append(allocator, commit_oid);
    }

    while (stack.pop()) |id| {
        // Commit-graph fast path: same parent list, same push order, so the
        // DFS pop order (and thus everything downstream) is identical to
        // the payload-parse path.
        if (store.graph) |*g| {
            if (g.lookup(&id)) |pos| {
                const resolved = g.entry(pos, allocator, &graph_parent_buf) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidGraph => null,
                };
                if (resolved) |ent| {
                    try commits.append(allocator, .{ .id = id, .tree = ent.tree });
                    for (ent.parents) |pp| {
                        const p = g.oidAt(pp);
                        if (visited.contains(p)) continue;
                        try visited.put(allocator, p, {});
                        try stack.append(allocator, p);
                    }
                    continue;
                }
            }
        }
        _ = bfs_scratch.reset(.retain_capacity);
        const payload = store.readPayload(bfs_scratch.allocator(), &id) catch continue;
        if (payload.object_type != .commit) continue;
        const c = commit_mod.parse(payload.data, id.algorithm, bfs_scratch.allocator()) catch continue;
        payload.release();
        try commits.append(allocator, .{ .id = id, .tree = c.tree });
        for (c.parents) |p| {
            if (visited.contains(p)) continue;
            try visited.put(allocator, p, {});
            try stack.append(allocator, p);
        }
    }
    shared.commits = commits.items;

    var claims = ClaimSet.init();
    defer claims.deinit();

    // Current tree at HEAD (walked first so HEAD paths win). HEAD was
    // appended last by refs.readAll.
    if (refs.refs.items.len > 0) {
        const head = refs.refs.items[refs.refs.items.len - 1];
        if (std.mem.eql(u8, head.name, "HEAD")) {
            if (peelToCommit(store, &head.target, 0)) |head_commit| {
                if (headTree(store, &head_commit)) |tree_oid| {
                    var scratch = std.heap.ArenaAllocator.init(allocator);
                    defer scratch.deinit();
                    var prefix: std.ArrayList(u8) = .empty;
                    defer prefix.deinit(arena);
                    walkTree(store, &claims, .{ .shared = &map }, &tree_oid, &prefix, scratch.allocator(), 0) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                } else |_| {}
            }
        }
    }

    // Full history walk, parallel across workers. Worker structs must stay
    // put once threads see them.
    // Explicit usize: @min against a comptime bound would otherwise infer
    // a narrow type for the worker count.
    const n_workers: usize = @max(1, @min(store.threads, max_workers));
    if (n_workers > 1) {
        // Pre-resolve loose headers so workers only read shared loose state
        // (lazy resolution writes back into the list).
        for (store.loose.objects.items) |*o| {
            _ = loose_mod.resolveHeader(o) catch continue;
        }
    }
    var workers_buf: [max_workers]Worker = undefined;
    var n_init: usize = 0;
    defer for (workers_buf[0..n_init]) |*w| w.deinit();

    if (shared.commits.len > 0) {
        for (0..n_workers) |i| {
            workers_buf[i] = initWorker(store, &shared, &claims, &map);
            n_init += 1;
        }
        if (n_workers == 1) {
            workerRun(&workers_buf[0]);
        } else {
            var spawned: usize = 0;
            var handles: [max_workers]?std.Thread = .{null} ** max_workers;
            for (workers_buf[0 .. n_workers - 1], 0..) |*w, i| {
                handles[i] = std.Thread.spawn(.{}, workerRun, .{w}) catch null;
                if (handles[i] != null) spawned += 1;
            }
            workerRun(&workers_buf[n_workers - 1]);
            for (0..spawned) |i| handles[i].?.join();
        }
    }
    if (shared.failed.load(.acquire)) return error.OutOfMemory;

    // Merge worker-local path records. HEAD blobs (already in `paths` with
    // their HEAD path, and present in `current`) only gain extra paths —
    // their representative paths are final. Other blobs pick the
    // lexicographically smallest representative across workers, with all
    // observed extra paths unioned.
    for (workers_buf[0..n_init]) |*w| {
        var it = w.local_paths.iterator();
        while (it.next()) |e| {
            if (!map.current.contains(e.key_ptr.*)) continue;
            const gop = try map.paths.getOrPut(arena, e.key_ptr.*);
            if (gop.found_existing) try mergeExtras(gop.value_ptr, arena, e.value_ptr.*);
        }
    }
    for (workers_buf[0..n_init]) |*w| {
        var it = w.local_paths.iterator();
        while (it.next()) |e| {
            if (map.current.contains(e.key_ptr.*)) continue;
            const gop = try map.paths.getOrPut(arena, e.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .rep = try arena.dupe(u8, e.value_ptr.rep) };
            } else if (std.mem.order(u8, e.value_ptr.rep, gop.value_ptr.rep) == .lt) {
                gop.value_ptr.rep = try arena.dupe(u8, e.value_ptr.rep);
            }
            try mergeExtras(gop.value_ptr, arena, e.value_ptr.*);
        }
    }

    // Union everything the walk visited into `reachable`: commits, trees,
    // blobs, and annotated-tag extras. Callers get unreachable stats without
    // a second graph walk.
    var qit = visited.keyIterator();
    while (qit.next()) |k| try map.reachable.put(arena, k.*, {});
    for (&claims.shards) |*s| {
        var tit = s.set.keyIterator();
        while (tit.next()) |k| try map.reachable.put(arena, k.*, {});
    }
    var bit = map.paths.keyIterator();
    while (bit.next()) |k| try map.reachable.put(arena, k.*, {});
    for (tag_extra.items) |t| try map.reachable.put(arena, t, {});

    return map;
}

fn initWorker(
    store: *const object_store.ObjectStore,
    shared: *WalkShared,
    claims: *ClaimSet,
    base: *const PathMap,
) Worker {
    return .{
        .store = store,
        .shared = shared,
        .claims = claims,
        .base = base,
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
}

fn workerRun(w: *Worker) void {
    const chunk = 256;
    while (true) {
        const start = w.shared.next.fetchAdd(chunk, .monotonic);
        if (start >= w.shared.commits.len) return;
        const end = @min(w.shared.commits.len, start + chunk);
        for (w.shared.commits[start..end]) |*ct| {
            if (w.shared.failed.load(.acquire)) return;
            _ = w.scratch.reset(.retain_capacity);
            w.prefix.clearRetainingCapacity();
            walkTree(w.store, w.claims, .{ .local = w }, &ct.tree, &w.prefix, w.scratch.allocator(), 0) catch {
                fail(w);
                return;
            };
        }
    }
}

fn fail(w: *Worker) void {
    w.shared.failed.store(true, .release);
}

fn headTree(store: *const object_store.ObjectStore, commit_oid: *const object_id.ObjectId) !object_id.ObjectId {
    var scratch = std.heap.ArenaAllocator.init(store.allocator);
    defer scratch.deinit();
    const payload = try store.readPayload(scratch.allocator(), commit_oid);
    if (payload.object_type != .commit) return error.CorruptRepository;
    const c = try commit_mod.parse(payload.data, commit_oid.algorithm, scratch.allocator());
    payload.release();
    return c.tree;
}

/// Recursively walk a tree, recording blob paths. Trees are claimed
/// atomically so each is walked once across all workers. `prefix` is caller
/// scratch space. `scratch` must not be reset for the duration of the walk
/// (recursion shares it).
fn walkTree(
    store: *const object_store.ObjectStore,
    claims: *ClaimSet,
    target: WalkTarget,
    tree_oid: *const object_id.ObjectId,
    prefix: *std.ArrayList(u8),
    scratch: std.mem.Allocator,
    depth: usize,
) PathError!void {
    if (depth > max_tree_depth) return;
    if (!try claims.claim(tree_oid)) return;

    const payload = store.readPayload(scratch, tree_oid) catch return;
    if (payload.object_type != .tree) return;
    // Held across the recursive reads below: the iterator borrows payload
    // data (entry names), and the pin keeps it valid even if a nested read
    // evicts this entry from the cache.
    defer payload.release();

    const base_len = prefix.items.len;
    var it = tree_mod.TreeIterator.init(payload.data, tree_oid.algorithm);
    while (it.next() catch return) |entry| {
        defer prefix.items.len = base_len;
        const prefix_allocator = switch (target) {
            .shared => |map| map.arena.allocator(),
            .local => |w| w.arena.allocator(),
        };
        if (prefix.items.len > 0) try prefix.append(prefix_allocator, '/');
        try prefix.appendSlice(prefix_allocator, entry.name);

        switch (entry.entryMode()) {
            .tree => try walkTree(store, claims, target, &entry.id, prefix, scratch, depth + 1),
            .blob, .other => switch (target) {
                .shared => |map| {
                    const arena = map.arena.allocator();
                    try map.current.put(arena, entry.id, {});
                    try recordBlobPath(&map.paths, arena, &entry.id, prefix.items);
                },
                .local => |w| {
                    try recordPathSmallest(&w.local_paths, w.arena.allocator(), &entry.id, prefix.items);
                },
            },
            .submodule => {},
        }
    }
}

test "recordPath dedupes, caps, and marks truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var map: std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80) = .empty;
    defer map.deinit(alloc);
    const id = object_id.ObjectId.zero_sha1;

    try recordBlobPath(&map, alloc, &id, "b.txt");
    var pc = pathCount(&map.get(id).?);
    try std.testing.expectEqual(@as(u64, 1), pc.count);
    try std.testing.expect(!pc.truncated);

    // Duplicate path: no-op.
    try recordBlobPath(&map, alloc, &id, "b.txt");
    pc = pathCount(&map.get(id).?);
    try std.testing.expectEqual(@as(u64, 1), pc.count);

    try recordBlobPath(&map, alloc, &id, "a.txt");
    pc = pathCount(&map.get(id).?);
    try std.testing.expectEqual(@as(u64, 2), pc.count);
    try std.testing.expectEqualStrings("b.txt", map.get(id).?.rep); // first wins

    // Fill to the cap, then overflow sets truncated.
    var i: usize = 0;
    while (i < max_paths_per_blob + 4) : (i += 1) {
        var buf: [32]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "p{d:0>3}.bin", .{i}) catch unreachable;
        try recordBlobPath(&map, alloc, &id, p);
    }
    pc = pathCount(&map.get(id).?);
    try std.testing.expectEqual(@as(u64, max_paths_per_blob), pc.count);
    try std.testing.expect(pc.truncated);
}

test "recordPathSmallest keeps smallest representative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var map: std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80) = .empty;
    defer map.deinit(alloc);
    const id = object_id.ObjectId.zero_sha1;

    try recordPathSmallest(&map, alloc, &id, "z/late.bin");
    try recordPathSmallest(&map, alloc, &id, "a/early.bin");
    try recordPathSmallest(&map, alloc, &id, "m/mid.bin");
    const v = map.get(id).?;
    try std.testing.expectEqualStrings("a/early.bin", v.rep);
    const pc = pathCount(&v);
    try std.testing.expectEqual(@as(u64, 3), pc.count);
}

test "mergeExtras unions and propagates truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var dst_map: std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80) = .empty;
    defer dst_map.deinit(alloc);
    var src_map: std.HashMapUnmanaged(object_id.ObjectId, BlobPaths, object_id.ObjectId.Context, 80) = .empty;
    defer src_map.deinit(alloc);
    const id = object_id.ObjectId.zero_sha1;

    try recordBlobPath(&dst_map, alloc, &id, "shared.bin");
    try recordBlobPath(&src_map, alloc, &id, "other.bin");
    try mergeExtras(dst_map.getPtr(id).?, alloc, src_map.get(id).?);
    var pc = pathCount(&dst_map.get(id).?);
    try std.testing.expectEqual(@as(u64, 2), pc.count);
    try std.testing.expect(!pc.truncated);

    // Merge a truncated source: truncation propagates, count still capped.
    const id2 = object_id.ObjectId{ .algorithm = .sha1, .bytes = [_]u8{1} ** 32 };
    try recordBlobPath(&dst_map, alloc, &id2, "x.bin");
    try recordBlobPath(&src_map, alloc, &id2, "y.bin");
    var i: usize = 0;
    while (i < max_paths_per_blob + 2) : (i += 1) {
        var buf: [32]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "q{d:0>3}.bin", .{i}) catch unreachable;
        try recordBlobPath(&src_map, alloc, &id2, p);
    }
    try std.testing.expect(pathCount(&src_map.get(id2).?).truncated);
    try mergeExtras(dst_map.getPtr(id2).?, alloc, src_map.get(id2).?);
    pc = pathCount(&dst_map.get(id2).?);
    try std.testing.expect(pc.truncated);
    try std.testing.expectEqual(@as(u64, max_paths_per_blob), pc.count);
}
