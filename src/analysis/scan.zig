const std = @import("std");
const object_id = @import("../git/object_id.zig");
const git_object = @import("../git/object.zig");
const loose_mod = @import("../git/loose.zig");
const pack_mod = @import("../git/pack/pack.zig");
const object_store = @import("objects.zig");
const paths_mod = @import("paths.zig");
const largest_mod = @import("largest.zig");
const reachability = @import("reachability.zig");

pub const ScanError = error{
    OutOfMemory,
    CorruptRepository,
};

pub const ScanResult = struct {
    stats: object_store.ObjectStats,
    /// Top blobs by logical size (empty when no path map was given).
    top: []largest_mod.BlobEntry,
    historical_bytes: u64,
    unreachable_stats: reachability.UnreachableStats,
};

/// One pass over every object in the store, computing type stats, top blobs,
/// historical weight, and unreachable stats together. Sharded across
/// `store.threads` workers over contiguous pack-index and loose-list ranges;
/// each worker resolves pack infos through its own per-pack cache.
pub fn fullScan(
    store: *object_store.ObjectStore,
    path_map: ?*const paths_mod.PathMap,
    reachable: ?*const reachability.Reachable,
    limit: usize,
    min_size: u64,
    filter: largest_mod.Filter,
    allocator: std.mem.Allocator,
) ScanError!ScanResult {
    const n_threads = @max(1, @min(store.threads, 64));

    // Build the shard list: contiguous index ranges per pack, plus loose
    // ranges.
    var shards: std.ArrayList(Shard) = .empty;
    defer shards.deinit(allocator);
    for (store.packs.items, 0..) |*pf, pack_id| {
        const count: usize = pf.pack.index.count;
        const per = @max(1024, count / (n_threads * 4) + 1);
        var start: usize = 0;
        while (start < count) : (start += per) {
            try shards.append(allocator, .{ .pack = .{ .pack_id = pack_id, .start = start, .end = @min(count, start + per) } });
        }
    }
    {
        const count = store.loose.objects.items.len;
        const per = @max(256, count / (n_threads * 4) + 1);
        var start: usize = 0;
        while (start < count) : (start += per) {
            try shards.append(allocator, .{ .loose = .{ .start = start, .end = @min(count, start + per) } });
        }
    }

    const results = try allocator.alloc(ShardResult, shards.items.len);
    for (results) |*r| r.* = .{};

    var next: std.atomic.Value(usize) = .init(0);
    var oom: std.atomic.Value(bool) = .init(false);
    var ctx: Ctx = .{
        .store = store,
        .path_map = path_map,
        .reachable = reachable,
        .limit = limit,
        .min_size = min_size,
        .filter = filter,
        .shards = shards.items,
        .results = results,
        .next = &next,
        .oom = &oom,
    };

    const workers = @min(n_threads, shards.items.len);
    if (workers <= 1) {
        worker(&ctx);
    } else {
        var handles: [64]?std.Thread = .{null} ** 64;
        // Main thread participates; spawn workers - 1 helpers.
        for (0..workers - 1) |i| {
            handles[i] = std.Thread.spawn(.{}, worker, .{&ctx}) catch null;
        }
        worker(&ctx);
        for (0..workers - 1) |i| {
            if (handles[i]) |h| h.join();
        }
    }
    if (ctx.oom.load(.acquire)) return error.OutOfMemory;

    // Merge shard results.
    var merged: ScanResult = .{
        .stats = .{},
        .top = &.{},
        .historical_bytes = 0,
        .unreachable_stats = .{ .count = 0, .logical_bytes = 0, .physical_bytes = 0 },
    };
    var heap: std.PriorityQueue(largest_mod.BlobEntry, void, largest_mod.sizeGreater) = .empty;
    for (results) |*r| {
        inline for (.{ "blob", "tree", "commit", "tag" }) |f| {
            const s = &@field(merged.stats, f);
            const o = @field(r.stats, f);
            s.count += o.count;
            s.logical_bytes += o.logical_bytes;
        }
        merged.historical_bytes += r.historical_bytes;
        merged.unreachable_stats.count += r.unreachable_stats.count;
        merged.unreachable_stats.logical_bytes += r.unreachable_stats.logical_bytes;
        merged.unreachable_stats.physical_bytes += r.unreachable_stats.physical_bytes;
        for (r.heap.items) |e| {
            if (heap.count() < limit) {
                try heap.push(allocator, e);
            } else if (limit > 0 and heap.peek().?.size < e.size) {
                _ = heap.pop();
                try heap.push(allocator, e);
            }
        }
        r.heap.deinit(std.heap.page_allocator);
    }
    const top = heap.items;
    std.mem.sort(largest_mod.BlobEntry, top, {}, largest_mod.entryOrderDesc);
    merged.top = top;
    return merged;
}

