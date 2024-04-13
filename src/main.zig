const std = @import("std");
const Allocator = std.mem.Allocator;
const huffman = @import("huffman.zig");
const z = @import("zlib.zig");

pub fn huffmanCompress(alloc: std.mem.Allocator, input_data: []const u8, bit_lengths: []const u64) !std.ArrayList(u8) {
    var codebook = try huffman.generateCodebook(alloc, bit_lengths);
    defer codebook.deinit();

    var buf = std.ArrayList(u8).init(alloc);
    errdefer buf.deinit();

    var writer = huffman.huffmanWriter(buf.writer(), codebook.items);
    try writer.write(u8, input_data);
    try writer.finish();

    return buf;
}

fn huffmanDecompress(alloc: std.mem.Allocator, data: []const u8, table: *const huffman.HuffmanTable(u8), output_len: usize) !std.ArrayList(u8) {
    var buf_reader = std.io.fixedBufferStream(data);
    var bit_reader = std.io.bitReader(.Little, buf_reader.reader());
    var reader = huffman.huffmanReader(bit_reader, table, output_len);

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

const ArgParseHelper = struct {
    process_name: []const u8,
    stderr: std.fs.File.Writer,
    args: std.process.ArgIterator,

    const Self = @This();

    fn init() ArgParseHelper {
        var stderr = std.io.getStdErr().writer();
        var args = std.process.args();
        const process_name = args.next() orelse "ziglib";
        return .{
            .process_name = process_name,
            .args = std.process.args(),
            .stderr = stderr,
        };
    }

    fn next(self: *Self) ?[]const u8 {
        return self.args.next();
    }

    fn nextStr(self: *Self, val_name: []const u8) []const u8 {
        return self.args.next() orelse {
            self.stderr.print("{s} value not provided\n", .{val_name}) catch {};
            Args.help(self.process_name);
        };
    }

    fn nextInt(self: *Self, comptime T: type, val_name: []const u8) T {
        var val = self.nextStr(val_name);

        return std.fmt.parseInt(u16, val, 10) catch |e| {
            self.stderr.print("Failed to parse {s}: {any}\n", .{ val_name, e }) catch {};
            Args.help(self.process_name);
        };
    }
};

const Args = struct {
    input_data: []const u8,
    lz77_length: u16,
    lz77_distance: u16,

    fn parse() !Args {
        var args = ArgParseHelper.init();

        const process_name = args.next() orelse "ziglib";
        var input_data_opt: ?[]const u8 = null;
        var lz77_length: u16 = 0;
        var lz77_distance: u16 = 1;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, "--input-data", arg)) {
                input_data_opt = args.nextStr("--input-data");
            } else if (std.mem.eql(u8, "--lz77-length", arg)) {
                lz77_length = args.nextInt(u16, "--lz77-length");
            } else if (std.mem.eql(u8, "--lz77-distance", arg)) {
                lz77_distance = args.nextInt(u16, "--lz77-distance");
            } else if (std.mem.eql(u8, "--help", arg)) {
                help(process_name);
            } else {
                _ = args.stderr.print("Unexpected argument: {s}\n", .{arg}) catch {};
                help(process_name);
            }
        }

        var input_data = input_data_opt orelse {
            _ = try args.stderr.write("Input data not provded\n");
            help(process_name);
        };

        return Args{
            .input_data = input_data,
            .lz77_length = lz77_length,
            .lz77_distance = lz77_distance,
        };
    }

    fn help(process_name: []const u8) noreturn {
        var stderr = std.io.getStdErr().writer();
        _ = stderr.print(
            \\Usage: {s} [ARGS]
            \\
            \\Required Args:
            \\--input-data [data]: Data to compress
            \\
            \\Optional Args:
            \\--lz77-length [val]: When testing a compressed block, do we want to append a length/distance pair?
            \\--lz77-distance [val]: When testing a compressed block, do we want to append a length/distance pair?
            \\
            \\A program to replace zlib, written in zig
            \\
        , .{process_name}) catch {};
        std.process.exit(1);
    }
};

