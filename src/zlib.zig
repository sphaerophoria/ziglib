const std = @import("std");
const Allocator = std.mem.Allocator;
const BitReader = std.io.BitReader;
const huffman = @import("huffman.zig");

const c = @cImport({
    @cInclude("zlib.h");
});

// NOTE: z_stream holds internal state that is a self referential pointer.
// Copying of z_stream is a big no no no no no no
fn initZStream(z_stream: *c.z_stream, input_data: []const u8, output_buf: []u8) !void {
    z_stream.zalloc = null;
    z_stream.zfree = null;
    z_stream.@"opaque" = null;

    z_stream.next_in = @ptrCast(@constCast(input_data.ptr));
    z_stream.avail_in = @intCast(input_data.len);

    z_stream.next_out = output_buf.ptr;
    z_stream.avail_out = @intCast(output_buf.len);
}

pub fn compressWithZlib(input_data: []const u8, output_buf: []u8) !usize {
    var z_stream: c.z_stream = undefined;
    try initZStream(&z_stream, input_data, output_buf);

    if (c.deflateInit(&z_stream, c.Z_DEFAULT_COMPRESSION) != c.Z_OK) {
        return error.ZlibInit;
    }

    defer {
        var ret = c.deflateEnd(&z_stream);
        if (ret != c.Z_OK) {
            std.log.err("failed to end deflate: {}", .{ret});
        }
    }

    var ret = c.deflate(&z_stream, c.Z_FINISH);

    if (ret != c.Z_STREAM_END) {
        std.log.err("input data could not be compressed into a small enough block", .{});
        return error.ZlibCompress;
    }

    std.debug.assert(z_stream.total_in == input_data.len); // All data should be consumed

    return z_stream.total_out;
}

pub fn decompressWithZlib(input_data: []const u8, output_buf: []u8) !usize {
    var z_stream: c.z_stream = undefined;
    try initZStream(&z_stream, input_data, output_buf);

    if (c.inflateInit(&z_stream) != c.Z_OK) {
        return error.ZlibInit;
    }

    defer {
        var ret = c.inflateEnd(&z_stream);
        if (ret != c.Z_OK) {
            std.log.err("failed to end deflate: {}", .{ret});
        }
    }

    var ret = c.inflate(&z_stream, c.Z_FINISH);

    if (ret != c.Z_STREAM_END) {
        std.log.err("input data could not be compressed into a small enough block", .{});
        return error.ZlibDecompress;
    }

    std.debug.assert(z_stream.total_in == input_data.len); // All data should be consumed

    return z_stream.total_out;
}

const Cmf = packed struct {
    cm: u4,
    cinfo: u4,
};

const Flg = packed struct {
    fcheck: u5,
    fdict: bool,
    flevel: u2,
};

const Header = packed struct {
    cmf: Cmf,
    flg: Flg,

    pub fn isValid(header: *const Header) bool {
        var header_u16: u16 = @as(u16, @as(u8, @bitCast(header.cmf))) * 256 + @as(u8, @bitCast(header.flg));
        return header_u16 % 31 == 0;
    }
};

// FIXME: This is valid for the length table as well
const DistanceTableItem = struct {
    extra_bits: u64,
    range_start: u64,
};

fn generateDistanceTable() [30]DistanceTableItem {
    comptime {
        var ret: [30]DistanceTableItem = undefined;
        // 4 elements with 0 extra bits, then pairs of 2
        var dist = 1;

        var i = 0;
        while (i < 4) {
            ret[i] = .{
                .extra_bits = 0,
                .range_start = dist,
            };
            dist += 1;
            i += 1;
        }

        while (i < 30) {
            for (0..2) |_| {
                const extra_bits = (i - 2) / 2;
                ret[i] = .{
                    .extra_bits = extra_bits,
                    .range_start = dist,
                };

                dist += 1 << extra_bits;
                i += 1;
            }
        }
        return ret;
    }
}
const distance_table = generateDistanceTable();

