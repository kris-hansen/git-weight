const std = @import("std");
const object_id = @import("../git/object_id.zig");
const git_object = @import("../git/object.zig");
const object_store = @import("objects.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const paths_mod = @import("paths.zig");
const reachability = @import("reachability.zig");

pub const ExplainError = error{
    OutOfMemory,
    SystemResources,
    NotFound,
    CorruptRepository,
    UnsupportedFormat,
    Unexpected,
};

/// A commit relevant to the target's history.
pub const CommitRef = struct {
    id: object_id.ObjectId,
    /// Committer timestamp (seconds since epoch).
    timestamp: i64,
    /// Author "Name <email>" ident (borrowed from a scratch arena that
    /// outlives the report; see build()).
    author: ?[]const u8,
};

pub const Report = struct {
    id: object_id.ObjectId,
    object_type: git_object.ObjectType,
    logical_bytes: u64,
    physical_bytes: u64,
    /// Representative path, when known.
    path: ?[]const u8,
    introduced: ?CommitRef,
    deleted: ?CommitRef,
    /// Full names of refs (excluding HEAD) retaining the object, sorted.
    /// Names are borrowed from the `Refs` passed to build(); the slice
    /// itself is owned. Author idents in introduced/deleted are owned.
    retained_by: [][]const u8,
    reachable: bool,
    /// Whether the object is part of the current tree at HEAD.
    reachable_from_head: bool,
    /// Physical bytes reclaimable if the object were dropped.
    reclaimable_bytes: u64,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.retained_by);
        if (self.introduced) |c| {
            if (c.author) |a| allocator.free(a);
        }
        if (self.deleted) |c| {
            if (c.author) |a| allocator.free(a);
        }
    }
};

/// Resolution outcome: either the target resolved to a single object, or a
/// hex prefix matched several objects (count carried for the error message).
pub const Resolved = union(enum) {
    object: object_id.ObjectId,
    ambiguous_prefix: usize,
};

/// True when `s` is 4-64 hex characters (either case).
pub fn looksLikeHexPrefix(s: []const u8) bool {
    if (s.len < 4 or s.len > 64) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Resolve a target argument: hex-prefix object ids first (falling through
/// to path lookup on zero matches), then representative paths (largest blob
/// wins when several blobs share a path).
pub fn resolveTarget(
    store: *const object_store.ObjectStore,
    path_map: *const paths_mod.PathMap,
    target: []const u8,
) ExplainError!Resolved {
    if (looksLikeHexPrefix(target)) {
        var lower_buf: [64]u8 = undefined;
        const prefix = std.ascii.lowerString(&lower_buf, target);
        var match: ?object_id.ObjectId = null;
        var matches: usize = 0;
        var it = store.locations.iterator();
        while (it.next()) |e| {
            var hbuf: [64]u8 = undefined;
            const hex = e.key_ptr.hex(&hbuf);
            if (hex.len < prefix.len) continue;
            if (!std.mem.eql(u8, hex[0..prefix.len], prefix)) continue;
            matches += 1;
            match = e.key_ptr.*;
        }
        if (matches == 1) return .{ .object = match.? };
        if (matches > 1) return .{ .ambiguous_prefix = matches };
        // Zero matches: fall through to path lookup.
    }

    // Path lookup: blobs whose representative path equals the target.
    var best: ?object_id.ObjectId = null;
    var best_size: u64 = 0;
    var it = path_map.paths.iterator();
    while (it.next()) |e| {
        if (!std.mem.eql(u8, e.value_ptr.*, target)) continue;
        const inf = store.info(e.key_ptr) catch continue;
        if (best == null or inf.size > best_size) {
            best = e.key_ptr.*;
            best_size = inf.size;
        }
    }
    if (best) |id| return .{ .object = id };
    return error.NotFound;
}

/// Format a Unix timestamp as "YYYY-MM-DD" (UTC). `buf` must be at least
/// 16 bytes. Negative timestamps clamp to the epoch.
pub fn formatDate(buf: []u8, timestamp: i64) []const u8 {
    const secs: u64 = if (timestamp < 0) 0 else @intCast(timestamp);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    }) catch unreachable;
}

