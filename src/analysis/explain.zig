const std = @import("std");
const object_id = @import("../git/object_id.zig");
const git_object = @import("../git/object.zig");
const object_store = @import("objects.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const tag_mod = @import("../git/tag.zig");
const loose_mod = @import("../git/loose.zig");
const pack_mod = @import("../git/pack/pack.zig");
const paths_mod = @import("paths.zig");
const reachability = @import("reachability.zig");
const largest_mod = @import("largest.zig");

const max_workers = 64;

pub const ExplainError = error{
    OutOfMemory,
    SystemResources,
    NotFound,
    CorruptRepository,
    UnsupportedFormat,
    Unexpected,
};

/// A single remediation step: a tool name plus the exact command line.
/// `command` is owned by the Remediation; `tool` is a literal.
pub const Command = struct {
    tool: []const u8,
    command: []const u8,
};

/// What reclaiming the object requires, mirroring the reclaimable verdict.
pub const Verdict = enum {
    /// Unreachable: reclaimable via standard gc.
    gc,
    /// Reachable but not in the HEAD tree: requires history rewriting.
    history_rewrite,
    /// Part of the current tree: nothing reclaimable today.
    none,

    pub fn name(self: Verdict) []const u8 {
        return switch (self) {
            .gc => "gc",
            .history_rewrite => "history_rewrite",
            .none => "none",
        };
    }
};

/// Copy-pasteable fix for the diagnosed object. Only ever contains commands
/// for a verdict the analysis actually computed; `commands` may be empty
/// when no exact command can be derived (e.g. no known path), in which case
/// `caveat` explains what is required. All strings are owned.
pub const Remediation = struct {
    verdict: Verdict,
    commands: []Command,
    /// Owned warning that accompanies history-rewriting steps, or null.
    caveat: ?[]const u8,
    /// Git LFS migration plan for a candidate blob still present at HEAD.
    lfs: ?LfsPlan,

    pub const LfsPlan = struct {
        /// include-pattern for `git lfs migrate` (`*.ext`, or the path).
        pattern: []const u8,
        command: []const u8,
    };

    pub fn deinit(self: *Remediation, allocator: std.mem.Allocator) void {
        for (self.commands) |c| allocator.free(c.command);
        allocator.free(self.commands);
        if (self.caveat) |c| allocator.free(c);
        if (self.lfs) |l| {
            allocator.free(l.pattern);
            allocator.free(l.command);
        }
    }
};

/// Wrap `s` in single quotes for safe shell pasting (embedded quotes become
/// '\'').
fn shellQuote(allocator: std.mem.Allocator, s: []const u8) ExplainError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn basename(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
}

/// Derive the remediation playbook strictly from the computed verdict.
/// `path` may be null (e.g. an unreachable blob no tree references); no
/// path-dependent command is emitted without one.
pub fn buildRemediation(
    allocator: std.mem.Allocator,
    object_type: git_object.ObjectType,
    logical_bytes: u64,
    path: ?[]const u8,
    reachable: bool,
    reachable_from_head: bool,
) ExplainError!Remediation {
    var commands: std.ArrayList(Command) = .empty;
    errdefer commands.deinit(allocator);
    var caveat: ?[]const u8 = null;
    var lfs: ?Remediation.LfsPlan = null;

    const verdict: Verdict = if (!reachable)
        .gc
    else if (!reachable_from_head)
        .history_rewrite
    else
        .none;

    switch (verdict) {
        .gc => try commands.append(allocator, .{
            .tool = "git",
            .command = try allocator.dupe(
                u8,
                "git reflog expire --expire=now --all && git gc --prune=now --aggressive",
            ),
        }),
        .history_rewrite => {
            if (path) |p| {
                const quoted = try shellQuote(allocator, p);
                defer allocator.free(quoted);
                const filter_repo = std.fmt.allocPrint(allocator, "git filter-repo --invert-paths --path {s}", .{quoted}) catch return error.OutOfMemory;
                const bfg = std.fmt.allocPrint(allocator, "bfg --delete-files {s}", .{basename(p)}) catch return error.OutOfMemory;
                try commands.append(allocator, .{ .tool = "git-filter-repo", .command = filter_repo });
                try commands.append(allocator, .{ .tool = "BFG Repo-Cleaner", .command = bfg });
                caveat = try allocator.dupe(u8, "Rewrites history: force-push afterwards and have collaborators re-clone. Never rewrite shared history casually.");
            }
        },
        .none => {
            // LFS only helps blobs that remain in the tree; for historical
            // blobs the filter-repo step above is the fix.
            if (object_type == .blob and largest_mod.isLfsCandidate(logical_bytes, path)) {
                const pattern = if (largest_mod.extensionOf(path.?)) |ext|
                    std.fmt.allocPrint(allocator, "*.{s}", .{ext}) catch return error.OutOfMemory
                else
                    try allocator.dupe(u8, path.?);
                const qpattern = try shellQuote(allocator, pattern);
                defer allocator.free(qpattern);
                const command = std.fmt.allocPrint(allocator, "git lfs migrate import --include={s} --everything", .{
                    qpattern,
                }) catch return error.OutOfMemory;
                lfs = .{ .pattern = pattern, .command = command };
            }
        },
    }

    return .{
        .verdict = verdict,
        .commands = commands.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .caveat = caveat,
        .lfs = lfs,
    };
}

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
    /// Copy-pasteable remediation derived from the verdict above.
    remediation: Remediation,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.retained_by);
        self.remediation.deinit(allocator);
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

