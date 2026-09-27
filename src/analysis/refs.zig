const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const tag_mod = @import("../git/tag.zig");
const paths_mod = @import("paths.zig");
const reachability = @import("reachability.zig");

pub const RefsError = error{
    OutOfMemory,
};

pub const RefWeight = struct {
    /// Short display name (refs/heads/, refs/tags/, refs/remotes/ stripped).
    name: []const u8,
    /// Full ref name, e.g. "refs/tags/v1.0".
    full_name: []const u8,
    /// Logical bytes reachable only from this ref (spec §6.4).
    unique_bytes: u64,
};

/// A ref kept after tip de-duplication: the first ref pointing at each
/// peeled commit tip, in original ref order.
const Kept = struct {
    ref: refs_mod.Ref,
    target: object_id.ObjectId,
};

/// Strip the conventional refs prefixes for display.
pub fn shortName(full: []const u8) []const u8 {
    for ([_][]const u8{ "refs/heads/", "refs/tags/", "refs/remotes/" }) |prefix| {
        if (std.mem.startsWith(u8, full, prefix)) return full[prefix.len..];
    }
    return full;
}

fn weightLess(_: void, a: RefWeight, b: RefWeight) bool {
    if (a.unique_bytes != b.unique_bytes) return a.unique_bytes > b.unique_bytes;
    return std.mem.order(u8, a.full_name, b.full_name) == .lt;
}

/// Index of the single set bit, or null when zero or multiple bits are set.
fn soleBit(m: u64) ?u6 {
    if (m == 0 or (m & (m - 1)) != 0) return null;
    return @intCast(@ctz(m));
}

/// Unique logical weight per ref (spec §6.4). HEAD is excluded; refs whose
/// peeled commit tip is identical are de-duplicated (first name kept).
/// Results are sorted by unique weight descending and capped at `limit`
/// (`0` means no limit). Returned slice and names are borrowed from `refs`.
///
/// With at most 64 kept tips, one combined walk from all ref targets records
/// per object a bitmask of the tips that reach it; unique bytes per ref are
/// the logical sizes of objects whose mask is exactly that ref's bit. With
/// more tips the old per-ref sequential walk is used instead.
pub fn uniqueWeights(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
    limit: usize,
) RefsError![]RefWeight {
    var seen_tips: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer seen_tips.deinit(allocator);
    var kept: std.ArrayList(Kept) = .empty;
    defer kept.deinit(allocator);

    for (refs.refs.items) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        const tip = paths_mod.peelToCommit(store, &r.target, 0) orelse r.target;
        if (seen_tips.contains(tip)) continue;
        try seen_tips.put(allocator, tip, {});
        try kept.append(allocator, .{ .ref = r, .target = r.target });
    }

    const unique_bytes = try allocator.alloc(u64, kept.items.len);
    defer allocator.free(unique_bytes);
    @memset(unique_bytes, 0);

    if (kept.items.len <= 64) {
        try accumulateUniqueMasks(store, kept.items, allocator, unique_bytes);
    } else {
        try accumulateUniquePerRef(store, kept.items, allocator, unique_bytes);
    }

    var out: std.ArrayList(RefWeight) = .empty;
    errdefer out.deinit(allocator);
    for (kept.items, unique_bytes) |k, bytes| {
        try out.append(allocator, .{
            .name = shortName(k.ref.name),
            .full_name = k.ref.name,
            .unique_bytes = bytes,
        });
    }

    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort(RefWeight, slice, {}, weightLess);
    if (limit > 0 and slice.len > limit) return slice[0..limit];
    return slice;
}