/// Whether blob `want` is stored at `comps` (path components) under the tree
/// `tree_oid`. Unreadable trees count as absent.
fn blobPresentAtPath(
    store: *const object_store.ObjectStore,
    scratch: *std.heap.ArenaAllocator,
    tree_oid: *const object_id.ObjectId,
    comps: []const []const u8,
    want: *const object_id.ObjectId,
) bool {
    var current = tree_oid.*;
    var i: usize = 0;
    while (i < comps.len) : (i += 1) {
        _ = scratch.reset(.retain_capacity);
        const payload = store.readPayload(scratch.allocator(), &current) catch return false;
        if (payload.object_type != .tree) return false;
        var found: ?tree_mod.TreeEntry = null;
        var it = tree_mod.TreeIterator.init(payload.data, current.algorithm);
        while (it.next() catch return false) |entry| {
            if (std.mem.eql(u8, entry.name, comps[i])) {
                found = entry;
                break;
            }
        }
        const entry = found orelse return false;
        if (i == comps.len - 1) return entry.id.eql(want);
        if (entry.entryMode() != .tree) return false;
        current = entry.id;
    }
    return false;
}

const CommitInfo = struct {
    id: object_id.ObjectId,
    time: i64,
    author: ?[]const u8,
    /// Parent oids, owned by the arena passed to walkCommits.
    parents: []const object_id.ObjectId,
    present: bool,
};

/// Walk every commit reachable from any ref (including HEAD), recording
/// committer time, author, parents, and whether `want` is present at
/// `comps`. Slice fields are owned by `arena`.
fn walkCommits(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    arena: std.mem.Allocator,
    comps: []const []const u8,
    want: *const object_id.ObjectId,
) ExplainError!std.ArrayList(CommitInfo) {
    var commits: std.ArrayList(CommitInfo) = .empty;
    errdefer commits.deinit(arena);

    var visited: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer visited.deinit(arena);
    var stack: std.ArrayList(object_id.ObjectId) = .empty;
    defer stack.deinit(arena);

    for (refs.refs.items) |r| {
        const tip = paths_mod.peelToCommit(store, &r.target, 0) orelse continue;
        if (visited.contains(tip)) continue;
        try visited.put(arena, tip, {});
        try stack.append(arena, tip);
    }

    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();

    while (stack.pop()) |id| {
        _ = scratch.reset(.retain_capacity);
        const payload = store.readPayload(scratch.allocator(), &id) catch continue;
        if (payload.object_type != .commit) continue;
        const c = commit_mod.parse(payload.data, id.algorithm, scratch.allocator()) catch continue;

        // blobPresentAtPath resets the scratch arena, invalidating the
        // commit payload — intern everything needed first.
        const parents = try arena.dupe(object_id.ObjectId, c.parents);
        const author: ?[]const u8 = if (c.author) |a| try arena.dupe(u8, a.ident) else null;
        const present = blobPresentAtPath(store, &scratch, &c.tree, comps, want);
        try commits.append(arena, .{
            .id = id,
            .time = if (c.committer) |cm| cm.timestamp else 0,
            .author = author,
            .parents = parents,
            .present = present,
        });

        for (parents) |p| {
            if (visited.contains(p)) continue;
            try visited.put(arena, p, {});
            try stack.append(arena, p);
        }
    }
    return commits;
}

const History = struct {
    introduced: ?CommitRef,
    deleted: ?CommitRef,
};

/// Find the introducing and (when the blob is gone from HEAD) deleting
/// commits across all reachable history.
fn analyzeHistory(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    arena: std.mem.Allocator,
    path: []const u8,
    want: *const object_id.ObjectId,
) ExplainError!History {
    var comps: std.ArrayList([]const u8) = .empty;
    defer comps.deinit(arena);
    var split = std.mem.splitScalar(u8, path, '/');
    while (split.next()) |comp| {
        if (comp.len == 0) continue;
        try comps.append(arena, comp);
    }
    if (comps.items.len == 0) return .{ .introduced = null, .deleted = null };

    var commits = try walkCommits(store, refs, arena, comps.items, want);
    defer commits.deinit(arena);

    var present_by_id: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    defer present_by_id.deinit(arena);
    for (commits.items) |ci| {
        try present_by_id.put(arena, ci.id, ci.present);
    }

    var introduced: ?CommitRef = null;
    var deleted: ?CommitRef = null;
    for (commits.items) |ci| {
        var any_parent_present = false;
        for (ci.parents) |p| {
            if (present_by_id.get(p) orelse false) {
                any_parent_present = true;
                break;
            }
        }
        const cand: CommitRef = .{ .id = ci.id, .timestamp = ci.time, .author = ci.author };
        if (ci.present and !any_parent_present) {
            if (introduced == null or ci.time < introduced.?.timestamp) introduced = cand;
        }
        if (!ci.present and any_parent_present) {
            if (deleted == null or ci.time < deleted.?.timestamp) deleted = cand;
        }
    }

    // A "deleted" commit only counts when the blob is absent from HEAD.
    var head_present = false;
    if (refs.refs.items.len > 0) {
        const head = refs.refs.items[refs.refs.items.len - 1];
        if (std.mem.eql(u8, head.name, "HEAD")) {
            if (paths_mod.peelToCommit(store, &head.target, 0)) |hc| {
                head_present = present_by_id.get(hc) orelse false;
            }
        }
    }
    if (head_present) deleted = null;

    return .{ .introduced = introduced, .deleted = deleted };
}