/// True when `s` is 4-64 hex characters (either case). Callers that know
/// the repository's hash algorithm should additionally cap `s` at its hex
/// width (resolveTarget does) so a sha1 repo never prefix-matches a 64-char
/// string against its 40-char ids.
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
    if (target.len <= store.algorithm.hexLen() and looksLikeHexPrefix(target)) {
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
        if (!std.mem.eql(u8, e.value_ptr.rep, target)) continue;
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
        // Only mode/id are used from the entry; the name borrows the
        // payload, which is released before returning.
        const entry = treeEntryAt(store, scratch.allocator(), &current, comps[i]) orelse return false;
        if (i == comps.len - 1) return entry.id.eql(want);
        if (entry.entryMode() != .tree) return false;
        current = entry.id;
    }
    return false;
}

/// The entry named `name` directly under tree `tree_oid`, or null. The
/// payload borrow is released before returning; the caller must not use
/// `entry.name`.
fn treeEntryAt(
    store: *const object_store.ObjectStore,
    allocator: std.mem.Allocator,
    tree_oid: *const object_id.ObjectId,
    name: []const u8,
) ?tree_mod.TreeEntry {
    const payload = store.readPayload(allocator, tree_oid) catch return null;
    defer payload.release();
    if (payload.object_type != .tree) return null;
    var it = tree_mod.TreeIterator.init(payload.data, tree_oid.algorithm);
    while (it.next() catch null) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

const CommitInfo = struct {
    id: object_id.ObjectId,
    time: i64,
    author: ?[]const u8,
    /// Parent oids, owned by the arena passed to collectCommits.
    parents: []const object_id.ObjectId,
    /// Root tree of this commit.
    tree: object_id.ObjectId,
    /// Whether `want` is present at `comps` under `tree`.
    present: bool,
};

const Collected = struct {
    /// Every commit reachable from any ref (including HEAD), in DFS pop
    /// order — the same order the sequential walk produced, so
    /// introduced/deleted selection (first-strictly-earliest) is unchanged.
    commits: std.ArrayList(CommitInfo),
    /// Distinct root trees of `commits`, deduplicated in first-seen order.
    trees: std.ArrayList(object_id.ObjectId),
};

/// Walk every commit reachable from any ref (including HEAD), recording
/// committer time, author, parents, and root tree. Commits covered by the
/// commit-graph are resolved from it without inflating payloads (authors
/// are not stored there and stay null; analyzeHistory fetches the at most
/// two it needs); everything else reads commit payloads (no trees). The
/// expensive per-tree presence check runs separately, sharded across
/// workers. Slice fields are owned by `arena`.
fn collectCommits(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    arena: std.mem.Allocator,
) ExplainError!Collected {
    var commits: std.ArrayList(CommitInfo) = .empty;
    errdefer commits.deinit(arena);
    var trees: std.ArrayList(object_id.ObjectId) = .empty;
    errdefer trees.deinit(arena);

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

    // Checkpoint-style histories reuse the same tree across many commits;
    // presence is computed once per distinct tree.
    var seen_trees: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer seen_trees.deinit(arena);

    while (stack.pop()) |id| {
        // Commit-graph fast path: identical parent order to the payload
        // parse, so the DFS pop order is unchanged.
        if (store.graph) |*g| {
            if (g.lookup(&id)) |pos| {
                const resolved = g.entry(pos, arena, &graph_parent_buf) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidGraph => null,
                };
                if (resolved) |ent| {
                    if (!seen_trees.contains(ent.tree)) {
                        try seen_trees.put(arena, ent.tree, {});
                        try trees.append(arena, ent.tree);
                    }
                    const parents = try arena.alloc(object_id.ObjectId, ent.parents.len);
                    for (ent.parents, 0..) |pp, i| parents[i] = g.oidAt(pp);
                    try commits.append(arena, .{
                        .id = id,
                        .time = ent.time,
                        .author = null, // not in the graph; see analyzeHistory
                        .parents = parents,
                        .tree = ent.tree,
                        .present = false,
                    });
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

        if (!seen_trees.contains(c.tree)) {
            try seen_trees.put(arena, c.tree, {});
            try trees.append(arena, c.tree);
        }
        try commits.append(arena, .{
            .id = id,
            .time = if (c.committer) |cm| cm.timestamp else 0,
            .author = if (c.author) |a| try arena.dupe(u8, a.ident) else null,
            .parents = try arena.dupe(object_id.ObjectId, c.parents),
            .tree = c.tree,
            .present = false,
        });

        for (c.parents) |p| {
            if (visited.contains(p)) continue;
            try visited.put(arena, p, {});
            try stack.append(arena, p);
        }
    }
    return .{ .commits = commits, .trees = trees };
}

const PresenceCtx = struct {
    store: *const object_store.ObjectStore,
    trees: []const object_id.ObjectId,
    comps: []const []const u8,
    want: *const object_id.ObjectId,
    next: std.atomic.Value(usize) = .init(0),
};

/// Compute `blobPresentAtPath` for a shard of distinct trees pulled from a
/// shared chunk cursor. Each tree is computed exactly once; results land in
/// disjoint `results` slots, so no synchronization beyond the cursor is
/// needed and the outcome is independent of scheduling.
fn presenceWorker(ctx: *PresenceCtx, results: []bool) void {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const chunk = 256;
    while (true) {
        const start = ctx.next.fetchAdd(chunk, .monotonic);
        if (start >= ctx.trees.len) return;
        const end = @min(ctx.trees.len, start + chunk);
        for (ctx.trees[start..end], start..) |*tree, i| {
            _ = scratch.reset(.retain_capacity);
            results[i] = blobPresentAtPath(ctx.store, &scratch, tree, ctx.comps, ctx.want);
        }
    }
}

/// Presence of `want` at `comps` under every tree in `trees`, as a map.
fn computePresence(
    store: *const object_store.ObjectStore,
    arena: std.mem.Allocator,
    trees: []const object_id.ObjectId,
    comps: []const []const u8,
    want: *const object_id.ObjectId,
) ExplainError!std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) {
    var presence: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    errdefer presence.deinit(arena);
    if (trees.len == 0) return presence;

    const results = try arena.alloc(bool, trees.len);
    const n_workers = @max(1, @min(store.threads, max_workers));
    if (n_workers > 1) {
        // Workers share the loose list; resolve lazy headers up front so the
        // write-back in readPayload is race-free (same trick as paths.zig).
        for (store.loose.objects.items) |*o| {
            _ = loose_mod.resolveHeader(o) catch continue;
        }
        var ctx: PresenceCtx = .{
            .store = store,
            .trees = trees,
            .comps = comps,
            .want = want,
        };
        var handles: [max_workers]?std.Thread = .{null} ** max_workers;
        var spawned: usize = 0;
        for (0..n_workers - 1) |i| {
            handles[i] = std.Thread.spawn(.{}, presenceWorker, .{ &ctx, results }) catch null;
            if (handles[i] != null) spawned += 1;
        }
        presenceWorker(&ctx, results);
        for (0..spawned) |i| handles[i].?.join();
    } else {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        for (trees, 0..) |*tree, i| {
            _ = scratch.reset(.retain_capacity);
            results[i] = blobPresentAtPath(store, &scratch, tree, comps, want);
        }
    }

    for (trees, results) |t, p| try presence.put(arena, t, p);
    return presence;
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

    var collected = try collectCommits(store, refs, arena);
    defer collected.commits.deinit(arena);
    defer collected.trees.deinit(arena);

    var presence = try computePresence(store, arena, collected.trees.items, comps.items, want);
    defer presence.deinit(arena);

    var present_by_id: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    defer present_by_id.deinit(arena);
    for (collected.commits.items) |*ci| {
        ci.present = presence.get(ci.tree) orelse false;
        try present_by_id.put(arena, ci.id, ci.present);
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

    var history = pickHistory(collected.commits.items, &present_by_id, head_present);
    // Commits served from the commit-graph have no author (CDAT does not
    // store one). The report needs at most two: inflate exactly those
    // payloads rather than every payload in history.
    if (history.introduced) |*c| {
        if (c.author == null) c.author = try commitAuthorIdent(store, arena, &c.id);
    }
    if (history.deleted) |*c| {
        if (c.author == null) c.author = try commitAuthorIdent(store, arena, &c.id);
    }
    return history;
}

/// Author ident "Name <email>" of a commit, or null when the payload is
/// unavailable or unparseable. `arena` owns the returned string.
fn commitAuthorIdent(
    store: *const object_store.ObjectStore,
    arena: std.mem.Allocator,
    id: *const object_id.ObjectId,
) ExplainError!?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    const payload = store.readPayload(scratch.allocator(), id) catch return null;
    defer payload.release();
    if (payload.object_type != .commit) return null;
    const c = commit_mod.parse(payload.data, id.algorithm, scratch.allocator()) catch return null;
    return if (c.author) |a| try arena.dupe(u8, a.ident) else null;
}

/// Select introducing/deleting commits from walk-ordered commits: the
/// earliest by committer time wins, and on equal timestamps the commit
/// earliest in walk order wins (the comparison is strictly-less while
/// scanning in order). `present_by_id` must contain an entry for every
/// commit in `commits` and any of their parents present in the walk.
fn pickHistory(
    commits: []const CommitInfo,
    present_by_id: *const std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80),
    head_present: bool,
) History {
    var introduced: ?CommitRef = null;
    var deleted: ?CommitRef = null;
    for (commits) |ci| {
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

    if (head_present) deleted = null;
    return .{ .introduced = introduced, .deleted = deleted };
}

/// Which refs (excluding HEAD) retain `id`, full names sorted alphabetically.
/// Refs sharing a target oid are walked once. The per-target reachability
/// walks run sharded across workers; each worker keeps its own
/// negative-reachability memo (objects proven unable to reach `id`), which
/// only ever short-circuits walks, so results are scheduling-independent.
fn retainingRefs(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    id: *const object_id.ObjectId,
    allocator: std.mem.Allocator,
) ExplainError![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);

    var by_target: std.HashMapUnmanaged(object_id.ObjectId, std.ArrayList([]const u8), object_id.ObjectId.Context, 80) = .empty;
    defer {
        var git = by_target.iterator();
        while (git.next()) |e| e.value_ptr.deinit(allocator);
        by_target.deinit(allocator);
    }
    for (refs.refs.items) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        const gop = try by_target.getOrPut(allocator, r.target);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, r.name);
    }

    const targets = try allocator.alloc(object_id.ObjectId, by_target.count());
    defer allocator.free(targets);
    {
        var i: usize = 0;
        var it = by_target.iterator();
        while (it.next()) |e| {
            targets[i] = e.key_ptr.*;
            i += 1;
        }
    }

    const n_workers = @max(1, @min(store.threads, max_workers));
    const use = @min(n_workers, targets.len);
    if (use > 1) {
        // Workers share the loose list; resolve lazy headers up front so the
        // write-back in info/readPayload is race-free (same trick as
        // paths.zig).
        for (store.loose.objects.items) |*o| {
            _ = loose_mod.resolveHeader(o) catch continue;
        }
    }

    var ctx: RetainCtx = .{
        .store = store,
        .by_target = &by_target,
        .targets = targets,
        .id = id,
    };

    var workers_buf: [max_workers]RetainWorker = undefined;
    var n_init: usize = 0;
    defer for (workers_buf[0..n_init]) |*w| w.deinit();

    if (use > 1) {
        for (0..use) |i| {
            workers_buf[i] = try initRetainWorker(&ctx);
            n_init += 1;
        }
        var spawned: usize = 0;
        var handles: [max_workers]?std.Thread = .{null} ** max_workers;
        for (workers_buf[0 .. use - 1], 0..) |*w, i| {
            handles[i] = std.Thread.spawn(.{}, retainRun, .{w}) catch null;
            if (handles[i] != null) spawned += 1;
        }
        retainRun(&workers_buf[use - 1]);
        for (0..spawned) |i| handles[i].?.join();
    } else if (targets.len > 0) {
        workers_buf[0] = try initRetainWorker(&ctx);
        n_init = 1;
        retainRun(&workers_buf[0]);
    }
    if (ctx.failed.load(.acquire)) return error.OutOfMemory;

    for (workers_buf[0..n_init]) |*w| {
        try names.appendSlice(allocator, w.names.items);
    }
    const slice = try names.toOwnedSlice(allocator);
    std.mem.sort([]const u8, slice, {}, strLess);
    return slice;
}

