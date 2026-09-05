const std = @import("std");
const object_id = @import("../git/object_id.zig");
const object_store = @import("objects.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");

pub const ChangedError = error{
    OutOfMemory,
    CorruptRepository,
    PathNotFound,
};

/// The tree or blob found at a path within a commit.
pub const Entry = struct {
    id: object_id.ObjectId,
    is_tree: bool,
};

pub const ChangedReport = struct {
    path: []const u8,
    /// Base revision as given on the command line (e.g. "HEAD~1").
    base_ref: []const u8,
    base_commit: object_id.ObjectId,
    base_entry: ?Entry,
    to_ref: []const u8,
    to_commit: object_id.ObjectId,
    to_entry: ?Entry,
    changed: bool,
};

/// Look up `path` in the tree of `commit_oid`. Path "." or "" selects the
/// root tree. Returns null when any component is absent (or a non-final
/// component is not a tree); unreadable objects count as absent.
pub fn treeEntryAtPath(
    store: *const object_store.ObjectStore,
    commit_oid: *const object_id.ObjectId,
    path: []const u8,
    allocator: std.mem.Allocator,
) ChangedError!?Entry {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const commit_payload = store.readPayload(scratch.allocator(), commit_oid) catch return error.CorruptRepository;
    if (commit_payload.object_type != .commit) return error.CorruptRepository;
    const c = commit_mod.parse(commit_payload.data, commit_oid.algorithm, scratch.allocator()) catch return error.CorruptRepository;
    var current = c.tree;

    if (path.len == 0 or std.mem.eql(u8, path, ".")) {
        return .{ .id = current, .is_tree = true };
    }

    var comps = std.mem.splitScalar(u8, path, '/');
    while (comps.next()) |comp| {
        if (comp.len == 0) continue;
        const is_last = comps.peek() == null;
        // Skip trailing empty components when deciding "last".
        const last = blk: {
            if (is_last) break :blk true;
            var rest = comps;
            while (rest.next()) |r| {
                if (r.len != 0) break :blk false;
            }
            break :blk true;
        };

        _ = scratch.reset(.retain_capacity);
        // The root tree oid was copied out of the commit payload above, so
        // resetting the scratch arena here is safe.
        const payload = store.readPayload(scratch.allocator(), &current) catch return null;
        if (payload.object_type != .tree) return null;

        var found: ?tree_mod.TreeEntry = null;
        var it = tree_mod.TreeIterator.init(payload.data, current.algorithm);
        while (it.next() catch return null) |entry| {
            if (std.mem.eql(u8, entry.name, comp)) {
                found = entry;
                break;
            }
        }
        const entry = found orelse return null;
        if (last) {
            return .{ .id = entry.id, .is_tree = entry.entryMode() == .tree };
        }
        if (entry.entryMode() != .tree) return null;
        current = entry.id;
    }
    return null;
}

/// Compare `path` between two commits (spec: `git weight changed`).
pub fn compare(
    store: *const object_store.ObjectStore,
    path: []const u8,
    base_ref: []const u8,
    base_commit: object_id.ObjectId,
    to_ref: []const u8,
    to_commit: object_id.ObjectId,
    allocator: std.mem.Allocator,
) ChangedError!ChangedReport {
    const base_entry = try treeEntryAtPath(store, &base_commit, path, allocator);
    const to_entry = try treeEntryAtPath(store, &to_commit, path, allocator);
    if (base_entry == null and to_entry == null) return error.PathNotFound;

    const changed = if (base_entry == null or to_entry == null)
        true
    else
        !base_entry.?.id.eql(&to_entry.?.id);

    return .{
        .path = path,
        .base_ref = base_ref,
        .base_commit = base_commit,
        .base_entry = base_entry,
        .to_ref = to_ref,
        .to_commit = to_commit,
        .to_entry = to_entry,
        .changed = changed,
    };
}