/// Single-pass walk from every kept ref target. The stack carries the
/// bitmask of tips being walked; an object is re-expanded only when a tip
/// reaches it that had not reached it before.
fn accumulateUniqueMasks(
    store: *const object_store.ObjectStore,
    kept: []const Kept,
    allocator: std.mem.Allocator,
    sums: []u64,
) RefsError!void {
    const Entry = struct { id: object_id.ObjectId, mask: u64 };
    var masks: std.HashMapUnmanaged(object_id.ObjectId, u64, object_id.ObjectId.Context, 80) = .empty;
    defer masks.deinit(allocator);
    var stack: std.ArrayList(Entry) = .empty;
    defer stack.deinit(allocator);
    for (kept, 0..) |k, i| {
        try stack.append(allocator, .{ .id = k.target, .mask = @as(u64, 1) << @intCast(i) });
    }

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    while (stack.pop()) |e| {
        const gop = try masks.getOrPut(allocator, e.id);
        if (gop.found_existing) {
            if ((gop.value_ptr.* & e.mask) == e.mask) continue;
            gop.value_ptr.* |= e.mask;
        } else {
            gop.value_ptr.* = e.mask;
        }

        const inf = store.info(&e.id) catch continue;
        _ = scratch.reset(.retain_capacity);
        switch (inf.object_type) {
            .commit => {
                const payload = store.readPayload(scratch.allocator(), &e.id) catch continue;
                const c = commit_mod.parse(payload.data, e.id.algorithm, scratch.allocator()) catch continue;
                payload.release();
                try stack.append(allocator, .{ .id = c.tree, .mask = e.mask });
                for (c.parents) |p| try stack.append(allocator, .{ .id = p, .mask = e.mask });
            },
            .tree => {
                const payload = store.readPayload(scratch.allocator(), &e.id) catch continue;
                var it = tree_mod.TreeIterator.init(payload.data, e.id.algorithm);
                while (it.next() catch null) |entry| {
                    switch (entry.entryMode()) {
                        .tree, .blob, .other => try stack.append(allocator, .{ .id = entry.id, .mask = e.mask }),
                        .submodule => {},
                    }
                }
                payload.release();
            },
            .tag => {
                const payload = store.readPayload(scratch.allocator(), &e.id) catch continue;
                const t = tag_mod.parse(payload.data, e.id.algorithm) catch continue;
                payload.release();
                try stack.append(allocator, .{ .id = t.object, .mask = e.mask });
            },
            else => {},
        }
    }

    var it = masks.iterator();
    while (it.next()) |e| {
        const bit = soleBit(e.value_ptr.*) orelse continue;
        const inf = store.info(e.key_ptr) catch continue;
        sums[bit] += inf.size;
    }
}

/// Fallback for more than 64 kept tips: one full reachability walk per ref,
/// counting how many refs retain each object.
fn accumulateUniquePerRef(
    store: *const object_store.ObjectStore,
    kept: []const Kept,
    allocator: std.mem.Allocator,
    sums: []u64,
) RefsError!void {
    var ref_count: std.HashMapUnmanaged(object_id.ObjectId, u32, object_id.ObjectId.Context, 80) = .empty;
    defer ref_count.deinit(allocator);

    var lists: std.ArrayList(std.ArrayList(object_id.ObjectId)) = .empty;
    defer {
        for (lists.items) |*l| l.deinit(allocator);
        lists.deinit(allocator);
    }

    for (kept) |k| {
        var reach = try reachability.computeFromTips(store, &.{k.target}, allocator);
        defer reach.deinit();
        var oids: std.ArrayList(object_id.ObjectId) = .empty;
        errdefer oids.deinit(allocator);
        var it = reach.set.iterator();
        while (it.next()) |e| {
            try oids.append(allocator, e.key_ptr.*);
            const gop = try ref_count.getOrPut(allocator, e.key_ptr.*);
            if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        }
        try lists.append(allocator, oids);
    }

    for (lists.items, 0..) |oids, i| {
        for (oids.items) |oid| {
            if ((ref_count.get(oid) orelse 0) != 1) continue;
            const inf = store.info(&oid) catch continue;
            sums[i] += inf.size;
        }
    }
}

test "short ref names" {
    try std.testing.expectEqualStrings("main", shortName("refs/heads/main"));
    try std.testing.expectEqualStrings("v1.0", shortName("refs/tags/v1.0"));
    try std.testing.expectEqualStrings("origin/main", shortName("refs/remotes/origin/main"));
    try std.testing.expectEqualStrings("refs/notes/commits", shortName("refs/notes/commits"));
}

test "soleBit" {
    try std.testing.expectEqual(@as(?u6, null), soleBit(0));
    try std.testing.expectEqual(@as(?u6, null), soleBit(3));
    try std.testing.expectEqual(@as(?u6, null), soleBit(0b10100));
    try std.testing.expectEqual(@as(?u6, 0), soleBit(1));
    try std.testing.expectEqual(@as(?u6, 5), soleBit(1 << 5));
    try std.testing.expectEqual(@as(?u6, 63), soleBit(@as(u64, 1) << 63));
}
