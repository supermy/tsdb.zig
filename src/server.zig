const std = @import("std");
const tsdb = @import("tsdb");

/// HTTP API Server：提供 InfluxDB Line Protocol 写入和 JSON 查询接口
/// 设计为单线程或线程池模型；此处为演示使用单线程 accept + 线程池处理请求
pub const Server = struct {
    allocator: std.mem.Allocator,
    engine: *tsdb.Engine,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, engine: *tsdb.Engine, port: u16) Server {
        return .{
            .allocator = allocator,
            .engine = engine,
            .port = port,
        };
    }

    pub fn start(self: *Server) !void {
        const address = std.net.Address.parseIp4("0.0.0.0", self.port) catch |err| {
            std.log.err("Failed to parse address: {}", .{err});
            return err;
        };
        var tcp_server = try address.listen(.{
            .reuse_address = true,
        });
        defer tcp_server.deinit();

        std.log.info("TSDB server listening on http://0.0.0.0:{d}", .{self.port});

        while (true) {
            const conn = tcp_server.accept() catch |err| {
                std.log.err("Accept error: {}", .{err});
                continue;
            };
            self.handleConnection(conn.stream) catch |err| {
                std.log.err("Connection error: {}", .{err});
            };
            conn.stream.close();
        }
    }

    fn handleConnection(self: *Server, stream: std.net.Stream) !void {
        // 动态缓冲区，支持大于 4096 的请求
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.ensureTotalCapacityPrecise(self.allocator, 4096);

        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&tmp) catch break;
            if (n == 0) break;
            try buf.appendSlice(self.allocator, tmp[0..n]);
            // 检测是否已读完（简化：如果读不满缓冲区则认为结束）
            if (n < tmp.len) break;
        }

        if (buf.items.len == 0) return;
        const request = buf.items;

        // 极简 HTTP 解析：只解析第一行
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const first_line = lines.next() orelse return error.BadRequest;

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return error.BadRequest;
        const path = parts.next() orelse return error.BadRequest;

        // 找到 body（两个 \r\n 之后）
        const body_sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse request.len;
        const body = if (body_sep + 4 <= request.len) request[body_sep + 4 ..] else "";

        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/write")) {
            try self.handleWrite(stream, body);
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/query")) {
            try self.handleQuery(stream, body);
        } else if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/stats")) {
            try self.handleStats(stream);
        } else {
            try sendResponse(stream, 404, "Not Found", "text/plain");
        }
    }

    fn handleWrite(self: *Server, stream: std.net.Stream, body: []const u8) !void {
        var lines = std.mem.splitScalar(u8, body, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = self.engine.parseLineProtocol(line) catch |err| {
                std.log.warn("Parse error on line: {}", .{err});
                continue;
            };
            if (parsed) |p| {
                // parseLineProtocol 返回深拷贝，write 内部会再次深拷贝，因此需要释放
                defer {
                    self.allocator.free(p.key.metric);
                    for (p.key.tags) |tag| {
                        self.allocator.free(tag.key);
                        self.allocator.free(tag.value);
                    }
                    self.allocator.free(p.key.tags);
                }
                self.engine.write(p.key, p.point) catch |err| {
                    std.log.warn("Write error: {}", .{err});
                    continue;
                };
                count += 1;
            }
        }

        var response_buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf, "{{\"written\":{d}}}\n", .{count});
        try sendResponse(stream, 200, response, "application/json");
    }

    fn handleQuery(self: *Server, stream: std.net.Stream, body: []const u8) !void {
        // 极简 JSON 解析：假设 body 为 {"series_id":123,"start":0,"end":1000}
        const series_id = parseJsonField(u64, body, "series_id") orelse 0;
        const query_start = parseJsonField(i64, body, "start") orelse 0;
        const query_end = parseJsonField(i64, body, "end") orelse std.math.maxInt(i64);

        const points = self.engine.queryRange(series_id, query_start, query_end, self.allocator) catch |err| {
            std.log.warn("Query error: {}", .{err});
            try sendResponse(stream, 500, "Query failed", "text/plain");
            return;
        };
        defer self.allocator.free(points);

        var response = std.ArrayList(u8).empty;
        defer response.deinit(self.allocator);
        try response.appendSlice(self.allocator, "[\n");
        for (points, 0..) |p, i| {
            if (i > 0) try response.appendSlice(self.allocator, ",\n");
            try response.writer().print("  {{\"timestamp\":{d},\"value\":{d:.6}}}", .{ p.timestamp, p.value });
        }
        try response.appendSlice(self.allocator, "\n]\n");
        try sendResponse(stream, 200, response.items, "application/json");
    }

    fn handleStats(self: *Server, stream: std.net.Stream) !void {
        self.engine.lock.lock();
        defer self.engine.lock.unlock();

        var response_buf: [512]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf, "{{\"hot_partition_start\":{d},\"hot_partition_end\":{d},\"readonly_partitions\":{d},\"disk_partitions\":{d}}}\n", .{
            self.engine.hot_partition.start_time,
            self.engine.hot_partition.end_time,
            self.engine.readonly_partitions.items.len,
            self.engine.disk_partitions.items.len,
        });
        try sendResponse(stream, 200, response, "application/json");
    }
};

fn sendResponse(stream: std.net.Stream, status: u16, body: []const u8, content_type: []const u8) !void {
    const reason = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{
        status, reason, content_type, body.len,
    });
    _ = try stream.write(header);
    _ = try stream.write(body);
}

fn parseJsonField(comptime T: type, json: []const u8, field: []const u8) ?T {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = blk: {
        for (val_start..json.len) |i| {
            const c = json[i];
            if (c == ',' or c == '}' or c == ' ') break :blk i;
        }
        break :blk json.len;
    };
    const val_str = std.mem.trim(u8, json[val_start..val_end], " \"");
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, val_str, 10) catch null,
        .float => std.fmt.parseFloat(T, val_str) catch null,
        else => if (val_str.len > 0) val_str else null,
    };
}

test "parseJsonField" {
    const json = "{\"series_id\":123,\"start\":0,\"end\":1000}";
    try std.testing.expectEqual(@as(u64, 123), parseJsonField(u64, json, "series_id").?);
    try std.testing.expectEqual(@as(i64, 0), parseJsonField(i64, json, "start").?);
    try std.testing.expectEqual(@as(i64, 1000), parseJsonField(i64, json, "end").?);
}
