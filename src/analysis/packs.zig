const std = @import("std");
const object_store = @import("objects.zig");
const filesystem = @import("../platform/filesystem.zig");
const pack_mod = @import("../git/pack/pack.zig");

pub const PackInfo = struct {
    /// File name of the pack (e.g. "pack-a2f3...pack").
    name: []const u8,
    object_count: u64,
    /// Physical size of the .pack file.
    pack_bytes: u64,
    /// Entries stored as deltas (spec §6.6 deep pack stats).
    delta_count: u64 = 0,
    /// Deepest delta chain in the pack (0 when no deltas).
    max_delta_depth: u64 = 0,
    /// Sum of delta chain depths; drives meanDeltaDepth.
    delta_depth_total: u64 = 0,
    /// Sum of logical (reconstructed) sizes of delta objects.
    delta_logical_bytes: u64 = 0,
    /// Sum of physical (on-disk) entry spans of delta objects.
    delta_physical_bytes: u64 = 0,

    pub fn meanDeltaDepth(self: *const PackInfo) f64 {
        if (self.delta_count == 0) return 0;
        return @as(f64, @floatFromInt(self.delta_depth_total)) / @as(f64, @floatFromInt(self.delta_count));
    }
};

pub const PackSizeRef = struct {
    name: []const u8,
    bytes: u64,
};

pub const PacksSummary = struct {
    pack_count: u64,
    total_bytes: u64,
    smallest: ?PackSizeRef,
    largest: ?PackSizeRef,
    total_delta_count: u64,
    total_delta_logical_bytes: u64,
    total_delta_physical_bytes: u64,
    /// One-line repack suggestion, when fragmentation or delta compression
    /// looks poor; null otherwise. Owned by the report allocator.
    repack_hint: ?[]const u8,
};

pub const HintReason = enum {
    many_small_packs,
    poor_delta_compression,
};

/// Whether the pack set looks like it would benefit from a repack, and why.
/// Pure: `smallest_bytes`/`total_bytes` are the per-pack byte extremes.
pub fn hintReason(
    pack_count: usize,
    smallest_bytes: u64,
    total_bytes: u64,
    total_delta_logical: u64,
    total_delta_physical: u64,
) ?HintReason {
    // Fragmentation: 4+ packs and the smallest holds less than an even
    // quarter share, or simply very many packs.
    if (pack_count >= 4 and (smallest_bytes * 4 < total_bytes or pack_count >= 8)) return .many_small_packs;
    if (total_delta_logical > 0 and total_delta_physical * 2 > total_delta_logical) return .poor_delta_compression;
    return null;
}

pub fn buildSummary(packs: []const PackInfo, allocator: std.mem.Allocator) PacksError!PacksSummary {
    var total_bytes: u64 = 0;
    var total_deltas: u64 = 0;
    var total_delta_logical: u64 = 0;
    var total_delta_physical: u64 = 0;
    var smallest: ?PackSizeRef = null;
    var largest: ?PackSizeRef = null;
    for (packs) |p| {
        total_bytes += p.pack_bytes;
        total_deltas += p.delta_count;
        total_delta_logical += p.delta_logical_bytes;
        total_delta_physical += p.delta_physical_bytes;
        if (smallest == null or p.pack_bytes < smallest.?.bytes) {
            smallest = .{ .name = p.name, .bytes = p.pack_bytes };
        }
        if (largest == null or p.pack_bytes > largest.?.bytes) {
            largest = .{ .name = p.name, .bytes = p.pack_bytes };
        }
    }

    const smallest_bytes = if (smallest) |s| s.bytes else 0;
    var hint: ?[]const u8 = null;
    if (hintReason(packs.len, smallest_bytes, total_bytes, total_delta_logical, total_delta_physical)) |reason| {
        hint = switch (reason) {
            .many_small_packs => try std.fmt.allocPrint(allocator, "{d} packfiles, smallest {d} bytes — consider consolidating with `git repack -ad`", .{ packs.len, smallest_bytes }),
            .poor_delta_compression => try std.fmt.allocPrint(allocator, "delta chains store {d}% of their logical size — consider `git repack -ad --aggressive`", .{(total_delta_physical * 100) / total_delta_logical}),
        };
    }

    return .{
        .pack_count = packs.len,
        .total_bytes = total_bytes,
        .smallest = smallest,
        .largest = largest,
        .total_delta_count = total_deltas,
        .total_delta_logical_bytes = total_delta_logical,
        .total_delta_physical_bytes = total_delta_physical,
        .repack_hint = hint,
    };
}

