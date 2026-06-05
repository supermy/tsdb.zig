const std = @import("std");
const tsdb = @import("tsdb");
const server = @import("server");
const compaction = @import("compaction");

var current_log_level: std.log.Level = .warn;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = customLogFn,
};

fn customLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) > @intFromEnum(current_log_level)) return;
    std.log.defaultLog(message_level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = arg_iter.next(); // skip executable name

    const command = arg_iter.next() orelse {
        try printUsage(io);
        return;
    };

    const log = std.log.scoped(.main);

    if (std.mem.eql(u8, command, "serve")) {
        var verbose = false;
        var port: u16 = 8080;
        while (arg_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                verbose = true;
            } else {
                port = std.fmt.parseInt(u16, arg, 10) catch {
                    log.err("Invalid port: {s}", .{arg});
                    return error.InvalidArgument;
                };
            }
        }
        try cmdServe(allocator, port, verbose);
    } else if (std.mem.eql(u8, command, "write")) {
        const line = arg_iter.next() orelse {
            log.err("Usage: tsdb write <line_protocol>", .{});
            return error.MissingArgument;
        };
        try cmdWrite(allocator, line);
    } else if (std.mem.eql(u8, command, "query")) {
        const series_id_str = arg_iter.next() orelse {
            log.err("Usage: tsdb query <series_id> <start> <end>", .{});
            return error.MissingArgument;
        };
        const start_str = arg_iter.next() orelse {
            log.err("Usage: tsdb query <series_id> <start> <end>", .{});
            return error.MissingArgument;
        };
        const end_str = arg_iter.next() orelse {
            log.err("Usage: tsdb query <series_id> <start> <end>", .{});
            return error.MissingArgument;
        };
        const series_id = try std.fmt.parseInt(u64, series_id_str, 10);
        const start = try std.fmt.parseInt(i64, start_str, 10);
        const end = try std.fmt.parseInt(i64, end_str, 10);
        try cmdQuery(allocator, series_id, start, end);
    } else if (std.mem.eql(u8, command, "nngwrite")) {
        const addr = arg_iter.next() orelse {
            log.err("Usage: tsdb nngwrite <addr> <line>", .{});
            return error.MissingArgument;
        };
        const line = arg_iter.next() orelse {
            log.err("Usage: tsdb nngwrite <addr> <line>", .{});
            return error.MissingArgument;
        };
        try cmdNngWrite(allocator, addr, line);
    } else if (std.mem.eql(u8, command, "nngquery")) {
        const addr = arg_iter.next() orelse {
            log.err("Usage: tsdb nngquery <addr> <sid> <start> <end>", .{});
            return error.MissingArgument;
        };
        const sid_str = arg_iter.next() orelse {
            log.err("Usage: tsdb nngquery <addr> <sid> <start> <end>", .{});
            return error.MissingArgument;
        };
        const start_str = arg_iter.next() orelse {
            log.err("Usage: tsdb nngquery <addr> <sid> <start> <end>", .{});
            return error.MissingArgument;
        };
        const end_str = arg_iter.next() orelse {
            log.err("Usage: tsdb nngquery <addr> <sid> <start> <end>", .{});
            return error.MissingArgument;
        };
        const sid = try std.fmt.parseInt(u64, sid_str, 10);
        const start = try std.fmt.parseInt(i64, start_str, 10);
        const end = try std.fmt.parseInt(i64, end_str, 10);
        try cmdNngQuery(allocator, addr, sid, start, end);
    } else if (std.mem.eql(u8, command, "nngstats")) {
        const addr = arg_iter.next() orelse {
            log.err("Usage: tsdb nngstats <addr>", .{});
            return error.MissingArgument;
        };
        try cmdNngStats(allocator, addr);
    } else if (std.mem.eql(u8, command, "compact")) {
        try cmdCompact(allocator);
    } else if (std.mem.eql(u8, command, "flush")) {
        try cmdFlush(allocator);
    } else {
        try printUsage(io);
    }
}

fn printUsage(io: std.Io) !void {
    const usage =
        \\tsdb.zig - Time Series Database Engine
        \\
        \\Usage:
        \\  tsdb serve [port] [-v|--verbose]  Start NNG server (default 8080)
        \\  tsdb write <line>              Write a line protocol point
        \\  tsdb query <sid> <s> <e>       Query range for series
        \\  tsdb nngwrite <addr> <line>    Write via NNG req/rep
        \\  tsdb nngquery <addr> <sid> <s> <e>  Query via NNG req/rep
        \\  tsdb nngstats <addr>           Stats via NNG req/rep
        \\  tsdb compact                   Run compaction on data dir
        \\  tsdb flush                     Flush hot partition to disk
        \\
    ;
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, usage);
}

