const std = @import("std");
const huffman = @import("huffman.zig");
const bit_writer = @import("bit_writer.zig");
const huffman_writer = @import("huffman_writer.zig");
const huffman_reader = @import("huffman_reader.zig");

pub fn compressString(alloc: std.mem.Allocator, input_data: []const u8, table: *const huffman.HuffmanTable) !std.ArrayList(u8) {
    var codebook: huffman.Codebook = undefined;
    try table.generateCodebook(alloc, &codebook);

    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();

    var writer = huffman_writer.huffmanWriter(buf.writer(), &codebook);
    try writer.write(input_data);
    try writer.finish();

    return buf;
}

fn decompress(alloc: std.mem.Allocator, data: []const u8, table: *const huffman.HuffmanTable, output_len: usize) !std.ArrayList(u8) {
    var buf_reader = std.io.fixedBufferStream(data);
    var reader = huffman_reader.huffmanReader(buf_reader.reader(), table, output_len);

    var ret = std.ArrayList(u8).init(alloc);
    errdefer ret.deinit();

    while (try reader.next()) |val| {
        try ret.append(val);
    }

    return ret;
}

fn calcCompressionRatio(input_len: usize, output_len: usize) f32 {
    return @as(f32, @floatFromInt(output_len)) / @as(f32, @floatFromInt(input_len));
}

// std formatters do not format the way I want them to
const HexSliceFormatter = struct {
    buf: []const u8,

    pub fn init(buf: []const u8) HexSliceFormatter {
        return .{
            .buf = buf,
        };
    }

    fn printByte(b: u8, writer: anytype) @TypeOf(writer).Error!void {
        _ = try writer.write("0x");
        try writer.print("{}", .{std.fmt.fmtSliceHexLower(&.{b})});
    }

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        if (self.buf.len == 0) {
            return;
        }

        try writer.writeByte('[');
        try printByte(self.buf[0], writer);

        for (1..self.buf.len) |i| {
            _ = try writer.write(", ");
            try printByte(self.buf[i], writer);
        }

        try writer.writeByte(']');
    }
};

const Args = struct {
    input_data: []const u8,

    fn parse() !Args {
        var args = std.process.args();
        var stderr = std.io.getStdErr().writer();

        const process_name = args.next() orelse "ziglib";
        var input_data_opt: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, "--input-data", arg)) {
                input_data_opt = args.next();
            } else if (std.mem.eql(u8, "--help", arg)) {
                help(process_name);
            } else {
                _ = stderr.print("Unexpected argument: {s}\n", .{arg}) catch {};
                help(process_name);
            }
        }

        var input_data = input_data_opt orelse {
            _ = try stderr.write("Input data not provded\n");
            help(process_name);
        };

        return Args{
            .input_data = input_data,
        };
    }

    fn help(process_name: []const u8) noreturn {
        var stderr = std.io.getStdErr().writer();
        _ = stderr.print(
            \\Usage: {s} --input-data [data]
            \\
            \\A program to replace zlib, written in zig
        , .{process_name}) catch {};
        std.process.exit(1);
    }
};

pub fn main() !void {
    var args = try Args.parse();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();

    var table = try huffman.HuffmanTable.init(alloc, args.input_data);
    defer table.deinit();

    var compressed = try compressString(alloc, args.input_data, &table);
    defer compressed.deinit();
    std.debug.print("compressed: {}\n", .{HexSliceFormatter.init(compressed.items)});

    const compression_ratio = calcCompressionRatio(args.input_data.len, compressed.items.len);
    std.debug.print("compression ratio: {d:.3}\n", .{compression_ratio});

    var decompressed = try decompress(alloc, compressed.items, &table, args.input_data.len);
    defer decompressed.deinit();

    std.debug.print("decompressed: {s}\n", .{decompressed.items});
}

test {
    @import("std").testing.refAllDecls(@This());
}