fn demoRealZlibCompression(args: *const Args) !void {
    var zlib_compression_buf: [4096]u8 = undefined;
    var compressed_size = try z.compressWithZlib(args.input_data, &zlib_compression_buf);
    std.debug.print("zlib compressed: {}\n", .{HexSliceFormatter.init(zlib_compression_buf[0..compressed_size])});

    var zlib_decompression_buf: [4096]u8 = undefined;
    var decompressed_size = try z.decompressWithZlib(zlib_compression_buf[0..compressed_size], &zlib_decompression_buf);
    std.debug.print("zlib decompressed: {s}\n", .{zlib_decompression_buf[0..decompressed_size]});
}

fn demoHuffmanCompression(alloc: Allocator, args: *const Args) !void {
    var bit_lengths = try huffman.freqsToBitDepths(alloc, &huffman.countCharFrequencies(args.input_data));
    defer bit_lengths.deinit();

    var table = try huffman.HuffmanTable(u8).initFromBitLengths(alloc, bit_lengths.items);
    defer table.deinit();

    var compressed = try huffmanCompress(alloc, args.input_data, bit_lengths.items);
    defer compressed.deinit();
    std.debug.print("compressed: {}\n", .{HexSliceFormatter.init(compressed.items)});

    const compression_ratio = calcCompressionRatio(args.input_data.len, compressed.items.len);
    std.debug.print("compression ratio: {d:.3}\n", .{compression_ratio});

    var decompressed = try huffmanDecompress(alloc, compressed.items, &table, args.input_data.len);
    defer decompressed.deinit();

    std.debug.print("decompressed: {s}\n", .{decompressed.items});
}

fn demoCustomDecompressorNoCompression(alloc: Allocator, input: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    var bytes_written = try z.generateZlibNoCompression(buf_stream.writer(), input);
    std.debug.print("custom generated no compression: {}\n", .{HexSliceFormatter{ .buf = buf[0..bytes_written] }});

    var output: [4096]u8 = undefined;
    buf_stream.reset();
    var decompressor = try z.zlibDecompressor(alloc, buf_stream.reader());
    defer decompressor.deinit();

    var read_bytes = try decompressor.readBlock(&output);
    std.debug.print("No compression block contained: {s}\n", .{output[0..read_bytes]});
}

fn demoCustomDecompressorFixedCompression(alloc: Allocator, input: []const u8, lz77_length: u16, lz77_distance: u16) !void {
    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    var bytes_written = try z.generateZlibStaticHuffman(alloc, buf_stream.writer(), input, lz77_length, lz77_distance);
    std.debug.print("custom generated static huffman: {}\n", .{HexSliceFormatter{ .buf = buf[0..bytes_written] }});

    var output = [1]u8{0} ** 4096;
    _ = z.decompressWithZlib(buf[0..bytes_written], &output) catch {};

    std.debug.print("real decompressor found: {s}\n", .{output});

    buf_stream.reset();
    var decompressor = try z.zlibDecompressor(alloc, buf_stream.reader());
    defer decompressor.deinit();

    var read_bytes = try decompressor.readBlock(&output);
    std.debug.print("custom decompressor found: {s}\n", .{output[0..read_bytes]});
}

fn demoCustomDecompressor(alloc: Allocator, input: []const u8, lz77_length: u16, lz77_distance: u16) !void {
    try demoCustomDecompressorNoCompression(alloc, input);
    try demoCustomDecompressorFixedCompression(alloc, input, lz77_length, lz77_distance);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() != .ok) {
            // For linting, if we have leaks we should indicate to our caller that we're broken
            std.process.exit(1);
        }
    }

    var alloc = gpa.allocator();

    var args = try Args.parse();
    std.debug.print("Input data: {s}\n", .{args.input_data});
    std.debug.print("Lz77 length: {d}\n", .{args.lz77_length});
    std.debug.print("Lz77 distance: {d}\n", .{args.lz77_distance});

    std.debug.print("\n#### Huffman ####\n", .{});
    try demoHuffmanCompression(alloc, &args);
    std.debug.print("\n#### Zlib ####\n", .{});
    try demoRealZlibCompression(&args);
    std.debug.print("\n#### Custom zlib decompressor ####\n", .{});
    try demoCustomDecompressor(alloc, args.input_data, args.lz77_length, args.lz77_distance);
}

test {
    @import("std").testing.refAllDecls(@This());
}