/// Which refs (excluding HEAD) retain `id`, full names sorted alphabetically.
fn retainingRefs(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    id: *const object_id.ObjectId,
    allocator: std.mem.Allocator,
) ExplainError![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (refs.refs.items) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        var reach = try reachability.computeFromTips(store, &.{r.target}, allocator);
        defer reach.deinit();
        if (reach.contains(id)) try names.append(allocator, r.name);
    }
    const slice = try names.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, strLess);
    return slice;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Build the full explain report for a resolved object (spec §6.3). The
/// returned report borrows path strings from `path_map` and ref names from
/// `refs`; only `retained_by`'s slice is owned (see deinit).
pub fn build(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    path_map: *const paths_mod.PathMap,
    id: object_id.ObjectId,
    allocator: std.mem.Allocator,
) ExplainError!Report {
    const inf = try store.info(&id);
    const physical = try store.physicalSize(&id);

    const path: ?[]const u8 = if (inf.object_type == .blob) path_map.pathOf(&id) else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var introduced: ?CommitRef = null;
    var deleted: ?CommitRef = null;
    if (path) |p| {
        const history = try analyzeHistory(store, refs, arena.allocator(), p, &id);
        // Author idents live in the scratch arena; intern the selected ones.
        if (history.introduced) |c| {
            introduced = .{
                .id = c.id,
                .timestamp = c.timestamp,
                .author = if (c.author) |a| try allocator.dupe(u8, a) else null,
            };
        }
        if (history.deleted) |c| {
            deleted = .{
                .id = c.id,
                .timestamp = c.timestamp,
                .author = if (c.author) |a| try allocator.dupe(u8, a) else null,
            };
        }
    }

    const retained_by = try retainingRefs(store, refs, &id, allocator);

    var all = try reachability.computeAll(store, refs, allocator);
    defer all.deinit();
    const reachable = all.contains(&id);

    // "From HEAD" answers whether the object is part of the current tree:
    // for blobs that is the HEAD-tree membership test; other object types
    // use plain tip reachability from HEAD.
    var reachable_from_head = false;
    if (inf.object_type == .blob) {
        reachable_from_head = path_map.isCurrent(&id);
    } else if (refs.refs.items.len > 0) {
        const head = refs.refs.items[refs.refs.items.len - 1];
        if (std.mem.eql(u8, head.name, "HEAD")) {
            var from_head = try reachability.computeFromTips(store, &.{head.target}, allocator);
            defer from_head.deinit();
            reachable_from_head = from_head.contains(&id);
        }
    }

    return .{
        .id = id,
        .object_type = inf.object_type,
        .logical_bytes = inf.size,
        .physical_bytes = physical,
        .path = path,
        .introduced = introduced,
        .deleted = deleted,
        .retained_by = retained_by,
        .reachable = reachable,
        .reachable_from_head = reachable_from_head,
        .reclaimable_bytes = physical,
    };
}

test "hex prefix detection" {
    try std.testing.expect(looksLikeHexPrefix("9ac810e"));
    try std.testing.expect(looksLikeHexPrefix("ABCDEF0123"));
    try std.testing.expect(!looksLikeHexPrefix("abc"));
    try std.testing.expect(!looksLikeHexPrefix("database/prod.sql"));
    try std.testing.expect(!looksLikeHexPrefix("zzzzz"));
    try std.testing.expect(!looksLikeHexPrefix(""));
}

test "civil date formatting" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01", formatDate(&buf, 0));
    try std.testing.expectEqualStrings("2019-03-11", formatDate(&buf, 1552272000));
    try std.testing.expectEqualStrings("2000-02-29", formatDate(&buf, 951782400));
    try std.testing.expectEqualStrings("2038-01-19", formatDate(&buf, 2147483647));
    try std.testing.expectEqualStrings("1970-01-01", formatDate(&buf, -5));
}
