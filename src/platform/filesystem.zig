const std = @import("std");

pub const SizeError = error{
    AccessDenied,
    OutOfMemory,
    SystemResources,
    Unexpected,
};

/// Recursively sum the sizes of all regular files under `path` (which may
/// itself be a file). Symlinks are not followed. Returns 0 for a missing path.
pub fn entrySize(path: []const u8) SizeError!u64 {
    var d = std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
        else => {
            // Maybe it is a plain file.
            const st = std.Io.Dir.cwd().statFile(io(), path, .{}) catch return error.Unexpected;
            return st.size;
        },
    };
    defer d.close(io());
    return dirSize(&d);
}

pub fn dirSize(d: *std.Io.Dir) SizeError!u64 {
    var total: u64 = 0;
    var it = d.iterate();
    while (it.next(io()) catch return error.Unexpected) |ent| {
        switch (ent.kind) {
            .file => {
                const st = d.statFile(io(), ent.name, .{}) catch continue;
                total += st.size;
            },
            .directory => {
                var sub = d.openDir(io(), ent.name, .{ .iterate = true }) catch continue;
                defer sub.close(io());
                total += try dirSize(&sub);
            },
            else => {},
        }
    }
    return total;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "dir size on temp tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(tio, .{ .sub_path = "a.txt", .data = "12345" });
    try tmp.dir.createDirPath(tio, "sub/deep");
    try tmp.dir.writeFile(tio, .{ .sub_path = "sub/b.txt", .data = "abc" });
    try tmp.dir.writeFile(tio, .{ .sub_path = "sub/deep/c.txt", .data = "x" });
    var d = tmp.dir.openDir(tio, ".", .{ .iterate = true }) catch return error.Unexpected;
    defer d.close(tio);
    const total = try dirSize(&d);
    try std.testing.expectEqual(@as(u64, 9), total);
}
