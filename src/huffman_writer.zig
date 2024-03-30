const std = @import("std");
const bit_writer = @import("bit_writer.zig");
const Codebook = @import("huffman.zig").Codebook;

pub fn HuffmanWriter(comptime Writer: type) type {
    return struct {
        const Self = @This();
        const BitWriter = bit_writer.BitWriter(Writer);
        writer: BitWriter,
        codebook: *const Codebook,

        /// codebook needs to be valid for the lifetime of huffman writer
        pub fn init(writer: Writer, codebook: *const Codebook) Self {
            return .{
                .writer = bit_writer.bitWriter(writer),
                .codebook = codebook,
            };
        }

        pub fn write(self: *Self, data: []const u8) !void {
            for (data) |v| {
                const code_opt = &self.codebook[v];
                if (code_opt.* == null) {
                    continue;
                }
                const code = &code_opt.*.?;

                try self.writer.write(code.*.val, code.*.num_bits);
            }
        }

        pub fn finish(self: *Self) !void {
            try self.writer.finish();
        }
    };
}

pub fn huffmanWriter(writer: anytype, codebook: *const Codebook) HuffmanWriter(@TypeOf(writer)) {
    return HuffmanWriter(@TypeOf(writer)).init(writer, codebook);
}
