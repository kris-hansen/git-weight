const std = @import("std");
const Io = std.Io;
const Repository = @import("repository.zig").Repository;
const object_id = @import("object_id.zig");

pub const RefError = error{
    OutOfMemory,
    SystemResources,
    Unexpected,
};

pub const Ref = struct {
    /// Full ref name, e.g. "refs/heads/main" or "HEAD".
    name: []const u8,
    /// Hex object id the ref points at (after one level of symbolic ref
    /// resolution for HEAD). May point at a tag object.
    target: object_id.ObjectId,
};

pub const Refs = struct {
    allocator: std.mem.Allocator,
    refs: std.ArrayList(Ref),

    pub fn deinit(self: *Refs) void {
        for (self.refs.items) |r| {
            self.allocator.free(r.name);
        }
        self.refs.deinit(self.allocator);
    }
};

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn parseOidHex(hex_str: []const u8) ?object_id.ObjectId {
    const trimmed = std.mem.trimEnd(u8, hex_str, " \r\n");
    return object_id.ObjectId.fromHex(trimmed) catch null;
}

/// Read HEAD (resolving one level of symref) plus all refs under refs/,
/// combining loose refs and packed-refs. Loosely resolves symbolic refs one
/// level deep (sufficient for HEAD -> refs/heads/x).
pub fn readAll(allocator: std.mem.Allocator, repo: *const Repository) RefError!Refs {
    var refs: Refs = .{ .allocator = allocator, .refs = .empty };
    errdefer refs.deinit();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // packed-refs first; loose refs override them.
    const packed_path = std.fmt.bufPrint(&buf, "{s}/packed-refs", .{repo.common_dir}) catch return error.Unexpected;
    var packed_names: std.StringHashMapUnmanaged(object_id.ObjectId) = .empty;
    defer {
        var it = packed_names.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        packed_names.deinit(allocator);
    }
    readPackedRefs(allocator, packed_path, &packed_names) catch {};

    // Loose refs walk.
    const refs_root = std.fmt.bufPrint(&buf, "{s}/refs", .{repo.common_dir}) catch return error.Unexpected;
    var overridden = std.StringHashMapUnmanaged(void){};
    defer overridden.deinit(allocator);
    try walkLoose(allocator, refs_root, "refs", &refs, &overridden);

    // Add packed refs not shadowed by a loose ref of the same name.
    var pit = packed_names.iterator();
    while (pit.next()) |e| {
        if (overridden.contains(e.key_ptr.*)) continue;
        const name = try allocator.dupe(u8, e.key_ptr.*);
        try refs.refs.append(allocator, .{ .name = name, .target = e.value_ptr.* });
    }

    // HEAD last.
    const head_path = std.fmt.bufPrint(&buf, "{s}/HEAD", .{repo.git_dir}) catch return error.Unexpected;
    if (readRefFile(head_path)) |target| {
        const name = try allocator.dupe(u8, "HEAD");
        try refs.refs.append(allocator, .{ .name = name, .target = target });
    }

    return refs;
}

fn readRefFile(path: []const u8) ?object_id.ObjectId {
    var fbuf: [4096]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io(), path, &fbuf) catch return null;
    const trimmed = std.mem.trimEnd(u8, data, " \r\n");
    if (std.mem.startsWith(u8, trimmed, "ref:")) {
        // Symbolic ref: "ref: refs/heads/main". Resolve the target file
        // relative to the same refs root (path's dir is the git dir).
        const target_name = std.mem.trim(u8, trimmed[4..], " \t");
        var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const git_dir = std.fs.path.dirname(path) orelse return null;
        const target_path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ git_dir, target_name }) catch return null;
        if (readRefFile(target_path)) |t| return t;
        // Fall back to packed-refs for the target.
        const packed_path = std.fmt.bufPrint(&pbuf, "{s}/packed-refs", .{git_dir}) catch return null;
        var fbuf2: [4096]u8 = undefined;
        const pdata = std.Io.Dir.cwd().readFile(io(), packed_path, &fbuf2) catch return null;
        var lines = std.mem.splitScalar(u8, pdata, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (std.mem.eql(u8, line[sp + 1 ..], target_name)) {
                return parseOidHex(line[0..sp]);
            }
        }
        return null;
    }
    return parseOidHex(trimmed);
}

fn readPackedRefs(allocator: std.mem.Allocator, path: []const u8, out: *std.StringHashMapUnmanaged(object_id.ObjectId)) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, std.Io.Limit.limited64(1 << 30)) catch return;
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const oid = parseOidHex(line[0..sp]) orelse continue;
        const name = try allocator.dupe(u8, line[sp + 1 ..]);
        try out.put(allocator, name, oid);
    }
}

fn walkLoose(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ref_prefix: []const u8,
    refs: *Refs,
    overridden: *std.StringHashMapUnmanaged(void),
) RefError!void {
    var d = std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true }) catch return;
    defer d.close(io());
    var it = d.iterate();
    while (it.next(io()) catch return error.Unexpected) |ent| {
        var nbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const child_path = std.fmt.bufPrint(&nbuf, "{s}/{s}", .{ dir_path, ent.name }) catch continue;
        switch (ent.kind) {
            .directory => {
                // Recurse with an allocated prefix.
                const prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_prefix, ent.name });
                defer allocator.free(prefix);
                try walkLoose(allocator, child_path, prefix, refs, overridden);
            },
            .file, .sym_link => {
                if (readRefFile(child_path)) |target| {
                    const name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ref_prefix, ent.name });
                    try refs.refs.append(allocator, .{ .name = name, .target = target });
                    try overridden.put(allocator, name, {});
                }
            },
            else => {},
        }
    }
}
