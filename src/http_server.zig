const std = @import("std");
const tsdb = @import("tsdb");

/// HTTP 文件服务器，基于 libevent evhttp 实现高性能事件驱动并发处理
/// 内嵌 webui/index.html，提供 REST API 测试接口
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
        const base = c.event_base_new() orelse return error.EventBaseNewFailed;
        defer c.event_base_free(base);

        const http = c.evhttp_new(base) orelse return error.EvhttpNewFailed;
        defer c.evhttp_free(http);

        if (c.evhttp_bind_socket(http, "0.0.0.0", self.port) < 0) {
            srv_log.err("HTTP bind failed on port {d}", .{self.port});
            return error.BindFailed;
        }

        c.evhttp_set_gencb(http, libeventGenericHandler, @ptrCast(self));

        srv_log.info("HTTP test server listening on http://0.0.0.0:{d}", .{self.port});
        _ = c.event_base_dispatch(base);
    }

    // ------------------------------------------------------------------
    // 请求处理器（适配 libevent evhttp）
    // ------------------------------------------------------------------

    fn handleHttpWrite(self: *const HttpServer, req: ?*anyopaque, body: []const u8) !void {
        var total_written: u32 = 0;
        var first_sid: u64 = 0;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0) continue;

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
            sendEvJson(req, resp);
        } else {
            sendEvJson(req, "{\"status\":\"error\",\"msg\":\"no valid lines written\"}");
        }
    }

    fn handleHttpQuery(self: *const HttpServer, req: ?*anyopaque, fake_request: []const u8) !void {
        const sid = extractQueryU64(fake_request, "series_id") orelse 0;
        const raw_start = extractQueryI64(fake_request, "start") orelse 0;
        const raw_end = extractQueryI64(fake_request, "end") orelse std.math.maxInt(i64);

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

            var item: [1536]u8 = undefined;
            const item_str = try std.fmt.bufPrint(&item, "{{\"ts\":{d},\"v\":{d:.6},\"metric\":\"{s}\",\"tags\":\"{s}\",\"series_id\":\"{d}\"}}", .{ p.timestamp, p.value, p.metric, tags_str, p.series_id });
            try json.appendSlice(self.allocator, item_str);
        }
        try json.appendSlice(self.allocator, "]}");

        sendEvJson(req, json.items);
    }

    fn handleHttpQueryMetric(self: *const HttpServer, req: ?*anyopaque, fake_request: []const u8) !void {
        const metric = extractQueryString(fake_request, "metric") orelse {
            sendEvJson(req, "{\"status\":\"error\",\"msg\":\"missing metric\"}");
            return;
        };
        const raw_start = extractQueryI64(fake_request, "start") orelse 0;
        const raw_end = extractQueryI64(fake_request, "end") orelse std.math.maxInt(i64);

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

            var item: [1536]u8 = undefined;
            const item_str = try std.fmt.bufPrint(&item, "{{\"ts\":{d},\"v\":{d:.6},\"metric\":\"{s}\",\"tags\":\"{s}\",\"series_id\":\"{d}\"}}", .{ p.timestamp, p.value, p.metric, tags_str, p.series_id });
            try json.appendSlice(self.allocator, item_str);
        }
        try json.appendSlice(self.allocator, "]}");

        sendEvJson(req, json.items);
    }

    fn handleHttpResolve(self: *const HttpServer, req: ?*anyopaque, body: []const u8) !void {
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
            sendEvJson(req, resp);
        } else {
            sendEvJson(req, "{\"status\":\"error\",\"msg\":\"parse failed\"}");
        }
    }

    fn handleHttpStats(self: *const HttpServer, req: ?*anyopaque) !void {
        self.engine.lock.lock();
        defer self.engine.lock.unlock();

        var resp_buf: [512]u8 = undefined;
        const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"ok\",\"hot_start\":{d},\"hot_end\":{d},\"readonly\":{d},\"disk\":{d}}}", .{
            self.engine.hot_partition.start_time,
            self.engine.hot_partition.end_time,
            self.engine.readonly_partitions.items.len,
            self.engine.disk_partitions.items.len,
        });
        sendEvJson(req, resp);
    }

    fn handleHttpFlush(self: *const HttpServer, req: ?*anyopaque) !void {
        self.engine.flushHotPartition() catch |err| {
            var resp_buf: [256]u8 = undefined;
            const resp = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"error\",\"msg\":\"{s}\"}}", .{@errorName(err)});
            sendEvJson(req, resp);
            return;
        };
        sendEvJson(req, "{\"status\":\"ok\",\"msg\":\"flushed\"}");
    }

    fn handleHttpExport(self: *const HttpServer, req: ?*anyopaque) !void {
        self.engine.lock.lock();
        defer self.engine.lock.unlock();

        self.engine.flushHotPartition() catch {};

        var output = std.ArrayList(u8).empty;
        defer output.deinit(self.allocator);

        try self.exportPartition(self.engine.hot_partition, &output);
        for (self.engine.readonly_partitions.items) |partition| {
            try self.exportPartition(partition, &output);
        }

        var i: usize = 0;
        while (i < self.engine.disk_partitions.items.len) {
            const meta = self.engine.disk_partitions.items[i];
            self.engine.loadPartition(meta.file_path) catch {
                i += 1;
                continue;
            };
            self.allocator.free(meta.file_path);
            _ = self.engine.disk_partitions.orderedRemove(i);
            const loaded = self.engine.readonly_partitions.items[self.engine.readonly_partitions.items.len - 1];
            try self.exportPartition(loaded, &output);
        }

        sendEvResponse(req, 200, "OK", "text/plain", output.items);
    }

    fn exportPartition(self: *const HttpServer, partition: *tsdb.MemoryPartition, output: *std.ArrayList(u8)) !void {
        var sit = partition.series_keys.iterator();
        while (sit.next()) |entry| {
            const sid = entry.key_ptr.*;
            const key = entry.value_ptr.*;
            const sd = partition.series_map.getPtr(sid) orelse continue;

            for (0..sd.len()) |j| {
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
                var ts_buf: [32]u8 = undefined;
                const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{sd.timestamps.items[j] * 1_000_000});
                try output.appendSlice(self.allocator, ts_str);
                try output.appendSlice(self.allocator, "\n");
            }
        }
    }

    fn handleHttpReadme(self: *const HttpServer, req: ?*anyopaque) !void {
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
        sendEvJson(req, json.items);
    }

    /// 将多字段 Line Protocol 拆分为多个单字段行
    fn splitMultiFieldLine(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
        const first_space = std.mem.indexOf(u8, line, " ") orelse {
            return allocator.dupe(u8, line);
        };
        const prefix = line[0..first_space];
        var rest = line[first_space + 1 ..];

        var ts_part: ?[]const u8 = null;
        const last_space = std.mem.lastIndexOf(u8, rest, " ");
        if (last_space) |ls| {
            const after = rest[ls + 1 ..];
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

        const comma_count = std.mem.count(u8, rest, ",");
        if (comma_count == 0) {
            return allocator.dupe(u8, line);
        }

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
};

// ------------------------------------------------------------------
// libevent C 回调与响应辅助函数
// ------------------------------------------------------------------

fn libeventGenericHandler(req: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const self: *const HttpServer = @ptrCast(@alignCast(user_data.?));
    const uri = std.mem.span(c.evhttp_request_get_uri(req.?).?);
    const cmd = c.evhttp_request_get_command(req.?);

    // 读取 POST body
    var body: []const u8 = &[_]u8{};
    if (cmd == c.EVHTTP_REQ_POST) {
        const input_buf = c.evhttp_request_get_input_buffer(req.?);
        const body_len = c.evbuffer_get_length(input_buf);
        if (body_len > 0) {
            const body_ptr = c.evbuffer_pullup(input_buf, @intCast(body_len));
            if (body_ptr) |ptr| {
                body = @as([*]const u8, @ptrCast(ptr))[0..body_len];
            }
        }
    }

    // 构造伪请求字符串用于 extractQuery
    if (uri.len > 2048) {
        sendEvError(req.?, 414, "URI Too Long");
        return;
    }
    var fake_req_buf: [4096]u8 = undefined;
    const method_str = if (cmd == c.EVHTTP_REQ_POST) "POST" else "GET";
    const fake_req = std.fmt.bufPrint(&fake_req_buf, "{s} {s} HTTP/1.1\r\n\r\n", .{ method_str, uri }) catch {
        sendEvError(req.?, 400, "bad request");
        return;
    };

    // CORS
    const out_headers = c.evhttp_request_get_output_headers(req.?);
    _ = c.evhttp_add_header(out_headers, "Access-Control-Allow-Origin", "*");

    if (cmd == c.EVHTTP_REQ_GET and (std.mem.eql(u8, uri, "/") or std.mem.startsWith(u8, uri, "/index.html"))) {
        sendEvResponse(req.?, 200, "OK", "text/html; charset=utf-8", HttpServer.INDEX_HTML);
    } else if (cmd == c.EVHTTP_REQ_POST and std.mem.startsWith(u8, uri, "/api/write")) {
        self.handleHttpWrite(req.?, body) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_GET and std.mem.startsWith(u8, uri, "/api/query_metric")) {
        self.handleHttpQueryMetric(req.?, fake_req) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_GET and std.mem.startsWith(u8, uri, "/api/query")) {
        self.handleHttpQuery(req.?, fake_req) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_POST and std.mem.startsWith(u8, uri, "/api/resolve")) {
        self.handleHttpResolve(req.?, body) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_GET and std.mem.startsWith(u8, uri, "/api/stats")) {
        self.handleHttpStats(req.?) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_POST and std.mem.startsWith(u8, uri, "/api/flush")) {
        self.handleHttpFlush(req.?) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_GET and std.mem.startsWith(u8, uri, "/api/export")) {
        self.handleHttpExport(req.?) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_GET and std.mem.startsWith(u8, uri, "/api/readme")) {
        self.handleHttpReadme(req.?) catch |err| {
            sendEvError(req.?, 500, @errorName(err));
        };
    } else if (cmd == c.EVHTTP_REQ_OPTIONS) {
        sendEvCors(req.?);
    } else {
        sendEvResponse(req.?, 404, "Not Found", "text/plain", "Not Found");
    }
}

fn sendEvResponse(req: ?*anyopaque, code: c_int, reason: [*:0]const u8, content_type: [*:0]const u8, body: []const u8) void {
    const out_headers = c.evhttp_request_get_output_headers(req);
    _ = c.evhttp_add_header(out_headers, "Content-Type", content_type);
    const out_buf = c.evhttp_request_get_output_buffer(req);
    _ = c.evbuffer_add(out_buf, body.ptr, body.len);
    c.evhttp_send_reply(req, code, reason, out_buf);
}

fn sendEvJson(req: ?*anyopaque, body: []const u8) void {
    sendEvResponse(req, 200, "OK", "application/json", body);
}

fn sendEvError(req: ?*anyopaque, code: c_int, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "{{\"status\":\"error\",\"msg\":\"{s}\"}}", .{msg}) catch "{\"status\":\"error\"}";
    sendEvResponse(req, code, "Error", "application/json", resp);
}

