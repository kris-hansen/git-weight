const std = @import("std");
const object_id = @import("../git/object_id.zig");
const objects = @import("objects.zig");
const commit_mod = @import("../git/commit.zig");
const tree_mod = @import("../git/tree.zig");
const core = @import("core.zig");

/// A stock measure: only blobs reachable from one commit's tree contribute.
/// This is deliberately distinct from the PR report's churn/work measure.
/// Scoring lives in `core.zig`; this file only walks git trees and feeds blobs to it.
pub const Report = struct {
    pub const score_version = core.score_version;
    revision: []const u8,
    commit: object_id.ObjectId,
    committed_at: ?i64,
    metrics: core.Metrics = .{},
    comparison: ?Comparison = null,

    pub const Comparison = struct {
        base_revision: []const u8,
        base_commit: object_id.ObjectId,
        base_points: u64,
        delta_points: i128,
    };
};

fn goModulePrefix(store: *const objects.ObjectStore, allocator: std.mem.Allocator, tree: object_id.ObjectId) !?[]const u8 {
    const payload = try store.readPayload(allocator, &tree);
    defer payload.release();
    if (payload.object_type != .tree) return error.CorruptRepository;
    var it = tree_mod.TreeIterator.init(payload.data, tree.algorithm);
    while (try it.next()) |entry| {
        if (!std.mem.eql(u8, entry.name, "go.mod") or entry.entryMode() != .blob) continue;
        const blob = try store.readPayload(allocator, &entry.id);
        defer blob.release();
        if (blob.object_type != .blob) return error.CorruptRepository;
        if (try core.goModulePrefix(allocator, blob.data)) |prefix| return prefix;
    }
    return null;
}

fn scanTree(store: *const objects.ObjectStore, allocator: std.mem.Allocator, tree: object_id.ObjectId, prefix: []const u8, scanner: *core.Scanner) !void {
    const payload = try store.readPayload(allocator, &tree);
    defer payload.release();
    if (payload.object_type != .tree) return error.CorruptRepository;
    var it = tree_mod.TreeIterator.init(payload.data, tree.algorithm);
    while (try it.next()) |entry| {
        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, entry.name });
        switch (entry.entryMode()) {
            .tree => {
                const child = try std.fmt.allocPrint(allocator, "{s}/", .{path});
                try scanTree(store, allocator, entry.id, child, scanner);
            },
            .blob => {
                if (!scanner.wants(path)) continue;
                const blob = try store.readPayload(allocator, &entry.id);
                defer blob.release();
                if (blob.object_type != .blob) return error.CorruptRepository;
                try scanner.addFile(allocator, path, blob.data);
            },
            else => {},
        }
    }
}

pub fn build(store: *const objects.ObjectStore, allocator: std.mem.Allocator, name: []const u8, oid: object_id.ObjectId) !Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const payload = try store.readPayload(alloc, &oid);
    defer payload.release();
    if (payload.object_type != .commit) return error.CorruptRepository;
    const commit = try commit_mod.parse(payload.data, oid.algorithm, alloc);
    var report: Report = .{ .revision = name, .commit = oid, .committed_at = if (commit.committer) |c| c.timestamp else null };
    var scanner = core.Scanner.begin(try goModulePrefix(store, alloc, commit.tree));
    try scanTree(store, alloc, commit.tree, "", &scanner);
    report.metrics = scanner.finish();
    return report;
}

test {
    _ = core;
}
