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

pub fn ZlibDecompressor(comptime Reader: type) type {
    return struct {
        reader: BitReader(.Little, Reader),

        const Self = @This();

        pub fn init(reader: anytype) !Self {
            const header = try readZlibHeader(reader);
            std.log.debug("zlib header: {any}", .{header});

            if (!header.isValid()) {
                return error.InvalidZlibHeader;
            }

            if (header.flg.fdict) {
                std.log.err("fdict is not yet supported", .{});
                return error.Unsupported;
            }

            return .{
                .reader = std.io.bitReader(.Little, reader),
            };
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
                    return len;
                },
                0b01 => {
                    // static huffman
                    std.log.err("Cannot decompress static huffman deflate block", .{});
                    return error.NotImplemented;
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

pub fn zlibDecompressor(reader: anytype) !ZlibDecompressor(@TypeOf(reader)) {
    return ZlibDecompressor(@TypeOf(reader)).init(reader);
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
    var decompressor = try zlibDecompressor(buf_stream.reader());
    var decompressed_len = try decompressor.readBlock(&decompressed);

    try std.testing.expectEqualStrings(input, decompressed[0..decompressed_len]);
}
