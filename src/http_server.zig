const std = @import("std");
const tsdb = @import("tsdb");

/// 极简 HTTP 文件服务器，内嵌 webui/index.html
/// 使用 POSIX socket 实现（Zig 0.16 兼容）
/// 仅提供：
///   GET  /           -> 返回测试页面
///   GET  /index.html -> 返回测试页面
///   POST /api/write  -> 写入数据（body 为 line protocol）
///   GET  /api/query  -> 查询数据（query 参数：series_id, start, end）
///   GET  /api/stats  -> 服务器统计
pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    engine: *tsdb.Engine,
    port: u16,

    const INDEX_HTML = @embedFile("webui/index.html");

    pub fn init(allocator: std.mem.Allocator, engine: *tsdb.Engine, port: u16) HttpServer {
        return .{
            .allocator = allocator,
            .engine = engine,
            .port = port,
        };
    }

    pub fn start(self: *const HttpServer) !void {
        const srv_log = std.log.scoped(.http);
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        defer _ = c.close(fd);

        // SO_REUSEADDR
        var reuse: c_int = 1;
        _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &reuse, @sizeOf(c_int));

        var addr: c.sockaddr_in = .{
            .sin_len = @sizeOf(c.sockaddr_in),
            .sin_family = c.AF_INET,
            .sin_port = std.mem.nativeToBig(u16, self.port),
            .sin_addr = c.INADDR_ANY,
            .sin_zero = .{0} ** 8,
        };

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_in)) < 0) {
            srv_log.err("HTTP bind failed on port {d}", .{self.port});
            return error.BindFailed;
        }
        if (c.listen(fd, 10) < 0) return error.ListenFailed;

        srv_log.info("HTTP test server listening on http://0.0.0.0:{d}", .{self.port});

        while (true) {
            var client_addr: c.sockaddr_in = undefined;
            var addr_len: c_uint = @sizeOf(c.sockaddr_in);
            const client_fd = c.accept(fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) continue;

            self.handleConnection(client_fd) catch |err| {
                srv_log.err("HTTP handle error: {s}", .{@errorName(err)});
            };
            _ = c.close(client_fd);
        }
    }

    fn handleConnection(self: *const HttpServer, client_fd: c_int) !void {
        var buf: [8192]u8 = undefined;
        const n = c.recv(client_fd, &buf, buf.len, 0);
        if (n <= 0) return;
        const request = buf[0..@as(usize, @intCast(n))];

        if (std.mem.startsWith(u8, request, "GET / ") or std.mem.startsWith(u8, request, "GET /index.html")) {
            try sendResponse(client_fd, "200 OK", "text/html; charset=utf-8", INDEX_HTML);
        } else if (std.mem.startsWith(u8, request, "POST /api/write")) {
            try self.handleHttpWrite(client_fd, request);
        } else if (std.mem.startsWith(u8, request, "GET /api/query")) {
            try self.handleHttpQuery(client_fd, request);
        } else if (std.mem.startsWith(u8, request, "GET /api/stats")) {
            try self.handleHttpStats(client_fd);
        } else if (std.mem.startsWith(u8, request, "OPTIONS ")) {
            // CORS preflight
            try sendCorsResponse(client_fd);
        } else {
            try sendResponse(client_fd, "404 Not Found", "text/plain", "Not Found");
        }
    }

    fn handleHttpWrite(self: *const HttpServer, client_fd: c_int, request: []const u8) !void {
        // 解析 body：找到 \r\n\r\n 后的内容
        const body_sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try sendJson(client_fd, "{\"status\":\"error\",\"msg\":\"missing body\"}");
            return;
        };
        const body = request[body_sep + 4 ..];

        const parsed = try self.engine.parseLineProtocol(body);
        if (parsed) |p| {
            defer {
                self.allocator.free(p.key.metric);
                for (p.key.tags) |tag| {
                    self.allocator.free(tag.key);
                    self.allocator.free(tag.value);
                }
                self.allocator.free(p.key.tags);
            }
            const sid = p.key.computeId();
            try self.engine.write(p.key, p.point);
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"ok\",\"written\":1,\"series_id\":{d}}}", .{sid});
            try sendJson(client_fd, resp);
        } else {
            try sendJson(client_fd, "{\"status\":\"error\",\"msg\":\"parse failed\"}");
        }
    }

    fn handleHttpQuery(self: *const HttpServer, client_fd: c_int, request: []const u8) !void {
        const sid = extractQueryU64(request, "series_id") orelse 0;
        const q_start = extractQueryI64(request, "start") orelse 0;
        const q_end = extractQueryI64(request, "end") orelse std.math.maxInt(i64);

        const points = try self.engine.queryRange(sid, q_start, q_end, self.allocator);
        defer self.allocator.free(points);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, "{\"status\":\"ok\",\"points\":[");
        for (points, 0..) |p, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");
            var item: [128]u8 = undefined;
            const item_str = try std.fmt.bufPrint(&item, "{{\"ts\":{d},\"v\":{d:.6}}}", .{ p.timestamp, p.value });
            try json.appendSlice(self.allocator, item_str);
        }
        try json.appendSlice(self.allocator, "]}");

        try sendJson(client_fd, json.items);
    }

    fn handleHttpStats(self: *const HttpServer, client_fd: c_int) !void {
        self.engine.lock.lock();
        defer self.engine.lock.unlock();

        var resp_buf: [512]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"ok\",\"hot_start\":{d},\"hot_end\":{d},\"readonly\":{d},\"disk\":{d}}}", .{
            self.engine.hot_partition.start_time,
            self.engine.hot_partition.end_time,
            self.engine.readonly_partitions.items.len,
            self.engine.disk_partitions.items.len,
        });
        try sendJson(client_fd, resp);
    }

    fn sendResponse(client_fd: c_int, status: []const u8, content_type: []const u8, body: []const u8) !void {
        var header_buf: [512]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len });
        _ = c.send(client_fd, header.ptr, header.len, 0);
        _ = c.send(client_fd, body.ptr, body.len, 0);
    }

    fn sendJson(client_fd: c_int, body: []const u8) !void {
        try sendResponse(client_fd, "200 OK", "application/json", body);
    }

    fn sendCorsResponse(client_fd: c_int) !void {
        const headers = "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n";
        _ = c.send(client_fd, headers.ptr, headers.len, 0);
    }
};

