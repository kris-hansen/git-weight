const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const paths_mod = @import("paths.zig");
const largest_mod = @import("largest.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");

pub const DupesError = error{
    OutOfMemory,
    CorruptRepository,
    Unexpected,
};

pub const DupeGroup = struct {
    id: object_id.ObjectId,
    /// Logical blob size in bytes.
    size: u64,
    /// Distinct paths (sorted), capped at paths_mod.max_paths_per_blob.
    paths: []const []const u8,
    /// Distinct path count; a lower bound when `truncated`.
    path_count: u64,
    truncated: bool,
    /// size * (path_count - 1): bytes reclaimable if the blob lived at one
    /// path only. A lower bound when `truncated`.
    wasted_bytes: u64,
};

pub const DupesReport = struct {
    groups: []DupeGroup,
    total_wasted_bytes: u64,

    pub fn deinit(self: *DupesReport, allocator: std.mem.Allocator) void {
        for (self.groups) |g| allocator.free(g.paths);
        allocator.free(self.groups);
    }
};

/// Reclaimable bytes for a blob of `size` living at `path_count` distinct
/// paths: every copy past the first is redundant.
pub fn wastedBytes(size: u64, path_count: u64) u64 {
    if (path_count <= 1) return 0;
    return size * (path_count - 1);
}

/// Deterministic presentation order: wasted bytes descending, ties by oid.
pub fn groupOrderDesc(_: void, a: DupeGroup, b: DupeGroup) bool {
    if (a.wasted_bytes != b.wasted_bytes) return a.wasted_bytes > b.wasted_bytes;
    return std.mem.order(u8, a.id.bytes[0..a.id.rawLen()], b.id.bytes[0..b.id.rawLen()]) == .lt;
}

/// Duplicate-content groups: blobs whose identical content (same oid) lives
/// at 2+ distinct paths. `filter` selects the path universe: `.all` covers
/// every path in reachable history; `.historical_only` covers blobs no
/// longer present at HEAD (all their historical paths); `.current_only`
/// covers duplicate paths within the tree at HEAD (a dedicated HEAD walk —
/// historical copies of a current blob do not count). Groups are sorted by
/// reclaimable bytes and capped at `limit` (0 = unlimited).
pub fn build(
    store: *const object_store.ObjectStore,
    path_map: *const paths_mod.PathMap,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
    limit: usize,
    min_size: u64,
    filter: largest_mod.Filter,
) DupesError!DupesReport {
    return switch (filter) {
        .current_only => buildCurrent(store, refs, allocator, limit, min_size),
        else => buildHistory(store, path_map, allocator, limit, min_size, filter == .historical_only),
    };
}

