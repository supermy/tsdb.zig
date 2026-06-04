const std = @import("std");

fn toZ(path: []const u8, buf: *[1025]u8) ![:0]u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    const printed = std.fmt.bufPrint(buf, "{s}", .{path}) catch return error.NameTooLong;
    buf[printed.len] = 0;
    return buf[0..printed.len :0];
}

/// 创建目录（包含父目录），使用 std.c.mkdir
pub fn makePath(path: []const u8) !void {
    var buf: [1025]u8 = undefined;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            const dir = path[0..i];
            const dir_z = try toZ(dir, &buf);
            _ = std.c.mkdir(dir_z.ptr, 0o755);
        }
    }
    const path_z = try toZ(path, &buf);
    _ = std.c.mkdir(path_z.ptr, 0o755);
}

/// 删除文件或空目录
pub fn remove(path: []const u8) !void {
    var buf: [1025]u8 = undefined;
    const path_z = try toZ(path, &buf);
    if (std.c.unlink(path_z.ptr) != 0) {
        if (std.c.rmdir(path_z.ptr) != 0) {
            return error.CannotRemove;
        }
    }
}

/// 递归删除目录树
pub fn deleteTree(path: []const u8) !void {
    var buf: [1025]u8 = undefined;
    const path_z = try toZ(path, &buf);

    // 尝试直接删除（若是文件或空目录）
    if (std.c.unlink(path_z.ptr) == 0 or std.c.rmdir(path_z.ptr) == 0) return;

    // 非空目录：遍历并递归删除
    const dir = std.c.opendir(path_z.ptr) orelse return error.CannotOpenDir;
    defer _ = std.c.closedir(dir);

    while (true) {
        const entry = std.c.readdir(dir) orelse break;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const child = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, name });
        defer std.heap.page_allocator.free(child);
        try deleteTree(child);
    }

    _ = std.c.rmdir(path_z.ptr);
}

/// 读取整个文件到内存
pub fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buf: [1025]u8 = undefined;
    const path_z = try toZ(path, &buf);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);

    const size = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (size < 0) return error.SeekError;
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);

    const data = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(data);

    var total_read: usize = 0;
    while (total_read < data.len) {
        const n = std.c.read(fd, data.ptr + total_read, data.len - total_read);
        if (n <= 0) return error.ReadError;
        total_read += @intCast(n);
    }
    return data;
}

/// 将数据写入文件（覆盖）
pub fn writeFile(path: []const u8, data: []const u8) !void {
    var buf: [1025]u8 = undefined;
    const path_z = try toZ(path, &buf);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.FileCreateFailed;
    defer _ = std.c.close(fd);

    var total_written: usize = 0;
    while (total_written < data.len) {
        const n = std.c.write(fd, data.ptr + total_written, data.len - total_written);
        if (n < 0) return error.WriteError;
        total_written += @intCast(n);
    }
}

/// 二进制写入器：将数据写入 ArrayList
pub const BinaryWriter = struct {
    buf: std.ArrayList(u8),

    pub fn init() BinaryWriter {
        return .{ .buf = std.ArrayList(u8).empty };
    }

    pub fn deinit(self: *BinaryWriter, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn writeAll(self: *BinaryWriter, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(allocator, bytes);
    }

    pub fn writeInt(self: *BinaryWriter, comptime T: type, value: T, endian: std.builtin.Endian, allocator: std.mem.Allocator) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, endian);
        try self.buf.appendSlice(allocator, &bytes);
    }

    pub fn items(self: *const BinaryWriter) []const u8 {
        return self.buf.items;
    }

    pub fn len(self: *const BinaryWriter) usize {
        return self.buf.items.len;
    }
};

/// 二进制读取器：从字节切片解析数据
pub const BinaryReader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) BinaryReader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn readAll(self: *BinaryReader, buf: []u8) !void {
        if (self.pos + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.pos..self.pos + buf.len]);
        self.pos += buf.len;
    }

    pub fn readInt(self: *BinaryReader, comptime T: type, endian: std.builtin.Endian) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.data.len) return error.EndOfStream;
        const result = std.mem.readInt(T, self.data[self.pos..self.pos + n][0..n], endian);
        self.pos += n;
        return result;
    }

    pub fn readSlice(self: *BinaryReader, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return error.EndOfStream;
        const result = self.data[self.pos..self.pos + len];
        self.pos += len;
        return result;
    }

    pub fn remaining(self: *const BinaryReader) usize {
        return self.data.len - self.pos;
    }
};
