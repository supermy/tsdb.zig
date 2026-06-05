const std = @import("std");
const tsdb = @import("tsdb");
const nng = @import("nng");
const http_server = @import("http_server");

/// NNG-based high-performance API server using req/rep pattern
/// Message format: JSON {"cmd":"write|query|stats", ...}
/// Response format: JSON {"status":"ok|error", ...}
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
        const srv_log = std.log.scoped(.server);

        // 启动 HTTP 测试页面服务线程（port + 1）
        const http_port = self.port + 1;
        const http_srv = http_server.HttpServer.init(self.allocator, self.engine, http_port);
        const http_thread = try std.Thread.spawn(.{}, httpServerThread, .{http_srv});
        http_thread.detach();

        // 启动 NNG 服务
        var sock: nng.nng_socket = undefined;
        try nng.check(nng.nng_rep0_open(&sock));
        defer _ = nng.nng_close(sock);

        var addr_buf: [64]u8 = undefined;
        const addr = try std.fmt.bufPrintZ(&addr_buf, "tcp://0.0.0.0:{d}", .{self.port});
        try nng.check(nng.nng_listen(sock, addr, null, 0));

        srv_log.info("NNG server listening on {s}", .{addr});
        srv_log.info("HTTP test console available at http://0.0.0.0:{d}", .{http_port});

        while (true) {
            self.runOnce(sock) catch |err| {
                srv_log.err("runOnce error: {}", .{err});
            };
        }
    }

    fn httpServerThread(http_srv: http_server.HttpServer) void {
        http_srv.start() catch |err| {
            std.log.scoped(.http).err("HTTP server error: {s}", .{@errorName(err)});
        };
    }

    /// Process a single request/response cycle using stack buffer
    pub fn runOnce(self: *Server, sock: nng.nng_socket) !void {
        const srv_log = std.log.scoped(.server);

        var buf: [16384]u8 = undefined;
        var recv_len: usize = buf.len;
        const recv_err = nng.nng_recv(sock, &buf, &recv_len, 0);
        if (recv_err != 0) {
            srv_log.err("recv failed: {d}", .{recv_err});
            return;
        }
        const request = buf[0..recv_len];
        srv_log.info("recv {d} bytes", .{recv_len});

        var resp_buf: [16384]u8 = undefined;
        const response = self.handleRequest(request, &resp_buf) catch |err| {
            const err_msg = try std.fmt.bufPrint(&resp_buf, "{{\"status\":\"error\",\"msg\":\"{}\"}}", .{err});
            _ = nng.nng_send(sock, err_msg.ptr, err_msg.len, 0);
            return;
        };

        const send_err = nng.nng_send(sock, response.ptr, response.len, 0);
        if (send_err != 0) {
            srv_log.err("send failed: {d}", .{send_err});
        }
    }

    fn handleRequest(self: *Server, request: []const u8, resp_buf: []u8) ![]const u8 {
        // Parse JSON command
        const cmd = parseJsonField(request, "cmd") orelse return error.MissingCommand;

        if (std.mem.eql(u8, cmd, "write")) {
            return try self.handleWriteCmd(request, resp_buf);
        } else if (std.mem.eql(u8, cmd, "query")) {
            return try self.handleQueryCmd(request, resp_buf);
        } else if (std.mem.eql(u8, cmd, "stats")) {
            return try self.handleStatsCmd(resp_buf);
        } else {
            return try std.fmt.bufPrint(resp_buf, "{{\"status\":\"error\",\"msg\":\"unknown cmd\"}}", .{});
        }
    }

    fn handleWriteCmd(self: *Server, request: []const u8, resp_buf: []u8) ![]const u8 {
        const data = parseJsonField(request, "data") orelse return error.MissingData;

        const parsed = try self.engine.parseLineProtocol(data);
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
            return try std.fmt.bufPrint(resp_buf, "{{\"status\":\"ok\",\"written\":1,\"series_id\":\"{d}\"}}", .{sid});
        }
        return try std.fmt.bufPrint(resp_buf, "{{\"status\":\"error\",\"msg\":\"parse failed\"}}", .{});
    }

    fn handleQueryCmd(self: *Server, request: []const u8, resp_buf: []u8) ![]const u8 {
        const sid = parseJsonFieldU64(request, "series_id") orelse 0;
        const raw_start = parseJsonFieldI64(request, "start") orelse 0;
        const raw_end = parseJsonFieldI64(request, "end") orelse std.math.maxInt(i64);

        // 若传入纳秒时间戳（>1e15）则转换为毫秒
        const q_start = if (raw_start > 1_000_000_000_000_000) @divFloor(raw_start, 1_000_000) else raw_start;
        const q_end = if (raw_end > 1_000_000_000_000_000) @divFloor(raw_end, 1_000_000) else raw_end;

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

        if (json.items.len > resp_buf.len) return error.ResponseTooLarge;
        @memcpy(resp_buf[0..json.items.len], json.items);
        return resp_buf[0..json.items.len];
    }

    fn handleStatsCmd(self: *Server, resp_buf: []u8) ![]const u8 {
        self.engine.lock.lock();
        defer self.engine.lock.unlock();

        return try std.fmt.bufPrint(resp_buf, "{{\"status\":\"ok\",\"hot_start\":{d},\"hot_end\":{d},\"readonly\":{d},\"disk\":{d}}}", .{
            self.engine.hot_partition.start_time,
            self.engine.hot_partition.end_time,
            self.engine.readonly_partitions.items.len,
            self.engine.disk_partitions.items.len,
        });
    }
};