fn distanceCode(distance: u16) !huffman.Code {
    for (distance_table, 0..) |distance_item, start_code| {
        if (distance < (distance_item.range_start + (@as(u64, 1) << @intCast(distance_item.extra_bits)))) {
            const extra_val = distance - distance_item.range_start;
            var val = huffman.bitReverse(start_code, 5);
            if (distance_item.extra_bits != 0) {
                val |= extra_val << 5;
            }

            return .{
                .val = val,
                .num_bits = 5 + distance_item.extra_bits,
            };
        }
    }

    return error.InvalidDistanceCode;
}

fn generateLengthTable() [29]DistanceTableItem {
    comptime {
        var ret: [29]DistanceTableItem = undefined;
        // 8 elements with 0 extra bits, then chunks of 4
        var dist = 3;

        var i = 0;
        while (i < 8) {
            ret[i] = .{
                .extra_bits = 0,
                .range_start = dist,
            };
            dist += 1;
            i += 1;
        }

        while (i < 29) {
            for (0..4) |_| {
                const extra_bits = (i - 4) / 4;
                ret[i] = .{
                    .extra_bits = extra_bits,
                    .range_start = dist,
                };

                dist += 1 << extra_bits;
                i += 1;
                if (i >= 29) {
                    break;
                }
            }
        }
        return ret;
    }
}
const length_table = generateLengthTable();

const LengthCode = struct {
    huffman_coded: u16,
    extra_val: huffman.Code,
};

fn lengthCode(length: u16) !LengthCode {
    for (length_table, 0..) |length_item, code_offset| {
        if (length < (length_item.range_start + (@as(u8, 1) << @intCast(length_item.extra_bits)))) {
            const offset = length - length_item.range_start;

            //var val: u64 = 0;
            //if (length_item.extra_bits > 0) {
            //    val = huffman.bitReverse(offset, length_item.extra_bits);
            //}
            return .{
                .huffman_coded = @intCast(257 + code_offset),
                .extra_val = .{
                    .val = offset,
                    .num_bits = length_item.extra_bits,
                },
            };
        }
    }

    return error.InvalidLength;
}

fn readZlibHeader(reader: anytype) !Header {
    var header: Header = undefined;
    _ = try reader.readAll(std.mem.asBytes(&header));

    return header;
}

pub fn generateZlibNoCompression(writer: anytype, data: []const u8) !usize {
    var counting_writer = std.io.countingWriter(writer);
    var header = Header{ .cmf = .{
        .cm = 8,
        .cinfo = 3,
    }, .flg = .{
        .fcheck = 0,
        .fdict = false,
        .flevel = 1,
    } };

    var header_u16: u16 = @as(u16, @as(u8, @bitCast(header.cmf))) * 256 + @as(u8, @bitCast(header.flg));

    header.flg.fcheck = @intCast((31 - header_u16 % 31) % 31);

    try counting_writer.writer().writeAll(std.mem.asBytes(&header));

    try counting_writer.writer().writeByte(0b001);
    var len_data = [_]u16{ @intCast(data.len), @truncate(~data.len) };
    for (&len_data) |*elem| {
        elem.* = std.mem.nativeToLittle(u16, elem.*);
    }
    try counting_writer.writer().writeAll(std.mem.sliceAsBytes(&len_data));
    try counting_writer.writer().writeAll(data);

    return counting_writer.bytes_written;
}

pub fn getFixedHuffmanBitLengths(alloc: Allocator) !std.ArrayList(u64) {
    var bit_lengths = std.ArrayList(u64).init(alloc);
    errdefer bit_lengths.deinit();

    try bit_lengths.resize(288);
    @memset(bit_lengths.items[0..144], 8);
    @memset(bit_lengths.items[144..256], 9);
    @memset(bit_lengths.items[256..280], 7);
    @memset(bit_lengths.items[280..288], 8);

    return bit_lengths;
}

