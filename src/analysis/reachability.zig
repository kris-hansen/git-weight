const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const refs_mod = @import("../git/refs.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const tag_mod = @import("../git/tag.zig");

pub const ReachError = error{
    OutOfMemory,
};

/// Set of all objects reachable from a set of tips.
pub const Reachable = struct {
    allocator: std.mem.Allocator,
    set: std.HashMapUnmanaged(object_id.ObjectId, void, object_id.ObjectId.Context, 80),

    pub fn deinit(self: *Reachable) void {
        self.set.deinit(self.allocator);
    }

    pub fn contains(self: *const Reachable, id: *const object_id.ObjectId) bool {
        return self.set.contains(id.*);
    }
};

/// Graph walk from `tips`: commits push parents and tree, trees push all
/// entry ids, tags push the tagged object. Unreadable or missing objects
/// are skipped (except on out-of-memory).
pub fn computeFromTips(
    store: *const object_store.ObjectStore,
    tips: []const object_id.ObjectId,
    allocator: std.mem.Allocator,
) ReachError!Reachable {
    var result: Reachable = .{ .allocator = allocator, .set = .empty };
    errdefer result.deinit();

    var stack: std.ArrayList(object_id.ObjectId) = .empty;
    defer stack.deinit(allocator);
    try stack.appendSlice(allocator, tips);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    while (stack.pop()) |id| {
        if (result.set.contains(id)) continue;
        try result.set.put(allocator, id, {});

        const inf = store.info(&id) catch continue;
        _ = scratch.reset(.retain_capacity);
        switch (inf.object_type) {
            .commit => {
                const payload = store.readPayload(scratch.allocator(), &id) catch continue;
                const c = commit_mod.parse(payload.data, id.algorithm, scratch.allocator()) catch continue;
                try stack.append(allocator, c.tree);
                try stack.appendSlice(allocator, c.parents);
            },
            .tree => {
                const payload = store.readPayload(scratch.allocator(), &id) catch continue;
                var it = tree_mod.TreeIterator.init(payload.data, id.algorithm);
                while (it.next() catch null) |entry| {
                    switch (entry.entryMode()) {
                        .tree, .blob, .other => try stack.append(allocator, entry.id),
                        .submodule => {},
                    }
                }
            },
            .tag => {
                const payload = store.readPayload(scratch.allocator(), &id) catch continue;
                const t = tag_mod.parse(payload.data, id.algorithm) catch continue;
                try stack.append(allocator, t.object);
            },
            else => {},
        }
    }
    return result;
}

/// Reachability from every ref (including HEAD). Annotated tags are walked
/// naturally since tag objects reference their target.
pub fn computeAll(
    store: *const object_store.ObjectStore,
    refs: *const refs_mod.Refs,
    allocator: std.mem.Allocator,
) ReachError!Reachable {
    var tips: std.ArrayList(object_id.ObjectId) = .empty;
    defer tips.deinit(allocator);
    for (refs.refs.items) |r| try tips.append(allocator, r.target);
    return computeFromTips(store, tips.items, allocator);
}

pub const UnreachableStats = struct {
    count: u64,
    logical_bytes: u64,
    physical_bytes: u64,
};
