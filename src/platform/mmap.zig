const std = @import("std");
const posix = std.posix;

pub const MapError = error{
    OpenFailed,
    StatFailed,
    EmptyFile,
    MapFailed,
    NotFile,
};

/// Read-only memory-mapped file. The mapping is valid for the lifetime of
/// this struct; `data` is the mapped bytes.
pub const MappedFile = struct {
    data: []align(std.heap.page_size_min) const u8,
    file: std.Io.File,

    pub fn init(path: []const u8) MapError!MappedFile {
        const file = std.Io.Dir.cwd().openFile(io(), path, .{}) catch return error.OpenFailed;
        return initFile(file);
    }

    pub fn initFile(file: std.Io.File) MapError!MappedFile {
        const stat = file.stat(io()) catch return error.StatFailed;
        if (stat.kind != .file) return error.NotFile;
        if (stat.size == 0) return error.EmptyFile;
        const size: usize = @intCast(stat.size);
        const data = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0) catch return error.MapFailed;
        return .{ .data = data, .file = file };
    }

    pub fn deinit(self: *MappedFile) void {
        posix.munmap(self.data);
        self.file.close(io());
    }
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "mmap file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tio = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(tio, .{ .sub_path = "hello.txt", .data = "hello world" });
    const path_z = try tmp.dir.realPathFileAlloc(tio, "hello.txt", std.testing.allocator);
    defer std.testing.allocator.free(path_z);
    var mf = try MappedFile.init(path_z);
    defer mf.deinit();
    try std.testing.expectEqualStrings("hello world", mf.data);
}

