const std = @import("std");
const Io = std.Io;
const object_id = @import("object_id.zig");
const git_object = @import("object.zig");
const mmap = @import("../platform/mmap.zig");

pub const LooseError = error{
    OutOfMemory,
    SystemResources,
    Unexpected,
    CorruptRepository,
};

pub const LooseObject = struct {
    id: object_id.ObjectId,
    /// Physical file size on disk.
    file_size: u64,
    /// Absolute path of the loose object file.
    path: []const u8,
    /// Lazily resolved object header (type + logical size); null until the
    /// file is first read via resolveHeader.
    header: ?git_object.Header,
};

pub const LooseList = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayList(LooseObject),

    pub fn deinit(self: *LooseList) void {
        for (self.objects.items) |o| self.allocator.free(o.path);
        self.objects.deinit(self.allocator);
    }
};

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Decompress only the `"<type> <size>\x00"` header of a zlib-compressed Git
/// object, without materializing the payload. `data` is the compressed bytes.
pub fn readObjectHeader(data: []const u8) !git_object.Header {
    var in = Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in, .zlib, &window);
    var buf: [64]u8 = undefined;
    const n = decomp.reader.readSliceShort(&buf) catch return error.CorruptRepository;
    const parsed = git_object.parseHeader(buf[0..n]) catch return error.CorruptRepository;
    return parsed.header;
}

/// Inflate just the header of the loose object file at `path`.
pub fn readHeaderFromPath(path: []const u8) LooseError!git_object.Header {
    var mf = mmap.MappedFile.init(path) catch return error.CorruptRepository;
    defer mf.deinit();
    return readObjectHeader(mf.data) catch return error.CorruptRepository;
}

/// Resolve and cache a loose object's header (type + logical size) by
/// inflating the first bytes of its file. Scanning defers this so startup
/// cost stays proportional to the objects actually touched.
pub fn resolveHeader(o: *LooseObject) LooseError!git_object.Header {
    if (o.header) |h| return h;
    const h = try readHeaderFromPath(o.path);
    o.header = h;
    return h;
}

fn scanLooseFile(
    allocator: std.mem.Allocator,
    dir_name: []const u8,
    file_name: []const u8,
    path: []const u8,
    stat: Io.File.Stat,
    out: *LooseList,
) LooseError!void {
    // dir_name must be exactly two hex chars, file_name the remaining hex.
    if (dir_name.len != 2 or file_name.len < 2) return;
    var hex_buf: [128]u8 = undefined;
    if (dir_name.len + file_name.len > hex_buf.len) return;
    const full_hex = std.fmt.bufPrint(&hex_buf, "{s}{s}", .{ dir_name, file_name }) catch return;
    const id = object_id.ObjectId.fromHex(full_hex) catch return;

    const dup_path = try allocator.dupe(u8, path);
    errdefer allocator.free(dup_path);
    try out.objects.append(allocator, .{
        .id = id,
        .file_size = stat.size,
        .path = dup_path,
        .header = null,
    });
}

/// Enumerate loose objects under `<objects_dir>/xx/yyyy...`.
pub fn scan(allocator: std.mem.Allocator, objects_dir: []const u8) LooseError!LooseList {
    var list: LooseList = .{ .allocator = allocator, .objects = .empty };
    errdefer list.deinit();

    var odir = std.Io.Dir.cwd().openDir(io(), objects_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => return error.Unexpected,
    };
    defer odir.close(io());

    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var it = odir.iterate();
    while (it.next(io()) catch return error.Unexpected) |fanout| {
        if (fanout.kind != .directory) continue;
        var sub = odir.openDir(io(), fanout.name, .{ .iterate = true }) catch continue;
        defer sub.close(io());
        var sit = sub.iterate();
        while (sit.next(io()) catch return error.Unexpected) |obj_file| {
            if (obj_file.kind != .file) continue;
            const obj_path = std.fmt.bufPrint(&pbuf, "{s}/{s}/{s}", .{ objects_dir, fanout.name, obj_file.name }) catch continue;
            const st = std.Io.Dir.cwd().statFile(io(), obj_path, .{}) catch continue;
            try scanLooseFile(allocator, fanout.name, obj_file.name, obj_path, st, &list);
        }
    }
    return list;
}
