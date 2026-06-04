const std = @import("std");
const tsdb = @import("tsdb");
const server = @import("server");
const compaction = @import("compaction");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = arg_iter.next(); // skip executable name

    const command = arg_iter.next() orelse {
        try printUsage(io);
        return;
    };

    if (std.mem.eql(u8, command, "serve")) {
        const port = if (arg_iter.next()) |p| try std.fmt.parseInt(u16, p, 10) else 8080;
        try cmdServe(allocator, port);
    } else if (std.mem.eql(u8, command, "write")) {
        const line = arg_iter.next() orelse {
            std.log.err("Usage: tsdb write <line_protocol>");
            return error.MissingArgument;
        };
        try cmdWrite(allocator, line);
    } else if (std.mem.eql(u8, command, "query")) {
        const series_id_str = arg_iter.next() orelse {
            std.log.err("Usage: tsdb query <series_id> <start> <end>");
            return error.MissingArgument;
        };
        const start_str = arg_iter.next() orelse {
            std.log.err("Usage: tsdb query <series_id> <start> <end>");
            return error.MissingArgument;
        };
        const end_str = arg_iter.next() orelse {
            std.log.err("Usage: tsdb query <series_id> <start> <end>");
            return error.MissingArgument;
        };
        const series_id = try std.fmt.parseInt(u64, series_id_str, 10);
        const start = try std.fmt.parseInt(i64, start_str, 10);
        const end = try std.fmt.parseInt(i64, end_str, 10);
        try cmdQuery(allocator, series_id, start, end);
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
        \\  tsdb serve [port]          Start HTTP server (default 8080)
        \\  tsdb write <line>          Write a line protocol point
        \\  tsdb query <sid> <s> <e>   Query range for series
        \\  tsdb compact               Run compaction on data dir
        \\  tsdb flush                 Flush hot partition to disk
        \\
    ;
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, usage);
}

fn cmdServe(allocator: std.mem.Allocator, port: u16) !void {
    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    var srv = server.Server.init(allocator, &engine, port);
    try srv.start();
}

fn cmdWrite(allocator: std.mem.Allocator, line: []const u8) !void {
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
        std.log.info("Written: {s} = {d} @ {d}", .{ p.key.metric, p.point.value, p.point.timestamp });
    } else {
        std.log.err("Failed to parse line protocol", .{});
    }
}

fn cmdQuery(allocator: std.mem.Allocator, series_id: u64, start: i64, end: i64) !void {
    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    const points = try engine.queryRange(series_id, start, end, allocator);
    defer allocator.free(points);

    std.log.info("Query returned {d} points:", .{points.len});
    for (points) |p| {
        std.log.info("  timestamp={d} value={d}", .{ p.timestamp, p.value });
    }
}

fn cmdCompact(allocator: std.mem.Allocator) !void {
    std.log.info("Compaction stub: would compact partitions in data/", .{});
    _ = allocator;
    // 实际实现：加载多个小分区，合并，去重，写回磁盘
}

fn cmdFlush(allocator: std.mem.Allocator) !void {
    var engine = try tsdb.Engine.init(allocator, "data");
    defer engine.deinit();

    try engine.flushHotPartition();
    std.log.info("Hot partition flushed.", .{});
}