const Shard = union(enum) {
    pack: struct { pack_id: usize, start: usize, end: usize },
    loose: struct { start: usize, end: usize },
};

const ShardResult = struct {
    stats: object_store.ObjectStats = .{},
    heap: std.PriorityQueue(largest_mod.BlobEntry, void, largest_mod.sizeGreater) = .empty,
    historical_bytes: u64 = 0,
    unreachable_stats: reachability.UnreachableStats = .{ .count = 0, .logical_bytes = 0, .physical_bytes = 0 },
};

const Ctx = struct {
    store: *object_store.ObjectStore,
    path_map: ?*const paths_mod.PathMap,
    reachable: ?*const reachability.Reachable,
    limit: usize,
    min_size: u64,
    filter: largest_mod.Filter,
    shards: []const Shard,
    results: []ShardResult,
    next: *std.atomic.Value(usize),
    oom: *std.atomic.Value(bool),
};

fn worker(ctx: *Ctx) void {
    // Worker-local arenas and caches; never shared with other threads.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info_caches = a.alloc(pack_mod.Pack.InfoCache, ctx.store.packs.items.len) catch {
        ctx.oom.store(true, .release);
        return;
    };
    for (info_caches) |*c| c.* = .empty;

    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.shards.len) return;
        if (ctx.oom.load(.acquire)) return;
        scanShard(ctx, a, info_caches, ctx.shards[i], &ctx.results[i]) catch {
            ctx.oom.store(true, .release);
            return;
        };
    }
}

fn scanShard(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    info_caches: []pack_mod.Pack.InfoCache,
    shard: Shard,
    out: *ShardResult,
) ScanError!void {
    const store = ctx.store;
    switch (shard) {
        .pack => |s| {
            const pf = &store.packs.items[s.pack_id];
            var i = s.start;
            while (i < s.end) : (i += 1) {
                const id = pf.pack.index.oidAt(i);
                const offset = pf.pack.index.offsetAt(i);
                const inf = pf.pack.infoAtCached(&info_caches[s.pack_id], allocator, offset) catch return error.CorruptRepository;
                const phys = pf.pack.nextOffsetAfter(offset) - offset;
                // Result heap outlives this worker's arena; allocate from the
                // page allocator.
                try record(ctx, std.heap.page_allocator, out, &id, inf.object_type, inf.size, phys);
            }
        },
        .loose => |s| {
            for (store.loose.objects.items[s.start..s.end]) |*o| {
                // Only this worker touches these list slots, so the lazy
                // header write is race-free.
                const header = loose_mod.resolveHeader(o) catch return error.CorruptRepository;
                try record(ctx, std.heap.page_allocator, out, &o.id, header.object_type, header.size, o.file_size);
            }
        },
    }
}

fn record(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    out: *ShardResult,
    id: *const object_id.ObjectId,
    object_type: git_object.ObjectType,
    size: u64,
    physical: u64,
) ScanError!void {
    if (object_type.isReal()) {
        const s = out.stats.forType(object_type);
        s.count += 1;
        s.logical_bytes += size;
    }
    if (ctx.reachable) |r| {
        if (!r.contains(id)) {
            out.unreachable_stats.count += 1;
            out.unreachable_stats.logical_bytes += size;
            out.unreachable_stats.physical_bytes += physical;
        }
    }
    if (object_type != .blob) return;
    if (ctx.path_map) |pm| {
        const status: largest_mod.Status = if (pm.isCurrent(id)) .current else .historical;
        if (status == .historical) out.historical_bytes += size;
        if (size >= ctx.min_size) {
            const keep = switch (ctx.filter) {
                .all => true,
                .current_only => status == .current,
                .historical_only => status == .historical,
            };
            if (keep) {
                const entry: largest_mod.BlobEntry = .{
                    .id = id.*,
                    .size = size,
                    .path = pm.pathOf(id),
                    .status = status,
                };
                if (out.heap.count() < ctx.limit) {
                    try out.heap.push(allocator, entry);
                } else if (ctx.limit > 0 and out.heap.peek().?.size < entry.size) {
                    _ = out.heap.pop();
                    try out.heap.push(allocator, entry);
                }
            }
        }
    }
}
