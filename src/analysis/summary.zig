const std = @import("std");
const Repository = @import("../git/repository.zig").Repository;
const refs_mod = @import("../git/refs.zig");
const object_store = @import("objects.zig");
const paths_mod = @import("paths.zig");
const largest_mod = @import("largest.zig");
const filesystem = @import("../platform/filesystem.zig");

pub const SummaryError = error{
    OutOfMemory,
    SystemResources,
    Unexpected,
    CorruptRepository,
    UnsupportedFormat,
};

pub const Contributor = largest_mod.BlobEntry;

pub const Summary = struct {
    /// Display name of the repository (basename of the worktree or git dir).
    name: []const u8,
    worktree_path: ?[]const u8,
    git_dir_path: []const u8,
    git_bytes: u64,
    object_bytes: u64,
    working_tree_bytes: u64,
    stats: object_store.ObjectStats,
    pack_bytes: u64,
    loose_bytes: u64,
    contributors: []Contributor,
    historical_bytes: u64,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.worktree_path) |w| allocator.free(w);
        allocator.free(self.git_dir_path);
        allocator.free(self.contributors);
    }
};

/// Build the full summary report (spec §5).
pub fn build(
    allocator: std.mem.Allocator,
    repo: *const Repository,
    store: *object_store.ObjectStore,
    refs: *const refs_mod.Refs,
) SummaryError!Summary {
    var obuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const objects_dir = repo.objectsDir(&obuf);

    // Physical sizes.
    const object_bytes = filesystem.entrySize(objects_dir) catch 0;
    const git_bytes = blk: {
        var total = filesystem.entrySize(repo.git_dir) catch 0;
        if (repo.common_dir.ptr != repo.git_dir.ptr) {
            total += filesystem.entrySize(repo.common_dir) catch 0;
        }
        break :blk total;
    };
    const working_tree_bytes = if (repo.worktree) |wt| blk: {
        var d = std.Io.Dir.cwd().openDir(io(), wt, .{ .iterate = true }) catch break :blk 0;
        defer d.close(io());
        break :blk workingTreeSize(&d, ".git") catch 0;
    } else 0;

    var pack_bytes: u64 = 0;
    for (store.packs.items) |*pf| {
        pack_bytes += filesystem.entrySize(pf.path) catch 0;
    }
    var loose_bytes: u64 = 0;
    for (store.loose.objects.items) |o| loose_bytes += o.file_size;

    const stats = try object_store.computeStats(store);

    var path_map = try paths_mod.compute(store, refs, allocator);
    defer path_map.deinit();

    const contributors = try largest_mod.topBlobs(store, &path_map, allocator, 4, 0, .all);
    const historical_bytes = try largest_mod.historicalWeight(store, &path_map);

    const name = repoName(allocator, repo) catch try allocator.dupe(u8, "repository");
    const git_dir_path = try allocator.dupe(u8, repo.git_dir);
    const wt_path: ?[]const u8 = if (repo.worktree) |w| try allocator.dupe(u8, w) else null;

    return .{
        .name = name,
        .worktree_path = wt_path,
        .git_dir_path = git_dir_path,
        .git_bytes = git_bytes,
        .object_bytes = object_bytes,
        .working_tree_bytes = working_tree_bytes,
        .stats = stats,
        .pack_bytes = pack_bytes,
        .loose_bytes = loose_bytes,
        .contributors = contributors,
        .historical_bytes = historical_bytes,
    };
}

fn repoName(allocator: std.mem.Allocator, repo: *const Repository) ![]const u8 {
    const base = if (repo.worktree) |w|
        std.fs.path.basename(w)
    else
        std.fs.path.basename(repo.git_dir);
    const trimmed = std.mem.trimEnd(u8, base, ".");
    if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    return allocator.dupe(u8, "repository");
}

/// Working tree size excluding the `.git` entry (and honoring the worktree
/// pointer file naturally by skipping `.git` regardless of kind).
fn workingTreeSize(d: *std.Io.Dir, exclude: []const u8) SummaryError!u64 {
    var total: u64 = 0;
    var it = d.iterate();
    while (it.next(io()) catch return error.Unexpected) |ent| {
        if (std.mem.eql(u8, ent.name, exclude)) continue;
        switch (ent.kind) {
            .file => {
                const st = d.statFile(io(), ent.name, .{}) catch continue;
                total += st.size;
            },
            .directory => {
                var sub = d.openDir(io(), ent.name, .{ .iterate = true }) catch continue;
                defer sub.close(io());
                total += try workingTreeSize(&sub, exclude);
            },
            else => {},
        }
    }
    return total;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
