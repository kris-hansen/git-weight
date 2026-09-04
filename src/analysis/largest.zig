const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const paths_mod = @import("paths.zig");

pub const LargestError = error{
    OutOfMemory,
    CorruptRepository,
    Unexpected,
};

pub const Status = enum {
    current,
    historical,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .current => "current",
            .historical => "historical",
        };
    }
};

pub const BlobEntry = struct {
    id: object_id.ObjectId,
    size: u64,
    /// Representative path, or null if the blob was not found in any
    /// reachable history tree.
    path: ?[]const u8,
    status: Status,
};

pub const Filter = enum {
    all,
    current_only,
    historical_only,
};

/// Find the `limit` largest blobs by logical size, with representative paths
/// and current/historical status. `--min-size` and status filters apply.
pub fn topBlobs(
    store: *const object_store.ObjectStore,
    path_map: *const paths_mod.PathMap,
    allocator: std.mem.Allocator,
    limit: usize,
    min_size: u64,
    filter: Filter,
) LargestError![]BlobEntry {
    // Min-heap of the best `limit` entries seen so far, ordered by size.
    var heap: std.PriorityQueue(BlobEntry, void, sizeGreater) = .empty;

    var it = store.locations.iterator();
    while (it.next()) |e| {
        const inf = store.info(&e.key_ptr.*) catch continue;
        if (inf.object_type != .blob) continue;
        if (inf.size < min_size) continue;

        const status: Status = if (path_map.isCurrent(&e.key_ptr.*)) .current else .historical;
        switch (filter) {
            .all => {},
            .current_only => if (status != .current) continue,
            .historical_only => if (status != .historical) continue,
        }

        const entry: BlobEntry = .{
            .id = e.key_ptr.*,
            .size = inf.size,
            .path = path_map.pathOf(&e.key_ptr.*),
            .status = status,
        };

        if (heap.count() < limit) {
            try heap.push(allocator, entry);
        } else if (heap.peek().?.size < entry.size) {
            _ = heap.pop();
            try heap.push(allocator, entry);
        }
    }

    // Present largest first. Ownership of the heap's backing array transfers
    // to the caller.
    const out = heap.items;
    std.mem.sort(BlobEntry, out, {}, sizeLessDesc);
    return out;
}

fn sizeGreater(_: void, a: BlobEntry, b: BlobEntry) std.math.Order {
    return std.math.order(a.size, b.size); // min-heap by size: peek = smallest
}

fn sizeLessDesc(_: void, a: BlobEntry, b: BlobEntry) bool {
    return a.size > b.size;
}

/// Total logical size of blobs that exist in reachable history but not in
/// the tree at HEAD.
pub fn historicalWeight(
    store: *const object_store.ObjectStore,
    path_map: *const paths_mod.PathMap,
) LargestError!u64 {
    var total: u64 = 0;
    var it = store.locations.iterator();
    while (it.next()) |e| {
        const inf = store.info(&e.key_ptr.*) catch continue;
        if (inf.object_type != .blob) continue;
        if (path_map.isCurrent(&e.key_ptr.*)) continue;
        total += inf.size;
    }
    return total;
}