pub const PacksError = error{
    OutOfMemory,
    Unexpected,
};

/// Full packfile statistics: per-pack base info plus delta stats, computed
/// by one sharded parallel pass over pack entries (each worker resolves
/// delta chains through its own per-pack info cache, like scan.zig).
pub fn analyzePacks(store: *const object_store.ObjectStore, allocator: std.mem.Allocator) PacksError![]PackInfo {
    const out = try allocator.alloc(PackInfo, store.packs.items.len);
    for (store.packs.items, 0..) |*pf, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, std.fs.path.basename(pf.path)),
            .object_count = pf.objectCount(),
            .pack_bytes = filesystem.entrySize(pf.path) catch 0,
        };
    }
    if (out.len == 0) return out;

    // Explicit usize: the @min bound otherwise infers a 7-bit type that
    // overflows in `n_threads * 4` below once threads reaches 32.
    const n_threads: usize = @max(1, @min(store.threads, 64));
    var shards: std.ArrayList(Shard) = .empty;
    defer shards.deinit(allocator);
    for (store.packs.items, 0..) |*pf, pack_id| {
        const count: usize = pf.pack.index.count;
        const per = @max(1024, count / (n_threads * 4) + 1);
        var start: usize = 0;
        while (start < count) : (start += per) {
            try shards.append(allocator, .{ .pack_id = pack_id, .start = start, .end = @min(count, start + per) });
        }
    }
    if (shards.items.len == 0) return out;

    const results = try allocator.alloc(ShardResult, shards.items.len);
    for (results, shards.items) |*r, s| r.* = .{ .pack_id = s.pack_id };

    var next: std.atomic.Value(usize) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    var ctx: Ctx = .{
        .store = store,
        .shards = shards.items,
        .results = results,
        .next = &next,
        .failed = &failed,
    };

    const workers = @min(n_threads, shards.items.len);
    if (workers <= 1) {
        shardWorker(&ctx);
    } else {
        var handles: [64]?std.Thread = .{null} ** 64;
        for (0..workers - 1) |i| {
            handles[i] = std.Thread.spawn(.{}, shardWorker, .{&ctx}) catch null;
        }
        shardWorker(&ctx);
        for (0..workers - 1) |i| {
            if (handles[i]) |h| h.join();
        }
    }
    if (ctx.failed.load(.acquire)) return error.OutOfMemory;

    for (results) |*r| {
        const p = &out[r.pack_id];
        p.delta_count += r.stats.delta_count;
        p.delta_depth_total += r.stats.delta_depth_total;
        p.max_delta_depth = @max(p.max_delta_depth, r.stats.max_delta_depth);
        p.delta_logical_bytes += r.stats.delta_logical_bytes;
        p.delta_physical_bytes += r.stats.delta_physical_bytes;
    }
    return out;
}

const Shard = struct {
    pack_id: usize,
    start: usize,
    end: usize,
};

const ShardStats = struct {
    delta_count: u64 = 0,
    delta_depth_total: u64 = 0,
    max_delta_depth: u64 = 0,
    delta_logical_bytes: u64 = 0,
    delta_physical_bytes: u64 = 0,
};

const ShardResult = struct {
    pack_id: usize,
    stats: ShardStats = .{},
};

const Ctx = struct {
    store: *const object_store.ObjectStore,
    shards: []const Shard,
    results: []ShardResult,
    next: *std.atomic.Value(usize),
    failed: *std.atomic.Value(bool),
};

