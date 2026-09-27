const std = @import("std");
const Io = std.Io;
const object_id = @import("object_id.zig");

pub const DiscoverError = error{
    NotARepository,
    OutOfMemory,
    SystemResources,
    Unexpected,
};

pub const RepoKind = enum {
    normal, // has a working tree and a .git directory
    bare,
    worktree, // linked worktree: git_dir is per-worktree, objects/refs are shared
};

/// A discovered Git repository. All paths are absolute and owned by
/// `allocator`; freed with `deinit`.
pub const Repository = struct {
    allocator: std.mem.Allocator,
    /// Absolute path of the working tree, or null for bare repositories.
    worktree: ?[]const u8,
    /// Absolute path of the (per-worktree) git directory.
    git_dir: []const u8,
    /// Absolute path of the common git directory (objects, refs, packed-refs).
    /// Same allocation as `git_dir` for normal and bare repositories.
    common_dir: []const u8,
    kind: RepoKind,
    hash_algorithm: object_id.HashAlgorithm = .sha1,

    pub fn objectsDir(self: *const Repository, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/objects", .{self.common_dir}) catch unreachable;
    }

    pub fn deinit(self: *Repository) void {
        if (self.worktree) |w| self.allocator.free(w);
        if (self.common_dir.ptr != self.git_dir.ptr) self.allocator.free(self.common_dir);
        self.allocator.free(self.git_dir);
    }
};

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn statPath(path: []const u8) ?Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io(), path, .{}) catch null;
}

fn isGitLayout(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{s}/HEAD", .{path}) catch return false;
    if (statPath(head) == null) return false;
    const objects = std.fmt.bufPrint(&buf, "{s}/objects", .{path}) catch return false;
    if (statPath(objects) == null) return false;
    const refs = std.fmt.bufPrint(&buf, "{s}/refs", .{path}) catch return false;
    if (statPath(refs) == null) return false;
    return true;
}

/// Discover the repository containing `start_path`, walking upward until a
/// `.git` entry or bare repository layout is found.
pub fn discover(allocator: std.mem.Allocator, start_path: []const u8) DiscoverError!Repository {
    const abs_z = std.Io.Dir.cwd().realPathFileAlloc(io(), start_path, allocator) catch return error.NotARepository;
    defer allocator.free(abs_z);
    const abs: []const u8 = abs_z;

    // `abs` comes from realpath: absolute, symlink-free, normalized.
    var path: []const u8 = abs;

    const repo = while (true) {
        // A `.git` entry (directory or worktree pointer file)?
        var join_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dotgit = std.fmt.bufPrint(&join_buf, "{s}/.git", .{path}) catch return error.Unexpected;
        if (statPath(dotgit)) |st| {
            switch (st.kind) {
                .directory => break try initNormal(allocator, path, dotgit),
                .file, .sym_link => break try initFromGitFile(allocator, path, dotgit),
                else => {},
            }
        }

        // Bare repository layout at this level?
        if (isGitLayout(path)) {
            break try initBare(allocator, path);
        }

        const parent = std.fs.path.dirname(path) orelse return error.NotARepository;
        if (parent.len == path.len) return error.NotARepository;
        path = parent;
    };

    var found = repo;
    // The object format lives in the shared config; it must be known before
    // the store opens any pack index or loose object path.
    found.hash_algorithm = detectHashAlgorithm(allocator, found.common_dir);
    return found;
}

/// Read the object format from `<common_dir>/config`
/// (`extensions.objectformat = sha256`). Defaults to SHA-1 when the config
/// file is missing, unparsable, or carries no such extension. Section and
/// key names are case-insensitive, as in Git.
fn detectHashAlgorithm(allocator: std.mem.Allocator, common_dir: []const u8) object_id.HashAlgorithm {
    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_path = std.fmt.bufPrint(&pbuf, "{s}/config", .{common_dir}) catch return .sha1;
    const raw = std.Io.Dir.cwd().readFileAlloc(io(), config_path, allocator, std.Io.Limit.limited(1 << 20)) catch return .sha1;
    defer allocator.free(raw);

    var algorithm: object_id.HashAlgorithm = .sha1;
    var in_extensions = false;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            // A subsection looks like `[extensions "x"]`; the bare section
            // name ends at the first quote or bracket.
            const name_end = std.mem.indexOfAny(u8, line[1..end], "\" ") orelse end - 1;
            const section = line[1 .. 1 + name_end];
            in_extensions = std.ascii.eqlIgnoreCase(section, "extensions");
            continue;
        }
        if (!in_extensions) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "objectformat")) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (std.ascii.eqlIgnoreCase(value, "sha256")) algorithm = .sha256;
    }
    return algorithm;
}

fn initNormal(allocator: std.mem.Allocator, worktree: []const u8, git_dir: []const u8) DiscoverError!Repository {
    const wt = try allocator.dupe(u8, worktree);
    errdefer allocator.free(wt);
    const gd = try allocator.dupe(u8, git_dir);
    return .{
        .allocator = allocator,
        .worktree = wt,
        .git_dir = gd,
        .common_dir = gd,
        .kind = .normal,
    };
}

fn initBare(allocator: std.mem.Allocator, git_dir: []const u8) DiscoverError!Repository {
    const gd = try allocator.dupe(u8, git_dir);
    return .{
        .allocator = allocator,
        .worktree = null,
        .git_dir = gd,
        .common_dir = gd,
        .kind = .bare,
    };
}

/// `worktree` is the directory containing the `.git` pointer file; the file
/// contains `gitdir: <path>` where the path may be relative to the worktree.
/// Linked worktrees carry a `commondir` file inside the git dir pointing at
/// the shared object/ref store.
fn initFromGitFile(allocator: std.mem.Allocator, worktree: []const u8, git_file: []const u8) DiscoverError!Repository {
    const raw = std.Io.Dir.cwd().readFileAlloc(io(), git_file, allocator, std.Io.Limit.limited(4096)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotARepository,
    };
    defer allocator.free(raw);

    const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return error.NotARepository;
    const target = std.mem.trim(u8, trimmed[prefix.len..], " \t");

    const git_dir = if (std.fs.path.isAbsolute(target))
        try allocator.dupe(u8, target)
    else
        try std.fs.path.resolve(allocator, &.{ worktree, target });

    var common_dir: []const u8 = git_dir;
    var kind: RepoKind = .normal;
    {
        var cbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const commondir_file = std.fmt.bufPrint(&cbuf, "{s}/commondir", .{git_dir}) catch unreachable;
        if (std.Io.Dir.cwd().readFileAlloc(io(), commondir_file, allocator, std.Io.Limit.limited(4096)) catch null) |cd_raw| {
            defer allocator.free(cd_raw);
            const cd = std.mem.trimEnd(u8, cd_raw, "\r\n");
            if (cd.len > 0) {
                common_dir = try std.fs.path.resolve(allocator, &.{ git_dir, cd });
                kind = .worktree;
            }
        }
    }

    const wt = try allocator.dupe(u8, worktree);
    return .{
        .allocator = allocator,
        .worktree = wt,
        .git_dir = git_dir,
        .common_dir = common_dir,
        .kind = kind,
    };
}