const RetainCtx = struct {
    store: *const object_store.ObjectStore,
    by_target: *const std.HashMapUnmanaged(object_id.ObjectId, std.ArrayList([]const u8), object_id.ObjectId.Context, 80),
    targets: []const object_id.ObjectId,
    id: *const object_id.ObjectId,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
};

const RetainWorker = struct {
    ctx: *RetainCtx,
    /// Owns unreachable_from entries, info caches, and collected names.
    arena: std.heap.ArenaAllocator,
    /// Payload reads; reset per walk.
    scratch: std.heap.ArenaAllocator,
    /// Per-pack delta-chain memoization; the store's built-in info caches
    /// are not thread-safe (one slot per pack).
    info_caches: []pack_mod.Pack.InfoCache = &.{},
    unreachable_from: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty,
    names: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *RetainWorker) void {
        self.arena.deinit();
        self.scratch.deinit();
    }
};

fn initRetainWorker(ctx: *RetainCtx) ExplainError!RetainWorker {
    var w: RetainWorker = .{
        .ctx = ctx,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    errdefer w.deinit();
    w.info_caches = w.arena.allocator().alloc(pack_mod.Pack.InfoCache, ctx.store.packs.items.len) catch return error.OutOfMemory;
    for (w.info_caches) |*c| c.* = .empty;
    return w;
}

/// Pull targets one at a time (each is a full graph walk) and record the ref
/// names of targets that reach `id`.
fn retainRun(w: *RetainWorker) void {
    const a = w.arena.allocator();
    while (true) {
        const i = w.ctx.next.fetchAdd(1, .monotonic);
        if (i >= w.ctx.targets.len) return;
        if (w.ctx.failed.load(.acquire)) return;
        const tip = &w.ctx.targets[i];
        const reaches = reachesObject(w.ctx.store, tip, w.ctx.id, &w.unreachable_from, a, w.info_caches, &w.scratch) catch {
            w.ctx.failed.store(true, .release);
            return;
        };
        if (reaches) {
            const ref_names = w.ctx.by_target.get(tip.*).?.items;
            w.names.appendSlice(a, ref_names) catch {
                w.ctx.failed.store(true, .release);
                return;
            };
        }
    }
}

/// Whether `id` is reachable from `tip`. `unreachable_from` memoizes objects
/// proven — by a walk that completed without finding `id` — to not reach it;
/// its entries are allocated from `memo_alloc` and live across walks.
/// `caches` memoizes pack delta chains (per-worker). `scratch` is
/// caller-owned (one per worker) and reset per object.
fn reachesObject(
    store: *const object_store.ObjectStore,
    tip: *const object_id.ObjectId,
    id: *const object_id.ObjectId,
    unreachable_from: *std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80),
    memo_alloc: std.mem.Allocator,
    caches: []pack_mod.Pack.InfoCache,
    scratch: *std.heap.ArenaAllocator,
) ExplainError!bool {
    var visited: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer visited.deinit(std.heap.page_allocator);
    var stack: std.ArrayList(object_id.ObjectId) = .empty;
    defer stack.deinit(std.heap.page_allocator);
    try stack.append(std.heap.page_allocator, tip.*);

    const found = found: while (stack.pop()) |oid| {
        if (oid.eql(id)) break :found true;
        if (visited.contains(oid)) continue;
        if (unreachable_from.contains(oid)) continue;
        try visited.put(std.heap.page_allocator, oid, {});

        const inf = store.infoWithCache(memo_alloc, &oid, caches) catch continue;
        _ = scratch.reset(.retain_capacity);
        switch (inf.object_type) {
            .commit => {
                const payload = store.readPayload(scratch.allocator(), &oid) catch continue;
                const c = commit_mod.parse(payload.data, oid.algorithm, scratch.allocator()) catch continue;
                payload.release();
                try stack.append(std.heap.page_allocator, c.tree);
                try stack.appendSlice(std.heap.page_allocator, c.parents);
            },
            .tree => {
                const payload = store.readPayload(scratch.allocator(), &oid) catch continue;
                var it = tree_mod.TreeIterator.init(payload.data, oid.algorithm);
                while (it.next() catch null) |entry| {
                    switch (entry.entryMode()) {
                        .tree, .blob, .other => try stack.append(std.heap.page_allocator, entry.id),
                        .submodule => {},
                    }
                }
                payload.release();
            },
            .tag => {
                const payload = store.readPayload(scratch.allocator(), &oid) catch continue;
                const t = tag_mod.parse(payload.data, oid.algorithm) catch continue;
                payload.release();
                try stack.append(std.heap.page_allocator, t.object);
            },
            else => {},
        }
    } else false;

    if (!found) {
        var it = visited.keyIterator();
        while (it.next()) |k| try unreachable_from.put(memo_alloc, k.*, {});
    }
    return found;
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

    // "From HEAD" answers whether the object is part of the current tree:
    // for blobs that is the HEAD-tree membership test; other object types
    // use plain tip reachability from HEAD. The HEAD walk is computed at
    // most once and is shared with the fallback reachability check below.
    var from_head: ?reachability.Reachable = null;
    defer if (from_head) |*fh| fh.deinit();

    var reachable_from_head = false;
    if (inf.object_type == .blob) {
        reachable_from_head = path_map.isCurrent(&id);
    } else if (refs.refs.items.len > 0) {
        const head = refs.refs.items[refs.refs.items.len - 1];
        if (std.mem.eql(u8, head.name, "HEAD")) {
            from_head = try reachability.computeFromTips(store, &.{head.target}, allocator);
            reachable_from_head = from_head.?.contains(&id);
        }
    }

    // Reachable from any ref (including HEAD). retainingRefs covers every
    // ref except HEAD, so only when nothing retains the object do we need a
    // HEAD walk — reused from above when it already ran.
    var reachable = retained_by.len > 0;
    if (!reachable and refs.refs.items.len > 0) {
        const head = refs.refs.items[refs.refs.items.len - 1];
        if (std.mem.eql(u8, head.name, "HEAD")) {
            if (from_head == null) {
                from_head = try reachability.computeFromTips(store, &.{head.target}, allocator);
            }
            reachable = from_head.?.contains(&id);
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
        .remediation = try buildRemediation(allocator, inf.object_type, inf.size, path, reachable, reachable_from_head),
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

fn oidFromByte(b: u8) object_id.ObjectId {
    var id: object_id.ObjectId = .{ .algorithm = .sha1 };
    id.bytes[19] = b;
    return id;
}

fn commitInfo(id: object_id.ObjectId, time: i64, parents: []const object_id.ObjectId, present: bool) CommitInfo {
    return .{ .id = id, .time = time, .author = null, .parents = parents, .tree = id, .present = present };
}

test "pickHistory selects earliest by committer time" {
    const a = std.testing.allocator;
    var present_by_id: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    defer present_by_id.deinit(a);

    const c1 = oidFromByte(1);
    const c2 = oidFromByte(2);
    const c3 = oidFromByte(3);
    const commits = [_]CommitInfo{
        commitInfo(c1, 300, &.{}, true), // blob appears; no parents
        commitInfo(c2, 100, &.{c1}, true), // present, parent present: not a candidate
        commitInfo(c3, 200, &.{c2}, false), // absent, parent present: deleted
    };
    for (commits) |ci| try present_by_id.put(a, ci.id, ci.present);

    const history = pickHistory(&commits, &present_by_id, false);
    try std.testing.expect(history.introduced != null);
    try std.testing.expect(history.introduced.?.id.eql(&c1));
    try std.testing.expect(history.introduced.?.timestamp == 300);
    try std.testing.expect(history.deleted != null);
    try std.testing.expect(history.deleted.?.id.eql(&c3));
}

test "pickHistory timestamp ties resolve to earliest in walk order" {
    const a = std.testing.allocator;
    var present_by_id: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    defer present_by_id.deinit(a);

    // Both c1 and c2 introduce the blob at the same committer time; c1 is
    // earlier in walk (list) order and must win, matching the sequential
    // strictly-less scan.
    const c1 = oidFromByte(1);
    const c2 = oidFromByte(2);
    const c3 = oidFromByte(3);
    const commits = [_]CommitInfo{
        commitInfo(c1, 100, &.{}, true),
        commitInfo(c2, 100, &.{c1}, true),
        commitInfo(c3, 100, &.{c2}, false),
    };
    for (commits) |ci| try present_by_id.put(a, ci.id, ci.present);

    const history = pickHistory(&commits, &present_by_id, false);
    try std.testing.expect(history.introduced.?.id.eql(&c1));
    try std.testing.expect(history.deleted.?.id.eql(&c3));
}

test "pickHistory deleted is null when blob is present at HEAD" {
    const a = std.testing.allocator;
    var present_by_id: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    defer present_by_id.deinit(a);

    const c1 = oidFromByte(1);
    const c2 = oidFromByte(2);
    const commits = [_]CommitInfo{
        commitInfo(c1, 100, &.{}, true),
        commitInfo(c2, 200, &.{c1}, false),
    };
    for (commits) |ci| try present_by_id.put(a, ci.id, ci.present);

    const history = pickHistory(&commits, &present_by_id, true);
    try std.testing.expect(history.introduced != null);
    try std.testing.expect(history.deleted == null);
}

test "pickHistory ignores present commits with present parents" {
    const a = std.testing.allocator;
    var present_by_id: std.HashMapUnmanaged(object_id.ObjectId, bool, object_id.ObjectId.Context, 80) = .empty;
    defer present_by_id.deinit(a);

    const c1 = oidFromByte(1);
    const c2 = oidFromByte(2);
    const c3 = oidFromByte(3);
    // Merge: c3 has two parents, blob present throughout; no commit has
    // present-without-parents (c1 is a root and present — the introducer),
    // and nothing is deleted.
    const commits = [_]CommitInfo{
        commitInfo(c1, 100, &.{}, true),
        commitInfo(c2, 90, &.{}, true), // earlier time, but tie rule favors first in order for equal times only
        commitInfo(c3, 200, &.{ c1, c2 }, true),
    };
    for (commits) |ci| try present_by_id.put(a, ci.id, ci.present);

    const history = pickHistory(&commits, &present_by_id, true);
    // Earliest introduction is c2 (time 90 < 100).
    try std.testing.expect(history.introduced.?.id.eql(&c2));
    try std.testing.expect(history.deleted == null);
}

test "buildRemediation gc verdict for unreachable objects" {
    const a = std.testing.allocator;
    var r = try buildRemediation(a, .blob, 700_000, null, false, false);
    defer r.deinit(a);
    try std.testing.expect(r.verdict == .gc);
    try std.testing.expect(r.commands.len == 1);
    try std.testing.expectEqualStrings("git", r.commands[0].tool);
    try std.testing.expect(std.mem.indexOf(u8, r.commands[0].command, "git gc --prune=now --aggressive") != null);
    try std.testing.expect(r.caveat == null);
    try std.testing.expect(r.lfs == null);
}

test "buildRemediation history rewrite with exact path commands" {
    const a = std.testing.allocator;
    var r = try buildRemediation(a, .blob, 3_000_000, "database/prod.sql", true, false);
    defer r.deinit(a);
    try std.testing.expect(r.verdict == .history_rewrite);
    try std.testing.expect(r.commands.len == 2);
    try std.testing.expect(std.mem.indexOf(u8, r.commands[0].command, "git filter-repo --invert-paths --path 'database/prod.sql'") != null);
    try std.testing.expectEqualStrings("bfg --delete-files prod.sql", r.commands[1].command);
    try std.testing.expect(r.caveat != null and std.mem.indexOf(u8, r.caveat.?, "Rewrites history") != null);
    // Historical blob: LFS does not apply.
    try std.testing.expect(r.lfs == null);
}

test "buildRemediation emits no path commands without a known path" {
    const a = std.testing.allocator;
    var r = try buildRemediation(a, .blob, 3_000_000, null, true, false);
    defer r.deinit(a);
    try std.testing.expect(r.verdict == .history_rewrite);
    try std.testing.expect(r.commands.len == 0);
    try std.testing.expect(r.caveat == null);
}

test "buildRemediation lfs plan for current candidate blob" {
    const a = std.testing.allocator;
    var r = try buildRemediation(a, .blob, 1_000_000, "assets/demo.mov", true, true);
    defer r.deinit(a);
    try std.testing.expect(r.verdict == .none);
    try std.testing.expect(r.commands.len == 0);
    try std.testing.expect(r.lfs != null);
    try std.testing.expectEqualStrings("*.mov", r.lfs.?.pattern);
    try std.testing.expectEqualStrings("git lfs migrate import --include='*.mov' --everything", r.lfs.?.command);

    // Small text file at HEAD: no remediation at all.
    var plain = try buildRemediation(a, .blob, 100, "README.md", true, true);
    defer plain.deinit(a);
    try std.testing.expect(plain.verdict == .none);
    try std.testing.expect(plain.lfs == null);
}

test "shellQuote escapes embedded quotes" {
    const a = std.testing.allocator;
    const q = try shellQuote(a, "it's/here");
    defer a.free(q);
    try std.testing.expectEqualStrings("'it'\\''s/here'", q);
}