fn sendEvCors(req: ?*anyopaque) void {
    const out_headers = c.evhttp_request_get_output_headers(req);
    _ = c.evhttp_add_header(out_headers, "Access-Control-Allow-Origin", "*");
    _ = c.evhttp_add_header(out_headers, "Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    _ = c.evhttp_add_header(out_headers, "Access-Control-Allow-Headers", "Content-Type");
    const out_buf = c.evhttp_request_get_output_buffer(req);
    c.evhttp_send_reply(req, 204, "No Content", out_buf);
}

// ------------------------------------------------------------------
// Query 参数提取
// ------------------------------------------------------------------

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

// ------------------------------------------------------------------
// libevent C API 声明
// ------------------------------------------------------------------

const c = struct {
    pub extern "c" fn event_base_new() ?*anyopaque;
    pub extern "c" fn event_base_dispatch(base: ?*anyopaque) c_int;
    pub extern "c" fn event_base_free(base: ?*anyopaque) void;

    pub extern "c" fn evhttp_new(base: ?*anyopaque) ?*anyopaque;
    pub extern "c" fn evhttp_free(http: ?*anyopaque) void;
    pub extern "c" fn evhttp_bind_socket(http: ?*anyopaque, address: [*:0]const u8, port: u16) c_int;
    pub extern "c" fn evhttp_set_gencb(http: ?*anyopaque, cb: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;

    pub extern "c" fn evhttp_request_get_uri(req: ?*anyopaque) ?[*:0]const u8;
    pub extern "c" fn evhttp_request_get_command(req: ?*anyopaque) c_int;
    pub extern "c" fn evhttp_request_get_input_buffer(req: ?*anyopaque) ?*anyopaque;
    pub extern "c" fn evhttp_request_get_output_buffer(req: ?*anyopaque) ?*anyopaque;
    pub extern "c" fn evhttp_request_get_output_headers(req: ?*anyopaque) ?*anyopaque;

    pub extern "c" fn evhttp_send_reply(req: ?*anyopaque, code: c_int, reason: [*:0]const u8, databuf: ?*anyopaque) void;

    pub extern "c" fn evbuffer_add(buf: ?*anyopaque, data: *const anyopaque, datlen: usize) c_int;
    pub extern "c" fn evbuffer_get_length(buf: ?*anyopaque) usize;
    pub extern "c" fn evbuffer_pullup(buf: ?*anyopaque, n: isize) ?*anyopaque;

    pub extern "c" fn evhttp_add_header(headers: ?*anyopaque, key: [*:0]const u8, value: [*:0]const u8) c_int;

    const EVHTTP_REQ_GET: c_int = 1;
    const EVHTTP_REQ_POST: c_int = 2;
    const EVHTTP_REQ_OPTIONS: c_int = 32;
};

// ------------------------------------------------------------------
// 单元测试
// ------------------------------------------------------------------

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
