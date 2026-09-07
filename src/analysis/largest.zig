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

pub fn sizeGreater(_: void, a: BlobEntry, b: BlobEntry) std.math.Order {
    return std.math.order(a.size, b.size); // min-heap by size: peek = smallest
}

/// Deterministic presentation order: size descending, ties by oid ascending.
pub fn entryOrderDesc(_: void, a: BlobEntry, b: BlobEntry) bool {
    if (a.size != b.size) return a.size > b.size;
    return std.mem.order(u8, a.id.bytes[0..a.id.rawLen()], b.id.bytes[0..b.id.rawLen()]) == .lt;
}