pub fn generateZlibStaticHuffman(alloc: Allocator, writer: anytype, data: []const u8, lz77_length: u16, lz77_distance: u16) !usize {
    var bit_lengths = try getFixedHuffmanBitLengths(alloc);
    defer bit_lengths.deinit();

    var codebook = try huffman.generateCodebook(alloc, bit_lengths.items);
    defer codebook.deinit();

    var counting_writer = std.io.countingWriter(writer);
    var header = Header{ .cmf = .{
        .cm = 8,
        .cinfo = 3,
    }, .flg = .{
        .fcheck = 0,
        .fdict = false,
        .flevel = 1,
    } };

    var header_u16: u16 = @as(u16, @as(u8, @bitCast(header.cmf))) * 256 + @as(u8, @bitCast(header.flg));

    header.flg.fcheck = @intCast((31 - header_u16 % 31) % 31);

    try counting_writer.writer().writeAll(std.mem.asBytes(&header));

    var huffman_writer = huffman.huffmanWriter(counting_writer.writer(), codebook.items);
    try huffman_writer.writer.writeBits(@as(u8, 0b011), 3);
    try huffman_writer.write(u8, data);

    if (lz77_length > 0) {
        const length_code = try lengthCode(lz77_length);
        std.debug.print("length code: {any}\n", .{length_code});
        try huffman_writer.write(u16, &[_]u16{length_code.huffman_coded});
        try huffman_writer.writer.writeBits(length_code.extra_val.val, length_code.extra_val.num_bits);

        var distance_code = try distanceCode(lz77_distance);
        std.debug.print("distance code: {any}\n", .{distance_code});
        try huffman_writer.writer.writeBits(distance_code.val, distance_code.num_bits);
    }

    try huffman_writer.write(u16, &[_]u16{256});
    try huffman_writer.finish();

    return counting_writer.bytes_written;
}

fn ensureCapacity(ring_buffer: *std.RingBuffer, capacity: usize) void {
    // It's invalid to try to write too much
    std.debug.assert(capacity <= ring_buffer.data.len);

    const current_capacity = ring_buffer.data.len - ring_buffer.len();
    if (current_capacity >= capacity) {
        return;
    }

    ring_buffer.read_index = ring_buffer.mask2(ring_buffer.read_index + (capacity - current_capacity));
}

