const std = @import("std");
const object_id = @import("../git/object_id.zig");
const git_object = @import("../git/object.zig");
const object_store = @import("objects.zig");
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

/// Blob oid -> representative path, plus the set of blob oids present in the
/// tree at HEAD, plus the set of all objects found reachable during the
/// walk. All path strings live in a single arena.
pub const PathMap = struct {
    arena: std.heap.ArenaAllocator,
    /// First-seen representative path per blob (may not contain every blob).
    paths: std.HashMapUnmanaged(object_id.ObjectId, []const u8, object_id.ObjectId.Context, 80),
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
        return self.paths.get(id.*);
    }
};

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
            return peelToCommit(store, &t.object, depth + 1);
        },
        else => return null,
    }
}

const PendingCommit = struct {
    time: i64,
    id: object_id.ObjectId,
};

fn commitTimeLess(_: void, a: PendingCommit, b: PendingCommit) std.math.Order {
    // Max-heap by commit time: newest first.
    return std.math.order(b.time, a.time);
}

/// Compute representative paths and the current-blob set.
///
/// - `current`: every blob reachable from the tree at HEAD.
/// - `paths`: first-seen path per blob across the full reachable history
///   (all refs, commits visited newest-first by committer date), with trees
///   memoized so shared subtrees are only walked once.
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

    // Seed the history walk with all ref tips (committer date ordering).
    var queue: std.PriorityQueue(PendingCommit, void, commitTimeLess) = .empty;
    defer queue.deinit(allocator);
    var queued: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer queued.deinit(allocator);

    var time_scratch = std.heap.ArenaAllocator.init(allocator);
    defer time_scratch.deinit();

    // Ref targets the commit walk never visits: annotated tag objects on the
    // way to a commit, and tag targets that are trees or blobs directly.
    var tag_extra: std.ArrayList(object_id.ObjectId) = .empty;
    defer tag_extra.deinit(allocator);

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
        if (queued.contains(commit_oid)) continue;
        try queued.put(allocator, commit_oid, {});
        _ = time_scratch.reset(.retain_capacity);
        const time = commitCommitterTime(time_scratch.allocator(), store, &commit_oid) orelse 0;
        try queue.push(allocator, .{ .time = time, .id = commit_oid });
    }

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
                    walkTree(store, &map, &tree_oid, &prefix, scratch.allocator(), null, true, 0) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {},
                    };
                } else |_| {}
            }
        }
    }

    // Full history walk for representative paths.
    var visited: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer visited.deinit(allocator);
    var processed_trees: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer processed_trees.deinit(allocator);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    while (queue.pop()) |pc| {
        if (visited.contains(pc.id)) continue;
        try visited.put(allocator, pc.id, {});

        _ = scratch.reset(.retain_capacity);
        const payload = store.readPayload(scratch.allocator(), &pc.id) catch {
            continue;
        };
        if (payload.object_type != .commit) continue;
        const c = commit_mod.parse(payload.data, pc.id.algorithm, scratch.allocator()) catch continue;

        {
            var prefix: std.ArrayList(u8) = .empty;
            defer prefix.deinit(arena);
            walkTree(store, &map, &c.tree, &prefix, scratch.allocator(), &processed_trees, false, 0) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }

        for (c.parents) |p| {
            if (visited.contains(p) or queued.contains(p)) continue;
            try queued.put(allocator, p, {});
            _ = time_scratch.reset(.retain_capacity);
            const time = commitCommitterTime(time_scratch.allocator(), store, &p) orelse 0;
            try queue.push(allocator, .{ .time = time, .id = p });
        }
    }

    // Union everything the walk visited into `reachable`: commits, trees,
    // blobs, and annotated-tag extras. Callers get unreachable stats without
    // a second graph walk.
    var vit = visited.keyIterator();
    while (vit.next()) |k| try map.reachable.put(arena, k.*, {});
    var tit = processed_trees.keyIterator();
    while (tit.next()) |k| try map.reachable.put(arena, k.*, {});
    var bit = map.paths.keyIterator();
    while (bit.next()) |k| try map.reachable.put(arena, k.*, {});
    for (tag_extra.items) |t| try map.reachable.put(arena, t, {});

    return map;
}

fn commitCommitterTime(scratch: std.mem.Allocator, store: *const object_store.ObjectStore, commit_oid: *const object_id.ObjectId) ?i64 {
    const payload = store.readPayload(scratch, commit_oid) catch return null;
    if (payload.object_type != .commit) return null;
    const c = commit_mod.parse(payload.data, commit_oid.algorithm, scratch) catch return null;
    if (c.committer) |cm| return cm.timestamp;
    return null;
}

fn headTree(store: *const object_store.ObjectStore, commit_oid: *const object_id.ObjectId) !object_id.ObjectId {
    var scratch = std.heap.ArenaAllocator.init(store.allocator);
    defer scratch.deinit();
    const payload = try store.readPayload(scratch.allocator(), commit_oid);
    if (payload.object_type != .commit) return error.CorruptRepository;
    const c = try commit_mod.parse(payload.data, commit_oid.algorithm, scratch.allocator());
    return c.tree;
}

/// Recursively walk a tree, recording blob paths. When `mark_current` is
/// true, blobs are also added to the `current` set (no tree memoization:
/// HEAD walk is single-pass). Otherwise `processed` memoizes fully-walked
/// subtrees so shared history is only traversed once. `prefix` is caller
/// scratch space; entries are interned in the PathMap arena. `scratch` is a
/// caller-owned arena for payload reads — it must not be reset for the
/// duration of the walk (recursion shares it).
fn walkTree(
    store: *const object_store.ObjectStore,
    map: *PathMap,
    tree_oid: *const object_id.ObjectId,
    prefix: *std.ArrayList(u8),
    scratch: std.mem.Allocator,
    processed: ?*std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80),
    mark_current: bool,
    depth: usize,
) PathError!void {
    if (depth > max_tree_depth) return;
    const arena = map.arena.allocator();

    if (processed) |pt| {
        if (pt.contains(tree_oid.*)) return;
        try pt.put(store.allocator, tree_oid.*, {});
    }

    const payload = store.readPayload(scratch, tree_oid) catch return;
    if (payload.object_type != .tree) return;

    const base_len = prefix.items.len;
    var it = tree_mod.TreeIterator.init(payload.data, tree_oid.algorithm);
    while (it.next() catch return) |entry| {
        defer prefix.items.len = base_len;
        if (prefix.items.len > 0) try prefix.append(arena, '/');
        try prefix.appendSlice(arena, entry.name);

        switch (entry.entryMode()) {
            .tree => try walkTree(store, map, &entry.id, prefix, scratch, processed, mark_current, depth + 1),
            .blob, .other => {
                if (mark_current) {
                    try map.current.put(arena, entry.id, {});
                }
                const gop = try map.paths.getOrPut(arena, entry.id);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try arena.dupe(u8, prefix.items);
                }
            },
            .submodule => {},
        }
    }
}