// 从 HTTP 请求 URL 中提取 query 参数
fn extractQueryU64(request: []const u8, key: []const u8) ?u64 {
    const path_end = std.mem.indexOf(u8, request, " HTTP/1.") orelse return null;
    const path = request[0..path_end];
    const query_start = std.mem.indexOf(u8, path, "?") orelse return null;
    const query = path[query_start + 1 ..];

    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=", .{key}) catch return null;
    const start = std.mem.indexOf(u8, query, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfAnyPos(u8, query, val_start, "& ") orelse query.len;
    return std.fmt.parseInt(u64, query[val_start..val_end], 10) catch null;
}

fn extractQueryI64(request: []const u8, key: []const u8) ?i64 {
    const path_end = std.mem.indexOf(u8, request, " HTTP/1.") orelse return null;
    const path = request[0..path_end];
    const query_start = std.mem.indexOf(u8, path, "?") orelse return null;
    const query = path[query_start + 1 ..];

    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=", .{key}) catch return null;
    const start = std.mem.indexOf(u8, query, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfAnyPos(u8, query, val_start, "& ") orelse query.len;
    return std.fmt.parseInt(i64, query[val_start..val_end], 10) catch null;
}

// POSIX socket 包装（macOS / Linux 兼容）
const c = struct {
    pub extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    pub extern "c" fn bind(sockfd: c_int, addr: *const anyopaque, addrlen: c_uint) c_int;
    pub extern "c" fn listen(sockfd: c_int, backlog: c_int) c_int;
    pub extern "c" fn accept(sockfd: c_int, addr: ?*anyopaque, addrlen: ?*c_uint) c_int;
    pub extern "c" fn recv(sockfd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
    pub extern "c" fn send(sockfd: c_int, buf: *const anyopaque, len: usize, flags: c_int) isize;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;

    const AF_INET: c_int = 2;
    const SOCK_STREAM: c_int = 1;
    const SOL_SOCKET: c_int = 1;
    const SO_REUSEADDR: c_int = 2;
    const INADDR_ANY: u32 = 0;

    const sockaddr_in = extern struct {
        sin_len: u8 = @sizeOf(sockaddr_in),
        sin_family: u8 = 2,
        sin_port: u16,
        sin_addr: u32,
        sin_zero: [8]u8 = .{0} ** 8,
    };
};

test "extractQueryU64" {
    try std.testing.expectEqual(@as(?u64, 123), extractQueryU64("GET /api/query?series_id=123&start=0 HTTP/1.1", "series_id"));
    try std.testing.expectEqual(@as(?u64, null), extractQueryU64("GET /api/query?start=0 HTTP/1.1", "series_id"));
}
