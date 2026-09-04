const std = @import("std");
const object_store = @import("objects.zig");
const filesystem = @import("../platform/filesystem.zig");

pub const PackInfo = struct {
    /// File name of the pack (e.g. "pack-a2f3...pack").
    name: []const u8,
    object_count: u64,
    /// Physical size of the .pack file.
    pack_bytes: u64,
};

pub const PacksError = error{
    OutOfMemory,
    Unexpected,
};

pub fn listPacks(store: *const object_store.ObjectStore, allocator: std.mem.Allocator) PacksError![]PackInfo {
    const out = try allocator.alloc(PackInfo, store.packs.items.len);
    errdefer allocator.free(out);
    for (store.packs.items, 0..) |*pf, i| {
        const name = try allocator.dupe(u8, std.fs.path.basename(pf.path));
        errdefer allocator.free(name);
        out[i] = .{
            .name = name,
            .object_count = pf.objectCount(),
            .pack_bytes = filesystem.entrySize(pf.path) catch 0,
        };
    }
    return out;
}

pub fn freePacks(allocator: std.mem.Allocator, packs: []PackInfo) void {
    for (packs) |p| allocator.free(p.name);
    allocator.free(packs);
}
