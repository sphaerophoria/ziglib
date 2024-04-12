const z = @import("zlib.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;

const Code = struct {
    val: u64,
    num_bits: u64,

    fn reversed(self: *const Code) Code {
        return .{
            .val = @bitReverse(self.val) >> @intCast(@bitSizeOf(@TypeOf(self.val)) - self.num_bits),
            .num_bits = self.num_bits,
        };
    }
};

pub fn generateCodebook(alloc: std.mem.Allocator, bit_lengths: []const u64) !std.ArrayList(?Code) {
    var ret = std.ArrayList(?Code).init(alloc);
    errdefer ret.deinit();

    try ret.resize(bit_lengths.len);
    @memset(ret.items, null);

    var code_iter = try HuffmanCodeIter.init(alloc, bit_lengths);
    defer code_iter.deinit();

    while (code_iter.next()) |elem| {
        ret.items[elem.elem] = elem.code.reversed();
    }
    return ret;
}

pub fn HuffmanTable(comptime T: type) type {
    return struct {
        const Self = @This();
        const DataType = T;

        const ValsForBitWidth = struct {
            vals: std.ArrayList(T),
            bit_width: usize,
            offset: usize,

            pub fn lookup(self: *const ValsForBitWidth, code: usize) !?T {
                if (code < self.offset) {
                    return error.InvalidCode;
                }
                const idx = code - self.offset;
                if (self.vals.items.len <= idx) {
                    return null;
                }

                return self.vals.items[idx];
            }
        };

        const ValsByBitWidth = struct {
            items: std.ArrayList(ValsForBitWidth),
            min_bit_width: usize,

            pub fn lookup(self: *const ValsByBitWidth, code: usize, bit_width: usize) !?T {
                var table_idx = bit_width - self.min_bit_width;
                return self.items.items[table_idx].lookup(code);
            }
        };

        alloc: std.heap.ArenaAllocator,
        vals_by_bit_width: ValsByBitWidth,

        pub fn initFromBitLengths(child_alloc: Allocator, bit_lengths: []const u64) !Self {
            var arena = std.heap.ArenaAllocator.init(child_alloc);
            var alloc = arena.allocator();

            var vals_by_bit_width = std.ArrayList(ValsForBitWidth).init(alloc);

            var code_iter = try HuffmanCodeIter.init(alloc, bit_lengths);
            defer code_iter.deinit();

            const min_bit_width = code_iter.last_bit_length;

            while (code_iter.next()) |elem| {
                const vals_by_bit_width_idx = elem.code.num_bits - min_bit_width;
                if (vals_by_bit_width_idx >= vals_by_bit_width.items.len) {
                    try vals_by_bit_width.append(.{
                        .vals = std.ArrayList(T).init(alloc),
                        .bit_width = elem.code.num_bits,
                        .offset = elem.code.val,
                    });
                }

                var vals_for_bit_width = &vals_by_bit_width.items[vals_by_bit_width_idx];
                try vals_for_bit_width.vals.append(@intCast(elem.elem));
            }

            return .{
                .alloc = arena,
                .vals_by_bit_width = .{
                    .items = vals_by_bit_width,
                    .min_bit_width = min_bit_width,
                },
            };
        }

        pub fn deinit(self: Self) void {
            self.alloc.deinit();
        }
    };
}

pub const CharFrequencies = [256]u64;

pub fn countCharFrequencies(s: []const u8) CharFrequencies {
    var ret = std.mem.zeroes(CharFrequencies);
    for (s) |c| {
        ret[c] += 1;
    }

    return ret;
}

const HuffmanCodeIter = struct {
    const Output = struct {
        elem: usize,
        code: Code,
    };

    const ElemWithBitLength = struct {
        elem: usize,
        bit_length: u64,
    };

    elems: std.ArrayList(ElemWithBitLength),
    idx: usize,
    code: u64,
    last_bit_length: usize,

    fn init(alloc: Allocator, bit_lengths: []const u64) !HuffmanCodeIter {
        var elems = try std.ArrayList(ElemWithBitLength).initCapacity(alloc, bit_lengths.len);
        errdefer elems.deinit();

        const lessThan = struct {
            fn lessThan(context: void, lhs: ElemWithBitLength, rhs: ElemWithBitLength) bool {
                _ = context;
                if (lhs.bit_length == rhs.bit_length) {
                    return lhs.elem < rhs.elem;
                }

                return lhs.bit_length < rhs.bit_length;
            }
        }.lessThan;

        for (bit_lengths, 0..) |bit_length, i| {
            if (bit_length == 0) {
                continue;
            }
            try elems.append(.{
                .elem = i,
                .bit_length = bit_length,
            });
        }

        std.sort.block(ElemWithBitLength, elems.items, {}, lessThan);

        const last_bit_length = if (elems.items.len > 0) elems.items[0].bit_length else 0;

        return .{
            .elems = elems,
            .idx = 0,
            .code = 0,
            .last_bit_length = last_bit_length,
        };
    }

    fn deinit(self: *HuffmanCodeIter) void {
        self.elems.deinit();
    }

    fn next(self: *HuffmanCodeIter) ?Output {
        if (self.idx >= self.elems.items.len) {
            return null;
        }

        const elem = &self.elems.items[self.idx];
        const shift = elem.bit_length - self.last_bit_length;
        self.code <<= @intCast(shift);
        self.last_bit_length = elem.bit_length;

        const ret = .{
            .elem = elem.elem,
            .code = .{
                .val = self.code,
                .num_bits = elem.bit_length,
            },
        };

        self.idx += 1;
        self.code += 1;
        return ret;
    }
};

pub fn freqsToBitDepths(alloc: Allocator, freqs: []const usize) !std.ArrayList(u64) {

    // bit_depths uses the normal allocator, but everything else uses the arena
    var bit_depths = try std.ArrayList(u64).initCapacity(alloc, freqs.len);
    errdefer bit_depths.deinit();

    try bit_depths.resize(freqs.len);
    @memset(bit_depths.items, 0);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var arena_alloc = arena.allocator();

    const NodeGroup = struct {
        count: usize,
        vals: std.ArrayList(usize),

        const NodeGroup = @This();

        fn deinit(self: *NodeGroup) void {
            self.vals.deinit();
        }

        fn order(context: void, a: NodeGroup, b: NodeGroup) std.math.Order {
            _ = context;
            return std.math.order(a.count, b.count);
        }
    };

    const NodeQueue = std.PriorityQueue(NodeGroup, void, NodeGroup.order);
    var queue = NodeQueue.init(arena_alloc, {});
    defer queue.deinit();

    for (0..freqs.len) |i| {
        if (freqs[i] == 0) {
            continue;
        }

        var vals = std.ArrayList(usize).init(arena_alloc);
        try vals.append(i);
        try queue.add(NodeGroup{
            .count = freqs[i],
            .vals = vals,
        });
    }

    while (queue.count() > 1) {
        var left = queue.remove();
        var right = queue.remove();
        defer right.deinit();

        try left.vals.appendSlice(right.vals.items);
        left.count += right.count;
        for (left.vals.items) |item| {
            bit_depths.items[item] += 1;
        }

        try queue.add(left);
    }

    return bit_depths;
}

fn printCharFrequencies(freqs: *const CharFrequencies) void {
    std.debug.print("char frequencies...\n", .{});
    for (0..freqs.len) |i| {
        if (freqs[i] == 0) {
            continue;
        }
        std.debug.print("{d}: {d}\n", .{ i, freqs[i] });
    }
}

pub fn HuffmanWriter(comptime Writer: type) type {
    return struct {
        const Self = @This();
        const BitWriter = std.io.BitWriter(.Little, Writer);
        writer: BitWriter,
        codebook: []const ?Code,

        /// codebook needs to be valid for the lifetime of huffman writer
        pub fn init(writer: Writer, codebook: []const ?Code) Self {
            return .{
                .writer = std.io.bitWriter(.Little, writer),
                .codebook = codebook,
            };
        }

        pub fn write(self: *Self, comptime T: type, data: []const T) !void {
            for (data) |v| {
                const code_opt = &self.codebook[v];
                if (code_opt.* == null) {
                    continue;
                }
                const code = &code_opt.*.?;

                try self.writer.writeBits(code.*.val, @intCast(code.*.num_bits));
            }
        }

        pub fn finish(self: *Self) !void {
            try self.writer.flushBits();
        }
    };
}

pub fn huffmanWriter(writer: anytype, codebook: []const ?Code) HuffmanWriter(@TypeOf(writer)) {
    return HuffmanWriter(@TypeOf(writer)).init(writer, codebook);
}

pub fn HuffmanReader(comptime Output: type, comptime Reader: type) type {
    return struct {
        reader: Reader,
        table: *const HuffmanTable(Output),
        elems_read: usize,
        max_len: usize,

        const Self = @This();

        pub fn next(self: *Self) !?Output {
            if (self.elems_read >= self.max_len) {
                return null;
            }

            var bit_width: usize = self.table.vals_by_bit_width.min_bit_width;
            var num_bits: usize = 0;
            var reversed: usize = try self.reader.readBits(usize, bit_width, &num_bits);
            if (num_bits != bit_width) {
                std.log.err("Expected {} bits, but got {}", .{ bit_width, num_bits });
                return error.NotEnoughData;
            }

            // FIXME: dedup
            var code = @bitReverse(reversed) >> @intCast(@bitSizeOf(@TypeOf(reversed)) - bit_width);

            var ret = try self.table.vals_by_bit_width.lookup(code, bit_width);
            while (ret == null) {
                var next_bit = try self.reader.readBits(usize, 1, &num_bits);
                code = (code << 1) | next_bit;
                bit_width += 1;
                if (num_bits != 1) {
                    return error.NotEnoughData;
                }
                ret = try self.table.vals_by_bit_width.lookup(code, bit_width);
            }
            self.elems_read += 1;
            return ret;
        }
    };
}

fn HuffmanReaderFromArgs(comptime Reader: type, comptime Table: type) type {
    switch (@typeInfo(Table)) {
        .Pointer => |p| {
            if (HuffmanTable(p.child.DataType) != p.child) {
                @compileError("HuffmanReader requires a *const HuffmanTable, but got unexpected type");
            }
            return HuffmanReader(p.child.DataType, Reader);
        },
        else => {
            @compileError("HuffmanReader requires a *const HuffmanTable, but got non-pointer type");
        },
    }
}

pub fn huffmanReader(reader: anytype, table: anytype, max_len: usize) HuffmanReaderFromArgs(@TypeOf(reader), @TypeOf(table)) {
    return .{
        .reader = reader,
        .table = table,
        .elems_read = 0,
        .max_len = max_len,
    };
}

test "huffman back and forth" {
    var alloc = std.testing.allocator;
    const input = "this is a test string";

    var freqs = countCharFrequencies(input);
    var bit_depths = try freqsToBitDepths(alloc, &freqs);
    defer bit_depths.deinit();

    var table = try HuffmanTable(u8).initFromBitLengths(alloc, bit_depths.items);
    defer table.deinit();

    var codebook = try generateCodebook(alloc, bit_depths.items);
    defer codebook.deinit();

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var writer = huffmanWriter(buf.writer(), codebook.items);
    try writer.write(u8, input);
    try writer.finish();

    var buf_reader = std.io.fixedBufferStream(buf.items);
    var bit_reader = std.io.bitReader(.Little, buf_reader.reader());
    var reader = huffmanReader(bit_reader, &table, input.len);

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();

    while (try reader.next()) |val| {
        try output.append(@intCast(val));
    }

    try std.testing.expectEqualStrings(input, output.items);
}

test "init from bit lengths" {
    var alloc = std.testing.allocator;
    var bit_lengths = std.ArrayList(u64).init(alloc);
    defer bit_lengths.deinit();

    // From the zlib rfc, table used for static huffman blocks
    try bit_lengths.resize(288);
    @memset(bit_lengths.items[0..144], 8);
    @memset(bit_lengths.items[144..256], 9);
    @memset(bit_lengths.items[256..280], 7);
    @memset(bit_lengths.items[280..288], 8);

    var codebook = try generateCodebook(alloc, bit_lengths.items);
    defer codebook.deinit();

    var expected: usize = 0;
    var num_bits: usize = 7;

    const Range = struct { begin: usize, end: usize, num_bits: usize };

    const ranges = &[_]Range{
        .{ .begin = 256, .end = 280, .num_bits = 7 },
        .{ .begin = 0, .end = 144, .num_bits = 8 },
        .{ .begin = 280, .end = 288, .num_bits = 8 },
        .{ .begin = 144, .end = 256, .num_bits = 9 },
    };

    // A little complex of a test, but I think it's worth it
    for (ranges) |range| {
        if (range.num_bits > num_bits) {
            num_bits += 1;
            expected <<= 1;
        }
        for (codebook.items[range.begin..range.end]) |item_opt| {
            // The values in the RFC are read in the order of MSB to LSB. Values from
            // 256..280 should be in the range [0, 280]. Our values are serialized in
            // the order of LSB to MSB, so we have to reverse them
            var item = item_opt.?;
            var reversed = @bitReverse(item.val) >> @intCast(@bitSizeOf(@TypeOf(item.val)) - item.num_bits);
            try std.testing.expectEqual(reversed, expected);
            expected += 1;
        }
    }
}