fn parseJsonField(json: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, needle) orelse return null;
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfPos(u8, json, val_start, "\"") orelse return null;
    return json[val_start..val_end];
}

fn parseJsonFieldU64(json: []const u8, field: []const u8) ?u64 {
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
    return std.fmt.parseInt(u64, val_str, 10) catch null;
}

fn parseJsonFieldI64(json: []const u8, field: []const u8) ?i64 {
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
    return std.fmt.parseInt(i64, val_str, 10) catch null;
}

test "parseJsonField" {
    const json = "{\"cmd\":\"write\",\"data\":\"cpu,host=A usage=45i\"}";
    try std.testing.expectEqualStrings("write", parseJsonField(json, "cmd").?);
    try std.testing.expectEqualStrings("cpu,host=A usage=45i", parseJsonField(json, "data").?);
}

test "parseJsonFieldU64" {
    const json = "{\"cmd\":\"query\",\"series_id\":12345,\"start\":0,\"end\":9999}";
    try std.testing.expectEqual(@as(?u64, 12345), parseJsonFieldU64(json, "series_id"));
    try std.testing.expectEqual(@as(?u64, null), parseJsonFieldU64(json, "nonexistent"));
}

test "parseJsonFieldI64" {
    const json = "{\"cmd\":\"query\",\"series_id\":1,\"start\":-100,\"end\":9999}";
    try std.testing.expectEqual(@as(?i64, -100), parseJsonFieldI64(json, "start"));
    try std.testing.expectEqual(@as(?i64, 9999), parseJsonFieldI64(json, "end"));
    try std.testing.expectEqual(@as(?i64, null), parseJsonFieldI64(json, "nonexistent"));
}

test "parseJsonFieldU64 with string value" {
    // series_id may be returned as string "12345"
    const json = "{\"series_id\":\"12345\"}";
    try std.testing.expectEqual(@as(?u64, 12345), parseJsonFieldU64(json, "series_id"));
}

test "parseJsonField missing field returns null" {
    const json = "{\"cmd\":\"stats\"}";
    try std.testing.expectEqual(@as(?[]const u8, null), parseJsonField(json, "data"));
}

test "parseJsonFieldU64 empty json returns null" {
    try std.testing.expectEqual(@as(?u64, null), parseJsonFieldU64("{}", "series_id"));
}

test "parseJsonFieldI64 empty json returns null" {
    try std.testing.expectEqual(@as(?i64, null), parseJsonFieldI64("{}", "start"));
}