const HeadPaths = struct {
    arena: std.heap.ArenaAllocator,
    map: std.HashMapUnmanaged(object_id.ObjectId, paths_mod.BlobPaths, object_id.ObjectId.Context, 80) = .empty,

    fn deinit(self: *HeadPaths) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

/// Walk the tree at HEAD recording blob -> distinct paths (same cap and
/// truncation rules as the main path walk).
fn collectHeadPaths(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
) DupesError!HeadPaths {
    var hp: HeadPaths = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer hp.deinit();
    const arena = hp.arena.allocator();

    if (refs.refs.items.len == 0) return hp;
    const head = refs.refs.items[refs.refs.items.len - 1];
    if (!std.mem.eql(u8, head.name, "HEAD")) return hp;
    const head_commit = paths_mod.peelToCommit(store, &head.target, 0) orelse return hp;

    var scratch = std.heap.ArenaAllocator.init(arena);
    const payload = store.readPayload(scratch.allocator(), &head_commit) catch return hp;
    defer payload.release();
    if (payload.object_type != .commit) return hp;
    const c = commit_mod.parse(payload.data, head_commit.algorithm, scratch.allocator()) catch return hp;

    var prefix: std.ArrayList(u8) = .empty;
    try walkHeadTree(store, &hp.map, arena, &c.tree, &prefix, scratch.allocator(), 0);
    return hp;
}

fn walkHeadTree(
    store: *const object_store.ObjectStore,
    map: *std.HashMapUnmanaged(object_id.ObjectId, paths_mod.BlobPaths, object_id.ObjectId.Context, 80),
    arena: std.mem.Allocator,
    tree_oid: *const object_id.ObjectId,
    prefix: *std.ArrayList(u8),
    scratch: std.mem.Allocator,
    depth: usize,
) DupesError!void {
    if (depth > 512) return;
    const payload = store.readPayload(scratch, tree_oid) catch return;
    defer payload.release();
    if (payload.object_type != .tree) return;

    const base_len = prefix.items.len;
    var it = tree_mod.TreeIterator.init(payload.data, tree_oid.algorithm);
    while (it.next() catch return) |entry| {
        defer prefix.items.len = base_len;
        if (prefix.items.len > 0) try prefix.append(arena, '/');
        try prefix.appendSlice(arena, entry.name);
        switch (entry.entryMode()) {
            .tree => try walkHeadTree(store, map, arena, &entry.id, prefix, scratch, depth + 1),
            .blob, .other => try paths_mod.recordBlobPath(map, arena, &entry.id, prefix.items),
            .submodule => {},
        }
    }
}

fn buildCurrent(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
    limit: usize,
    min_size: u64,
) DupesError!DupesReport {
    var hp = try collectHeadPaths(store, refs, allocator);
    defer hp.deinit();
    return finishGroups(store, &hp.map, allocator, limit, min_size);
}

fn buildHistory(
    store: *const object_store.ObjectStore,
    path_map: *const paths_mod.PathMap,
    allocator: std.mem.Allocator,
    limit: usize,
    min_size: u64,
    historical_only: bool,
) DupesError!DupesReport {
    var groups: std.ArrayList(DupeGroup) = .empty;
    defer groups.deinit(allocator);

    var it = path_map.paths.iterator();
    while (it.next()) |e| {
        const rec = e.value_ptr;
        if (rec.extra == null) continue; // single-path blob
        const pc = paths_mod.pathCount(rec);
        if (pc.count < 2) continue;

        const id = e.key_ptr.*;
        if (historical_only and path_map.isCurrent(&id)) continue;

        const inf = store.info(&id) catch return error.CorruptRepository;
        if (inf.size < min_size) continue;

        const all_paths = try allocator.alloc([]const u8, pc.count);
        all_paths[0] = rec.rep;
        @memcpy(all_paths[1..], rec.extra.?.items.items);
        std.mem.sort([]const u8, all_paths, {}, strLess);

        try groups.append(allocator, .{
            .id = id,
            .size = inf.size,
            .paths = all_paths,
            .path_count = pc.count,
            .truncated = pc.truncated,
            .wasted_bytes = wastedBytes(inf.size, pc.count),
        });
    }

    return finalize(&groups, allocator, limit);
}

fn finishGroups(
    store: *const object_store.ObjectStore,
    map: *const std.HashMapUnmanaged(object_id.ObjectId, paths_mod.BlobPaths, object_id.ObjectId.Context, 80),
    allocator: std.mem.Allocator,
    limit: usize,
    min_size: u64,
) DupesError!DupesReport {
    var groups: std.ArrayList(DupeGroup) = .empty;
    defer groups.deinit(allocator);

    var it = map.iterator();
    while (it.next()) |e| {
        const rec = e.value_ptr;
        if (rec.extra == null) continue;
        const pc = paths_mod.pathCount(rec);
        if (pc.count < 2) continue;

        const id = e.key_ptr.*;
        const inf = store.info(&id) catch return error.CorruptRepository;
        if (inf.size < min_size) continue;

        const all_paths = try allocator.alloc([]const u8, pc.count);
        all_paths[0] = rec.rep;
        @memcpy(all_paths[1..], rec.extra.?.items.items);
        std.mem.sort([]const u8, all_paths, {}, strLess);

        try groups.append(allocator, .{
            .id = id,
            .size = inf.size,
            .paths = all_paths,
            .path_count = pc.count,
            .truncated = pc.truncated,
            .wasted_bytes = wastedBytes(inf.size, pc.count),
        });
    }

    return finalize(&groups, allocator, limit);
}

fn finalize(groups: *std.ArrayList(DupeGroup), allocator: std.mem.Allocator, limit: usize) DupesError!DupesReport {
    std.mem.sort(DupeGroup, groups.items, {}, groupOrderDesc);
    if (limit > 0 and groups.items.len > limit) {
        for (groups.items[limit..]) |g| allocator.free(g.paths);
        groups.items.len = limit;
    }

    var total: u64 = 0;
    for (groups.items) |g| total += g.wasted_bytes;

    return .{
        .groups = try groups.toOwnedSlice(allocator),
        .total_wasted_bytes = total,
    };
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "wastedBytes scales with copies past the first" {
    try std.testing.expectEqual(@as(u64, 0), wastedBytes(100, 0));
    try std.testing.expectEqual(@as(u64, 0), wastedBytes(100, 1));
    try std.testing.expectEqual(@as(u64, 100), wastedBytes(100, 2));
    try std.testing.expectEqual(@as(u64, 3900), wastedBytes(1000, 3) + wastedBytes(100, 20));
}

test "groupOrderDesc sorts by wasted then oid" {
    const id_a = object_id.ObjectId.fromHex("81f43dc8215a9b66a3bb71b11ffde1a3542e1e0d") catch unreachable;
    const id_b = object_id.ObjectId.fromHex("91f43dc8215a9b66a3bb71b11ffde1a3542e1e0d") catch unreachable;
    const g_a: DupeGroup = .{ .id = id_a, .size = 0, .paths = &.{}, .path_count = 2, .truncated = false, .wasted_bytes = 100 };
    const g_b: DupeGroup = .{ .id = id_b, .size = 0, .paths = &.{}, .path_count = 2, .truncated = false, .wasted_bytes = 100 };
    const g_big: DupeGroup = .{ .id = id_b, .size = 0, .paths = &.{}, .path_count = 2, .truncated = false, .wasted_bytes = 200 };

    // Wasted descending wins over oid order.
    try std.testing.expect(groupOrderDesc({}, g_big, g_a));
    // Ties break by oid ascending.
    try std.testing.expect(groupOrderDesc({}, g_a, g_b));
    try std.testing.expect(!groupOrderDesc({}, g_b, g_a));
    // Reflexive.
    try std.testing.expect(!groupOrderDesc({}, g_a, g_a));
}