pub fn ZlibDecompressor(comptime Reader: type) type {
    return struct {
        reader: BitReader(.Little, Reader),
        fixedHuffmanTable: huffman.HuffmanTable(u16),
        previous_data: std.RingBuffer,
        alloc: Allocator,

        const Self = @This();

        pub fn init(alloc: Allocator, reader: anytype) !Self {
            const header = try readZlibHeader(reader);
            std.log.debug("zlib header: {any}", .{header});

            if (!header.isValid()) {
                return error.InvalidZlibHeader;
            }

            if (header.flg.fdict) {
                std.log.err("fdict is not yet supported", .{});
                return error.Unsupported;
            }

            var bit_lengths = try getFixedHuffmanBitLengths(alloc);
            defer bit_lengths.deinit();

            var table = try huffman.HuffmanTable(u16).initFromBitLengths(alloc, bit_lengths.items);
            return .{
                .reader = std.io.bitReader(.Little, reader),
                .fixedHuffmanTable = table,
                .previous_data = try std.RingBuffer.init(alloc, 32768),
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.fixedHuffmanTable.deinit();
            self.previous_data.deinit(self.alloc);
        }

        pub fn readBlock(self: *Self, output: []u8) !usize {
            var read_bits: usize = undefined;
            var block_header = try self.reader.readBits(u8, 3, &read_bits);
            const bfinal: u1 = @truncate(block_header);
            const btype: u2 = @truncate(block_header >> 1);

            std.debug.print("bfinal: 0b{b}, btype: 0b{b}\n", .{ bfinal, btype });
            switch (btype) {
                // FIXME: enum?
                0b00 => {
                    // FIXME: split function?
                    // no compression
                    var len: u16 = undefined;
                    var len_comp: u16 = undefined;
                    self.reader.alignToByte();

                    if (try self.reader.read(std.mem.asBytes(&len)) != 2) {
                        std.log.err("length field for no compression block not complete", .{});
                        return error.InvalidData;
                    }

                    if (try self.reader.read(std.mem.asBytes(&len_comp)) != 2) {
                        std.log.err("length compliment field for no compression block not complete", .{});
                        return error.InvalidData;
                    }

                    if (len != ~len_comp) {
                        std.log.err("length and length compliment fields did not match", .{});
                        return error.InvalidData;
                    }

                    if (len > output.len) {
                        return error.NotEnoughSpace;
                    }

                    _ = try self.reader.reader().readAll(output[0..len]);
                    ensureCapacity(&self.previous_data, len);
                    self.previous_data.writeSliceAssumeCapacity(output[0..len]);
                    return len;
                },
                0b01 => {
                    var reader = huffman.huffmanReader(&self.reader, &self.fixedHuffmanTable, std.math.maxInt(usize));
                    var output_idx: usize = 0;
                    while (try reader.next()) |val| {
                        if (val < 256) {
                            output[output_idx] = @intCast(val);
                            ensureCapacity(&self.previous_data, 1);
                            self.previous_data.writeAssumeCapacity(@intCast(val));
                            output_idx += 1;
                        } else if (val == 256) {
                            break;
                        } else {
                            const length_table_idx = val - 257;
                            if (length_table_idx >= length_table.len) {
                                std.log.err("Length code was too big", .{});
                                return error.InvalidData;
                            }
                            const length_code = length_table[length_table_idx];

                            var bits_consumed: usize = 0;
                            var extra_val = try self.reader.readBits(u16, length_code.extra_bits, &bits_consumed);

                            if (bits_consumed != length_code.extra_bits) {
                                std.log.err("Length code was not complete", .{});
                                return error.InvalidData;
                            }

                            var length = length_code.range_start + extra_val;

                            var distance_idx = try self.reader.readBits(u16, 5, &bits_consumed);
                            if (bits_consumed != 5) {
                                std.log.err("Distance code was not complete", .{});
                                return error.InvalidData;
                            }
                            distance_idx = huffman.bitReverse(distance_idx, 5);

                            if (distance_idx >= distance_table.len) {
                                std.log.err("Distance code was too big", .{});
                                return error.InvalidData;
                            }

                            var distance_code = distance_table[distance_idx];
                            extra_val = try self.reader.readBits(u16, length_code.extra_bits, &bits_consumed);

                            if (bits_consumed != length_code.extra_bits) {
                                std.log.err("Distance code was not complete", .{});
                                return error.InvalidData;
                            }

                            var distance = distance_code.range_start + extra_val;

                            std.debug.print("Found length: {} and distance: {}\n", .{ length, distance });
                            var copy_data = self.previous_data.sliceAt(self.previous_data.write_index - distance, @min(distance, length));

                            // slice[idx..][0..len]
                            var remaining_length = length;
                            while (remaining_length > 0) {
                                var copy_len = @min(remaining_length, copy_data.first.len);
                                @memcpy(output[output_idx .. output_idx + copy_len], copy_data.first[0..copy_len]);
                                remaining_length -= copy_len;
                                output_idx += copy_len;

                                copy_len = @min(remaining_length, copy_data.second.len);
                                @memcpy(output[output_idx .. output_idx + copy_len], copy_data.second[0..copy_len]);
                                remaining_length -= copy_len;
                                output_idx += copy_len;
                                // FIXME adjust previous view
                            }
                            std.debug.print("data to copy: {s}{s}\n", .{ copy_data.first, copy_data.second });
                        }
                    }
                    return output_idx;
                },
                0b10 => {
                    // dynamic huffman
                    std.log.err("Cannot decompress dynamic huffman deflate block", .{});
                    return error.NotImplemented;
                },
                0b11 => {
                    return error.NotImplemented;
                },
            }
        }
    };
}

pub fn zlibDecompressor(alloc: Allocator, reader: anytype) !ZlibDecompressor(@TypeOf(reader)) {
    return ZlibDecompressor(@TypeOf(reader)).init(alloc, reader);
}

test "zlib back and forth" {
    const test_string = "the quick brown fox jumped over the lazy dog";
    var compressed_buf = [_]u8{0} ** 256;
    var compressed_len = try compressWithZlib(test_string, &compressed_buf);

    var decompressed_buf = [_]u8{0} ** test_string.len;
    var decompressed_len = try decompressWithZlib(compressed_buf[0..compressed_len], &decompressed_buf);

    try std.testing.expectEqualStrings(test_string, decompressed_buf[0..decompressed_len]);
}

test "no compression block generation" {
    var alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const input = "hello world";
    const num_written = try generateZlibNoCompression(buf.writer(), input);
    try std.testing.expectEqual(num_written, buf.items.len);

    var decompressed: [input.len]u8 = undefined;
    // For the time being, we error out because we do not generate the adler32 segment
    _ = decompressWithZlib(buf.items, &decompressed) catch {};
    try std.testing.expectEqualStrings(input, &decompressed);
}

test "no compression block decompression" {
    var alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const input = "hello world";
    const num_written = try generateZlibNoCompression(buf.writer(), input);
    try std.testing.expectEqual(num_written, buf.items.len);

    var decompressed: [input.len]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(buf.items);
    var decompressor = try zlibDecompressor(alloc, buf_stream.reader());
    defer decompressor.deinit();

    var decompressed_len = try decompressor.readBlock(&decompressed);

    try std.testing.expectEqualStrings(input, decompressed[0..decompressed_len]);
}

test "static huffman block generation" {
    var alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const input = "hello world";
    const num_written = try generateZlibStaticHuffman(alloc, buf.writer(), input, 3, 2);
    try std.testing.expectEqual(num_written, buf.items.len);

    var decompressed: [input.len + 10:0]u8 = undefined;
    @memset(&decompressed, 0);
    // For the time being, we error out because we do not generate the adler32 segment
    _ = decompressWithZlib(buf.items, &decompressed) catch {};
    try std.testing.expectEqualStrings(input ++ "ldl", decompressed[0..std.mem.indexOfScalar(u8, &decompressed, 0).?]);
}

test "static huffman block decompression" {
    var alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    const input = "hello world";
    const num_written = try generateZlibStaticHuffman(alloc, buf.writer(), input, 0, 0);
    try std.testing.expectEqual(num_written, buf.items.len);

    var decompressed: [input.len]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(buf.items);
    var decompressor = try zlibDecompressor(alloc, buf_stream.reader());
    defer decompressor.deinit();

    var decompressed_len = try decompressor.readBlock(&decompressed);

    try std.testing.expectEqualStrings(input, decompressed[0..decompressed_len]);
}

test "distance code generation" {
    var code = try distanceCode(4);

    // Distance code 3, but bitreversed initial 5 bit value
    // 0b00011 -> 0b11000
    try std.testing.expectEqual(@as(u64, 0b11000), code.val);

    code = try distanceCode(760);

    // Bitreversed initial 5 bits
    // >>> f"{18:b}"
    // '10010'
    // >>> 0b01001
    // 9
    // The next N bits seem to be _not_ reversed
    // >>> 760 - 513
    // 247
    // >>> 247 << 5
    // 7904
    // Combine the two
    // >>> 7904 | 9
    // 7913
    try std.testing.expectEqual(@as(u64, 7913), code.val);
}

test "length code generation" {
    var code = try lengthCode(4);
    try std.testing.expectEqual(@as(u64, 258), code.huffman_coded);
    try std.testing.expectEqual(@as(u64, 0), code.extra_val.num_bits);

    code = try lengthCode(140);
    try std.testing.expectEqual(@as(u64, 281), code.huffman_coded);
    // 140 - 131 from length table in rfc
    try std.testing.expectEqual(@as(u64, 9), code.extra_val.val);
    try std.testing.expectEqual(@as(u64, 5), code.extra_val.num_bits);
}