fn shardWorker(ctx: *Ctx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info_caches = a.alloc(pack_mod.Pack.InfoCache, ctx.store.packs.items.len) catch {
        ctx.failed.store(true, .release);
        return;
    };
    for (info_caches) |*c| c.* = .empty;

    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.shards.len) return;
        if (ctx.failed.load(.acquire)) return;
        scanShard(ctx, a, info_caches, ctx.shards[i], &ctx.results[i]) catch {
            ctx.failed.store(true, .release);
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
) PacksError!void {
    out.pack_id = shard.pack_id;
    const pf = &ctx.store.packs.items[shard.pack_id];
    var i = shard.start;
    while (i < shard.end) : (i += 1) {
        const offset = pf.pack.index.offsetAt(i);
        const inf = pf.pack.infoAtCached(&info_caches[shard.pack_id], allocator, offset) catch return error.Unexpected;
        if (inf.delta_depth == 0) continue;
        const physical = pf.pack.nextOffsetAfter(offset) - offset;
        out.stats.delta_count += 1;
        out.stats.delta_depth_total += inf.delta_depth;
        out.stats.max_delta_depth = @max(out.stats.max_delta_depth, inf.delta_depth);
        out.stats.delta_logical_bytes += inf.size;
        out.stats.delta_physical_bytes += physical;
    }
}

test "hintReason flags fragmentation and poor delta compression" {
    // Few packs, healthy deltas: no hint.
    try std.testing.expect(hintReason(2, 100, 1000, 1000, 100) == null);
    // 4+ packs with the smallest below a quarter share (even 5 equal packs).
    try std.testing.expectEqual(@as(?HintReason, .many_small_packs), hintReason(5, 100, 500, 1000, 100));
    // Few packs but deltas barely compress (store more than half of logical).
    try std.testing.expectEqual(@as(?HintReason, .poor_delta_compression), hintReason(1, 100, 1000, 1000, 600));
    // Exactly half is still acceptable.
    try std.testing.expect(hintReason(1, 100, 1000, 1000, 500) == null);
    // 4 evenly sized packs: smallest is exactly a quarter share, no hint.
    try std.testing.expect(hintReason(4, 250, 1000, 0, 0) == null);
    // Very many packs hint regardless of evenness.
    try std.testing.expectEqual(@as(?HintReason, .many_small_packs), hintReason(8, 100, 800, 0, 0));
    // No deltas and only a few packs: no hint.
    try std.testing.expect(hintReason(3, 1, 100000, 0, 0) == null);
}

test "buildSummary aggregates extremes and totals" {
    const packs = [_]PackInfo{
        .{ .name = "a.pack", .object_count = 10, .pack_bytes = 100, .delta_count = 2, .max_delta_depth = 3, .delta_depth_total = 4, .delta_logical_bytes = 1000, .delta_physical_bytes = 100 },
        .{ .name = "b.pack", .object_count = 20, .pack_bytes = 900, .delta_count = 1, .max_delta_depth = 1, .delta_depth_total = 1, .delta_logical_bytes = 500, .delta_physical_bytes = 400 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try buildSummary(&packs, arena.allocator());
    try std.testing.expectEqual(@as(u64, 2), s.pack_count);
    try std.testing.expectEqual(@as(u64, 1000), s.total_bytes);
    try std.testing.expectEqualStrings("a.pack", s.smallest.?.name);
    try std.testing.expectEqualStrings("b.pack", s.largest.?.name);
    try std.testing.expectEqual(@as(u64, 3), s.total_delta_count);
    try std.testing.expectEqual(@as(u64, 1500), s.total_delta_logical_bytes);
    // Deltas store 500/1500 = 33% of logical: healthy, two packs: no hint.
    try std.testing.expect(s.repack_hint == null);
}

test "meanDeltaDepth" {
    var p: PackInfo = .{ .name = "x", .object_count = 0, .pack_bytes = 0 };
    try std.testing.expectEqual(@as(f64, 0), p.meanDeltaDepth());
    p.delta_count = 4;
    p.delta_depth_total = 9;
    try std.testing.expectEqual(@as(f64, 2.25), p.meanDeltaDepth());
}
