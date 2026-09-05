const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const refs_mod = @import("../git/refs.zig");
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

/// Unique logical weight per ref (spec §6.4). HEAD is excluded; refs whose
/// peeled commit tip is identical are de-duplicated (first name kept).
/// Results are sorted by unique weight descending and capped at `limit`
/// (`0` means no limit). Returned slice and names are borrowed from `refs`.
pub fn uniqueWeights(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
    limit: usize,
) RefsError![]RefWeight {
    // First pass: dedup by peeled commit tip, walk reachability per ref,
    // count how many refs retain each object.
    var ref_count: std.HashMapUnmanaged(object_id.ObjectId, u32, object_id.ObjectId.Context, 80) = .empty;
    defer ref_count.deinit(allocator);
    var seen_tips: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80) = .empty;
    defer seen_tips.deinit(allocator);

    const Kept = struct {
        ref: refs_mod.Ref,
        oids: std.ArrayList(object_id.ObjectId),
    };
    var kept: std.ArrayList(Kept) = .empty;
    defer {
        for (kept.items) |*k| k.oids.deinit(allocator);
        kept.deinit(allocator);
    }

    for (refs.refs.items) |r| {
        if (std.mem.eql(u8, r.name, "HEAD")) continue;
        const tip = paths_mod.peelToCommit(store, &r.target, 0) orelse r.target;
        if (seen_tips.contains(tip)) continue;
        try seen_tips.put(allocator, tip, {});

        var reach = try reachability.computeFromTips(store, &.{r.target}, allocator);
        defer reach.deinit();
        var oids: std.ArrayList(object_id.ObjectId) = .empty;
        errdefer oids.deinit(allocator);
        var it = reach.set.iterator();
        while (it.next()) |e| {
            try oids.append(allocator, e.key_ptr.*);
            const gop = try ref_count.getOrPut(allocator, e.key_ptr.*);
            if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        }
        try kept.append(allocator, .{ .ref = r, .oids = oids });
    }

    // Second pass: sum logical sizes of objects retained by exactly one ref.
    var out: std.ArrayList(RefWeight) = .empty;
    errdefer out.deinit(allocator);
    for (kept.items) |*k| {
        var unique_bytes: u64 = 0;
        for (k.oids.items) |oid| {
            if ((ref_count.get(oid) orelse 0) != 1) continue;
            const inf = store.info(&oid) catch continue;
            unique_bytes += inf.size;
        }
        try out.append(allocator, .{
            .name = shortName(k.ref.name),
            .full_name = k.ref.name,
            .unique_bytes = unique_bytes,
        });
    }

    const slice = try out.toOwnedSlice(allocator);
    std.mem.sort(RefWeight, slice, {}, weightLess);
    if (limit > 0 and slice.len > limit) return slice[0..limit];
    return slice;
}

test "short ref names" {
    try std.testing.expectEqualStrings("main", shortName("refs/heads/main"));
    try std.testing.expectEqualStrings("v1.0", shortName("refs/tags/v1.0"));
    try std.testing.expectEqualStrings("origin/main", shortName("refs/remotes/origin/main"));
    try std.testing.expectEqualStrings("refs/notes/commits", shortName("refs/notes/commits"));
}
