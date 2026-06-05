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
    const README_MD = @embedFile("README.md");

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
        // 在堆上分配 1MB 缓冲区，支持大批量写入
        const alloc_buf = try self.allocator.alloc(u8, 1048576);
        defer self.allocator.free(alloc_buf);

        // 循环 recv 直到收完 HTTP 请求（或缓冲区满）
        var total: usize = 0;
        while (total < alloc_buf.len) {
            const n = c.recv(client_fd, alloc_buf.ptr + total, alloc_buf.len - total, 0);
            if (n <= 0) break;
            total += @as(usize, @intCast(n));

            // 检查是否已收到完整 HTTP 请求（header + body）
            if (total >= 4) {
                const req_so_far = alloc_buf[0..total];
                // 检查是否已收到 header 结束标记
                if (std.mem.indexOf(u8, req_so_far, "\r\n\r\n")) |body_start| {
                    // 解析 Content-Length 判断 body 是否收完
                    const header = req_so_far[0..body_start];
                    const cl_str = "Content-Length: ";
                    if (std.mem.indexOf(u8, header, cl_str)) |cl_pos| {
                        const cl_val_start = cl_pos + cl_str.len;
                        const cl_val_end = std.mem.indexOfAnyPos(u8, header, cl_val_start, "\r\n") orelse header.len;
                        const content_length = std.fmt.parseInt(usize, header[cl_val_start..cl_val_end], 10) catch 0;
                        const body_received = total - (body_start + 4);
                        if (body_received >= content_length) break;
                    } else {
                        // 无 Content-Length，header 结束即请求完成
                        break;
                    }
                }
            }
        }
        if (total == 0) return;
        const request = alloc_buf[0..total];

        if (std.mem.startsWith(u8, request, "GET / ") or std.mem.startsWith(u8, request, "GET /index.html")) {
            try sendResponse(client_fd, "200 OK", "text/html; charset=utf-8", INDEX_HTML);
        } else if (std.mem.startsWith(u8, request, "POST /api/write")) {
            try self.handleHttpWrite(client_fd, request);
        } else if (std.mem.startsWith(u8, request, "GET /api/query_metric")) {
            try self.handleHttpQueryMetric(client_fd, request);
        } else if (std.mem.startsWith(u8, request, "GET /api/query")) {
            try self.handleHttpQuery(client_fd, request);
        } else if (std.mem.startsWith(u8, request, "POST /api/resolve")) {
            try self.handleHttpResolve(client_fd, request);
        } else if (std.mem.startsWith(u8, request, "GET /api/stats")) {
            try self.handleHttpStats(client_fd);
        } else if (std.mem.startsWith(u8, request, "POST /api/flush")) {
            try self.handleHttpFlush(client_fd);
        } else if (std.mem.startsWith(u8, request, "GET /api/export")) {
            try self.handleHttpExport(client_fd);
        } else if (std.mem.startsWith(u8, request, "GET /api/readme")) {
            try self.handleHttpReadme(client_fd);
        } else if (std.mem.startsWith(u8, request, "OPTIONS ")) {
            // CORS preflight
            try sendCorsResponse(client_fd);
        } else {
            try sendResponse(client_fd, "404 Not Found", "text/plain", "Not Found");
        }
    }

    /// 将多字段 Line Protocol 拆分为多个单字段行。
    /// 例如：cpu,host=A usage=95.07,temperature=56.76 123456
    /// 拆分为：cpu,host=A,_f=usage usage=95.07 123456\ncpu,host=A,_f=temperature temperature=56.76 123456\n
    fn splitMultiFieldLine(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
        // 找到第一个空格
        const first_space = std.mem.indexOf(u8, line, " ") orelse {
            return allocator.dupe(u8, line);
        };
        const prefix = line[0..first_space];
        var rest = line[first_space + 1..];

        // 尝试找到 timestamp（最后一个空格后的纯数字）
        var ts_part: ?[]const u8 = null;
        const last_space = std.mem.lastIndexOf(u8, rest, " ");
        if (last_space) |ls| {
            const after = rest[ls + 1..];
            if (after.len > 0) {
                var all_digit = true;
                for (after) |ch| {
                    if (!std.ascii.isDigit(ch) and ch != '-') {
                        all_digit = false;
                        break;
                    }
                }
                if (all_digit) {
                    ts_part = after;
                    rest = rest[0..ls];
                }
            }
        }

        // 检查是否有多个 fields（逗号分隔）
        const comma_count = std.mem.count(u8, rest, ",");
        if (comma_count == 0) {
            return allocator.dupe(u8, line);
        }

        // 多字段，构造新的 multi-line 字符串
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        var field_iter = std.mem.splitScalar(u8, rest, ',');
        while (field_iter.next()) |field| {
            if (field.len == 0) continue;
            const eq_pos = std.mem.indexOf(u8, field, "=");
            if (eq_pos == null) continue;
            const field_name = field[0..eq_pos.?];

            try result.appendSlice(allocator, prefix);
            try result.appendSlice(allocator, ",_f=");
            try result.appendSlice(allocator, field_name);
            try result.appendSlice(allocator, " ");
            try result.appendSlice(allocator, field);
            if (ts_part) |ts| {
                try result.appendSlice(allocator, " ");
                try result.appendSlice(allocator, ts);
            }
            try result.appendSlice(allocator, "\n");
        }

        return result.toOwnedSlice(allocator);
    }

    fn handleHttpWrite(self: *const HttpServer, client_fd: c_int, request: []const u8) !void {
        // 解析 body：找到 \r\n\r\n 后的内容
        const body_sep = std.mem.indexOf(u8, request, "\r\n\r\n") orelse {
            try sendJson(client_fd, "{\"status\":\"error\",\"msg\":\"missing body\"}");
            return;
        };
        const body = request[body_sep + 4 ..];

        // 支持批量写入：按换行拆分，逐行解析写入
        var total_written: u32 = 0;
        var first_sid: u64 = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) continue;

            // 拆分多字段行
            const processed = splitMultiFieldLine(self.allocator, line) catch |err| {
                const srv_log = std.log.scoped(.http);
                srv_log.err("split fields error: {s}", .{@errorName(err)});
                continue;
            };
            defer self.allocator.free(processed);

            var processed_lines = std.mem.splitScalar(u8, processed, '\n');
            while (processed_lines.next()) |pl| {
                if (pl.len == 0) continue;

                const parsed = self.engine.parseLineProtocol(pl) catch |err| {
                    const srv_log = std.log.scoped(.http);
                    srv_log.err("parse error: {s}", .{@errorName(err)});
                    continue;
                };
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
                    if (total_written == 0) first_sid = sid;
                    self.engine.write(p.key, p.point) catch |err| {
                        const srv_log = std.log.scoped(.http);
                        srv_log.err("write error: {s}", .{@errorName(err)});
                        continue;
                    };
                    total_written += 1;
                    if (total_written <= 5 or total_written % 1000 == 0) {
                        const srv_log = std.log.scoped(.http);
                        srv_log.info("wrote point: series_id={d}, ts={d}, val={d:.2}", .{ sid, p.point.timestamp, p.point.value });
                    }
                }
            }
        }

        if (total_written > 0) {
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"ok\",\"written\":{d},\"series_id\":\"{d}\"}}", .{ total_written, first_sid });
            try sendJson(client_fd, resp);
        } else {
            try sendJson(client_fd, "{\"status\":\"error\",\"msg\":\"no valid lines written\"}");
        }
    }

    fn handleHttpQuery(self: *const HttpServer, client_fd: c_int, request: []const u8) !void {
        const sid = extractQueryU64(request, "series_id") orelse 0;
        const raw_start = extractQueryI64(request, "start") orelse 0;
        const raw_end = extractQueryI64(request, "end") orelse std.math.maxInt(i64);

        // 前端使用纳秒时间戳，内部存储使用毫秒：若值大于 1e15 则视为纳秒并转换
        const q_start = if (raw_start > 1_000_000_000_000_000) @divFloor(raw_start, 1_000_000) else raw_start;
        const q_end = if (raw_end > 1_000_000_000_000_000) @divFloor(raw_end, 1_000_000) else raw_end;

        const points = try self.engine.queryRangeEx(sid, q_start, q_end, self.allocator);
        defer self.allocator.free(points);

        const srv_log = std.log.scoped(.http);
        srv_log.info("query series_id={d}, range=[{d},{d}], found {d} points", .{ sid, q_start, q_end, points.len });

        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, "{\"status\":\"ok\",\"points\":[");
        for (points, 0..) |p, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");
            // 构建 tags 字符串
            var tags_buf: [1024]u8 = undefined;
            var tags_len: usize = 0;
            for (p.tags, 0..) |tag, ti| {
                if (ti > 0) {
                    tags_buf[tags_len] = ',';
                    tags_len += 1;
                }
                @memcpy(tags_buf[tags_len .. tags_len + tag.key.len], tag.key);
                tags_len += tag.key.len;
                tags_buf[tags_len] = '=';
                tags_len += 1;
                @memcpy(tags_buf[tags_len .. tags_len + tag.value.len], tag.value);
                tags_len += tag.value.len;
            }
            const tags_str = tags_buf[0..tags_len];

            var item: [512]u8 = undefined;
            const item_str = try std.fmt.bufPrint(&item, "{{\"ts\":{d},\"v\":{d:.6},\"metric\":\"{s}\",\"tags\":\"{s}\",\"series_id\":\"{d}\"}}", .{ p.timestamp, p.value, p.metric, tags_str, p.series_id });
            try json.appendSlice(self.allocator, item_str);
        }
        try json.appendSlice(self.allocator, "]}");

        try sendJson(client_fd, json.items);
    }

    fn handleHttpQueryMetric(self: *const HttpServer, client_fd: c_int, request: []const u8) !void {
        const metric = extractQueryString(request, "metric") orelse {
            try sendJson(client_fd, "{\"status\":\"error\",\"msg\":\"missing metric\"}");
            return;
        };
        const raw_start = extractQueryI64(request, "start") orelse 0;
        const raw_end = extractQueryI64(request, "end") orelse std.math.maxInt(i64);

        const q_start = if (raw_start > 1_000_000_000_000_000) @divFloor(raw_start, 1_000_000) else raw_start;
        const q_end = if (raw_end > 1_000_000_000_000_000) @divFloor(raw_end, 1_000_000) else raw_end;

        const points = try self.engine.queryByMetricEx(metric, q_start, q_end, self.allocator);
        defer self.allocator.free(points);

        const srv_log = std.log.scoped(.http);
        srv_log.info("query_metric metric={s}, range=[{d},{d}], found {d} points", .{ metric, q_start, q_end, points.len });

        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, "{\"status\":\"ok\",\"points\":[");
        for (points, 0..) |p, i| {
            if (i > 0) try json.appendSlice(self.allocator, ",");
            // 构建 tags 字符串
            var tags_buf: [1024]u8 = undefined;
            var tags_len: usize = 0;
            for (p.tags, 0..) |tag, ti| {
                if (ti > 0) {
                    tags_buf[tags_len] = ',';
                    tags_len += 1;
                }
                @memcpy(tags_buf[tags_len .. tags_len + tag.key.len], tag.key);
                tags_len += tag.key.len;
                tags_buf[tags_len] = '=';
                tags_len += 1;
                @memcpy(tags_buf[tags_len .. tags_len + tag.value.len], tag.value);
                tags_len += tag.value.len;
            }
            const tags_str = tags_buf[0..tags_len];

            var item: [512]u8 = undefined;
            const item_str = try std.fmt.bufPrint(&item, "{{\"ts\":{d},\"v\":{d:.6},\"metric\":\"{s}\",\"tags\":\"{s}\",\"series_id\":\"{d}\"}}", .{ p.timestamp, p.value, p.metric, tags_str, p.series_id });
            try json.appendSlice(self.allocator, item_str);
        }
        try json.appendSlice(self.allocator, "]}");

        try sendJson(client_fd, json.items);
    }

    fn handleHttpResolve(self: *const HttpServer, client_fd: c_int, request: []const u8) !void {
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
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"ok\",\"series_id\":\"{d}\"}}", .{sid});
            try sendJson(client_fd, resp);
        } else {
            try sendJson(client_fd, "{\"status\":\"error\",\"msg\":\"parse failed\"}");
        }
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

    fn handleHttpFlush(self: *const HttpServer, client_fd: c_int) !void {
        self.engine.flushHotPartition() catch |err| {
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"error\",\"msg\":\"{s}\"}}", .{@errorName(err)});
            try sendJson(client_fd, resp);
            return;
        };
        try sendJson(client_fd, "{\"status\":\"ok\",\"msg\":\"flushed\"}");
    }

    fn handleHttpExport(self: *const HttpServer, client_fd: c_int) !void {
        // 先落盘，确保热分区数据也能导出
        self.engine.flushHotPartition() catch {};

        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);

        // 导出热分区（flush 后可能还有新数据）
        try self.exportPartition(self.engine.hot_partition, &output);

        // 导出只读分区
        for (self.engine.readonly_partitions.items) |partition| {
            try self.exportPartition(partition, &output);
        }

        // 加载并导出磁盘分区
        var i: usize = 0;
        while (i < self.engine.disk_partitions.items.len) {
            const meta = self.engine.disk_partitions.items[i];
            self.engine.loadPartition(meta.file_path) catch {
                i += 1;
                continue;
            };
            self.engine.allocator.free(meta.file_path);
            _ = self.engine.disk_partitions.orderedRemove(i);
            const loaded = self.engine.readonly_partitions.items[self.engine.readonly_partitions.items.len - 1];
            try self.exportPartition(loaded, &output);
        }

        try sendResponse(client_fd, "200 OK", "text/plain", output.items);
    }

    fn exportPartition(self: *const HttpServer, partition: *tsdb.MemoryPartition, output: *std.ArrayList(u8)) !void {
        var sit = partition.series_keys.iterator();
        while (sit.next()) |entry| {
            const sid = entry.key_ptr.*;
            const key = entry.value_ptr.*;
            const sd = partition.series_map.getPtr(sid) orelse continue;

            for (0..sd.len()) |j| {
                // 从 tags 中提取 _f=fieldname，还原为原始 Line Protocol 格式
                var field_name: []const u8 = "value";
                try output.appendSlice(self.allocator, key.metric);
                for (key.tags) |tag| {
                    if (std.mem.eql(u8, tag.key, "_f")) {
                        field_name = tag.value;
                        continue;
                    }
                    try output.appendSlice(self.allocator, ",");
                    try output.appendSlice(self.allocator, tag.key);
                    try output.appendSlice(self.allocator, "=");
                    try output.appendSlice(self.allocator, tag.value);
                }
                try output.appendSlice(self.allocator, " ");
                try output.appendSlice(self.allocator, field_name);
                try output.appendSlice(self.allocator, "=");
                const val = sd.values.items[j];
                if (val == @floor(val) and @abs(val) < 1e15) {
                    var val_buf: [64]u8 = undefined;
                    const val_str = try std.fmt.bufPrint(&val_buf, "{d:.0}i", .{val});
                    try output.appendSlice(self.allocator, val_str);
                } else {
                    var val_buf: [64]u8 = undefined;
                    const val_str = try std.fmt.bufPrint(&val_buf, "{d}", .{val});
                    try output.appendSlice(self.allocator, val_str);
                }
                try output.appendSlice(self.allocator, " ");
                // 毫秒转纳秒
                var ts_buf: [32]u8 = undefined;
                const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{sd.timestamps.items[j] * 1_000_000});
                try output.appendSlice(self.allocator, ts_str);
                try output.appendSlice(self.allocator, "\n");
            }
        }
    }

    fn handleHttpReadme(self: *const HttpServer, client_fd: c_int) !void {
        // README_MD 是编译时嵌入的 README.md 内容
        var json = std.ArrayList(u8).empty;
        defer json.deinit(self.allocator);
        try json.appendSlice(self.allocator, "{\"status\":\"ok\",\"content\":\"");
        for (README_MD) |ch| {
            switch (ch) {
                '\\' => try json.appendSlice(self.allocator, "\\\\"),
                '"' => try json.appendSlice(self.allocator, "\\\""),
                '\n' => try json.appendSlice(self.allocator, "\\n"),
                '\r' => {},
                '\t' => try json.appendSlice(self.allocator, "\\t"),
                else => try json.append(self.allocator, ch),
            }
        }
        try json.appendSlice(self.allocator, "\"}");
        try sendJson(client_fd, json.items);
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
pub fn extractQueryU64(request: []const u8, key: []const u8) ?u64 {
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

pub fn extractQueryI64(request: []const u8, key: []const u8) ?i64 {
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

pub fn extractQueryString(request: []const u8, key: []const u8) ?[]const u8 {
    const path_end = std.mem.indexOf(u8, request, " HTTP/1.") orelse return null;
    const path = request[0..path_end];
    const query_start = std.mem.indexOf(u8, path, "?") orelse return null;
    const query = path[query_start + 1 ..];

    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "{s}=", .{key}) catch return null;
    const start = std.mem.indexOf(u8, query, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfAnyPos(u8, query, val_start, "& ") orelse query.len;
    return query[val_start..val_end];
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

test "extractQueryI64" {
    try std.testing.expectEqual(@as(?i64, 1000), extractQueryI64("GET /api/query?start=1000&end=2000 HTTP/1.1", "start"));
    try std.testing.expectEqual(@as(?i64, -500), extractQueryI64("GET /api/query?start=-500 HTTP/1.1", "start"));
    try std.testing.expectEqual(@as(?i64, null), extractQueryI64("GET /api/query HTTP/1.1", "start"));
}

test "extractQueryString" {
    const result = extractQueryString("GET /api/query_metric?metric=cpu&start=0 HTTP/1.1", "metric");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("cpu", result.?);
    try std.testing.expectEqual(@as(?[]const u8, null), extractQueryString("GET /api/query HTTP/1.1", "metric"));
}

test "extractQueryU64 missing key returns null" {
    try std.testing.expectEqual(@as(?u64, null), extractQueryU64("GET /api/query?start=0 HTTP/1.1", "series_id"));
}

test "extractQueryI64 no query string returns null" {
    try std.testing.expectEqual(@as(?i64, null), extractQueryI64("GET /api/query HTTP/1.1", "start"));
}

test "extractQueryString no query string returns null" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractQueryString("GET /api/query HTTP/1.1", "metric"));
}