fn cmdServe(allocator: std.mem.Allocator, port: u16, verbose: bool) !void {
    if (verbose) {
        current_log_level = .debug;
    }
    const log = std.log.scoped(.main);
    log.info("日志级别: {s} ({s})", .{ @tagName(current_log_level), if (verbose) "详细模式" else "静默模式" });

    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    var srv = server.Server.init(allocator, &engine, port);
    try srv.start();
}

fn cmdNngWrite(allocator: std.mem.Allocator, addr: []const u8, line: []const u8) !void {
    const nng = @import("nng");
    const log = std.log.scoped(.main);
    var sock: nng.nng_socket = undefined;
    try nng.check(nng.nng_req0_open(&sock));
    defer _ = nng.nng_close(sock);
    const addr_z = try allocator.dupeZ(u8, addr);
    defer allocator.free(addr_z);
    try nng.check(nng.nng_dial(sock, addr_z, null, 0));

    var req_buf: [4096]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"write\",\"data\":\"{s}\"}}", .{line});
    try nng.check(nng.nng_send(sock, req.ptr, req.len, 0));

    var resp_buf: [4096]u8 = undefined;
    var resp_len: usize = resp_buf.len;
    try nng.check(nng.nng_recv(sock, &resp_buf, &resp_len, 0));
    log.info("Response: {s}", .{resp_buf[0..resp_len]});
}

fn cmdNngQuery(allocator: std.mem.Allocator, addr: []const u8, sid: u64, start: i64, end: i64) !void {
    const nng = @import("nng");
    const log = std.log.scoped(.main);
    var sock: nng.nng_socket = undefined;
    try nng.check(nng.nng_req0_open(&sock));
    defer _ = nng.nng_close(sock);
    const addr_z = try allocator.dupeZ(u8, addr);
    defer allocator.free(addr_z);
    try nng.check(nng.nng_dial(sock, addr_z, null, 0));

    var req_buf: [4096]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"query\",\"series_id\":{d},\"start\":{d},\"end\":{d}}}", .{ sid, start, end });
    try nng.check(nng.nng_send(sock, req.ptr, req.len, 0));

    var resp_buf: [16384]u8 = undefined;
    var resp_len: usize = resp_buf.len;
    try nng.check(nng.nng_recv(sock, &resp_buf, &resp_len, 0));
    log.info("Response: {s}", .{resp_buf[0..resp_len]});
}

fn cmdNngStats(allocator: std.mem.Allocator, addr: []const u8) !void {
    const nng = @import("nng");
    const log = std.log.scoped(.main);
    var sock: nng.nng_socket = undefined;
    try nng.check(nng.nng_req0_open(&sock));
    defer _ = nng.nng_close(sock);
    const addr_z = try allocator.dupeZ(u8, addr);
    defer allocator.free(addr_z);
    try nng.check(nng.nng_dial(sock, addr_z, null, 0));

    const req = "{\"cmd\":\"stats\"}";
    try nng.check(nng.nng_send(sock, req.ptr, req.len, 0));

    var resp_buf: [4096]u8 = undefined;
    var resp_len: usize = resp_buf.len;
    try nng.check(nng.nng_recv(sock, &resp_buf, &resp_len, 0));
    log.info("Response: {s}", .{resp_buf[0..resp_len]});
}

fn cmdWrite(allocator: std.mem.Allocator, line: []const u8) !void {
    const log = std.log.scoped(.main);
    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    const parsed = try engine.parseLineProtocol(line);
    if (parsed) |p| {
        defer {
            allocator.free(p.key.metric);
            for (p.key.tags) |tag| {
                allocator.free(tag.key);
                allocator.free(tag.value);
            }
            allocator.free(p.key.tags);
        }
        try engine.write(p.key, p.point);
        log.info("Written: {s} = {d} @ {d}", .{ p.key.metric, p.point.value, p.point.timestamp });
    } else {
        log.err("Failed to parse line protocol", .{});
    }
}

fn cmdQuery(allocator: std.mem.Allocator, series_id: u64, start: i64, end: i64) !void {
    const log = std.log.scoped(.main);
    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    const points = try engine.queryRange(series_id, start, end, allocator);
    defer allocator.free(points);

    log.info("Query returned {d} points:", .{points.len});
    for (points) |p| {
        log.info("  timestamp={d} value={d}", .{ p.timestamp, p.value });
    }
}

fn cmdCompact(allocator: std.mem.Allocator) !void {
    const log = std.log.scoped(.main);
    log.info("Compaction stub: would compact partitions in data/", .{});
    _ = allocator;
    // 实际实现：加载多个小分区，合并，去重，写回磁盘
}

fn cmdFlush(allocator: std.mem.Allocator) !void {
    const log = std.log.scoped(.main);
    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    try engine.flushHotPartition();
    log.info("Hot partition flushed.", .{});
}
