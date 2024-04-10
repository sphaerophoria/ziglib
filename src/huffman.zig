const std = @import("std");

pub const Code = struct {
    // FIXME: Code might not fit in in u8
    val: u8,
    num_bits: u3,
};

pub const Node = union(enum) {
    Leaf: u8,
    Branch: struct {
        left: usize,
        right: usize,
    },

    pub fn format(value: Node, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        switch (value) {
            .Leaf => |v| try writer.print("Leaf {{ {} }}", .{v}),
            .Branch => |v| try writer.print("Branch {{ .left: {}, .right: {} }}", .{ v.left, v.right }),
        }
    }
};

pub const HuffmanTable = struct {
    const NodeArray = std.ArrayList(Node);
    nodes: NodeArray,
    num_elems: usize,

    pub fn init(alloc: std.mem.Allocator, s: []const u8) !HuffmanTable {
        const freqs = countCharFrequencies(s);
        var nodes = NodeArray.init(alloc);

        const NodeQueue = std.PriorityQueue(FreqCountedNode, void, freqCountedNodePriority);
        var queue = NodeQueue.init(alloc, {});
        defer queue.deinit();

        for (0..freqs.len) |i| {
            if (freqs[i] == 0) {
                continue;
            }
            try nodes.append(.{ .Leaf = @intCast(i) });
            try queue.add(FreqCountedNode{
                .count = freqs[i],
                .node = nodes.items.len - 1,
            });
        }

        while (queue.count() > 1) {
            var left = queue.remove();
            var right = queue.remove();

            var new_node_idx = nodes.items.len;
            try nodes.append(.{ .Branch = .{
                .left = left.node,
                .right = right.node,
            } });

            try queue.add(FreqCountedNode{
                .count = left.count + right.count,
                .node = new_node_idx,
            });
        }

        return .{
            .nodes = nodes,
            .num_elems = freqs.len,
        };
    }

    pub fn deinit(self: HuffmanTable) void {
        self.nodes.deinit();
    }

    pub fn rootNodeIdx(self: *const HuffmanTable) usize {
        return self.nodes.items.len - 1;
    }

    pub fn nodeFromCode(self: *const HuffmanTable, code: []const u8) Node {
        var node_idx = self.nodes.items.len - 1;
        for (code) |v| {
            var node = switch (self.nodes.items[node_idx]) {
                .Branch => |b| b,
                .Leaf => unreachable,
            };

            switch (v) {
                0 => node_idx = node.left,
                1 => node_idx = node.right,
                else => unreachable,
            }
        }

        return self.nodes.items[node_idx];
    }

    pub fn generateCodebook(self: *const HuffmanTable, alloc: std.mem.Allocator) !std.ArrayList(?Code) {
        var ret = std.ArrayList(?Code).init(alloc);
        errdefer ret.deinit();

        try ret.resize(self.num_elems);
        var codebook = ret.items;
        @memset(codebook, null);

        var path = std.ArrayList(u8).init(alloc);
        defer path.deinit();

        try path.append(0);

        while (path.items.len > 0) {
            var node = self.nodeFromCode(path.items);
            switch (node) {
                .Leaf => |leaf| {
                    codebook[leaf] = pathToBitRepresentation(path.items);
                },
                .Branch => {
                    try path.append(0);
                    continue;
                },
            }

            while (path.items.len > 0 and (path.items[path.items.len - 1] == 1)) {
                _ = path.pop();
            }

            if (path.items.len == 0) {
                break;
            }

            path.items[path.items.len - 1] = 1;
        }

        return ret;
    }
};

const FreqCountedNode = struct {
    count: u64,
    node: usize,
};

fn freqCountedNodePriority(context: void, a: FreqCountedNode, b: FreqCountedNode) std.math.Order {
    _ = context;
    return std.math.order(a.count, b.count);
}

const CharFrequencies = [255]u64;

fn countCharFrequencies(s: []const u8) CharFrequencies {
    var ret = std.mem.zeroes(CharFrequencies);
    for (s) |c| {
        ret[c] += 1;
    }

    return ret;
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

fn pathToBitRepresentation(path: []const u8) Code {
    var code: u8 = 0;
    for (0..path.len) |i| {
        const val = path[i];
        std.debug.assert(val < 2); // Path should only have 0 or 1
        code |= val << @intCast(i);
    }

    return .{
        .val = code,
        .num_bits = @intCast(path.len),
    };
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

        pub fn write(self: *Self, data: []const u8) !void {
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

pub fn HuffmanReader(comptime Reader: type) type {
    return struct {
        reader: Reader,
        current_byte: u8,
        // How many bits of the byte have we processed
        byte_progress: u8,
        table: *const HuffmanTable,
        bytes_read: usize,
        max_len: usize,

        const Self = @This();

        fn nextBit(self: *Self) !u1 {
            if (self.byte_progress >= 8) {
                self.current_byte = try self.reader.readByte();
                self.byte_progress = 0;
            }

            var ret: u1 = @truncate(self.current_byte >> @intCast(self.byte_progress));

            self.byte_progress += 1;
            return ret;
        }

        pub fn next(self: *Self) !?u8 {
            var node_idx = self.table.rootNodeIdx();

            if (self.bytes_read >= self.max_len) {
                return null;
            }

            while (true) {
                var branch = switch (self.table.nodes.items[node_idx]) {
                    .Leaf => |val| {
                        self.bytes_read += 1;
                        return val;
                    },
                    .Branch => |b| b,
                };

                const next_bit = try self.nextBit();
                node_idx = switch (next_bit) {
                    0 => branch.left,
                    1 => branch.right,
                };
            }
        }
    };
}

pub fn huffmanReader(reader: anytype, table: *const HuffmanTable, max_len: usize) HuffmanReader(@TypeOf(reader)) {
    return .{
        .reader = reader,
        .current_byte = 0,
        .byte_progress = 8,
        .table = table,
        .bytes_read = 0,
        .max_len = max_len,
    };
}

test "bit representation from path" {
    var path = &.{ 0, 1, 1, 0, 0, 1 };
    try std.testing.expect(std.meta.eql(pathToBitRepresentation(path), .{
        .val = 0b100110,
        .num_bits = 6,
    }));
}

test "huffman back and forth" {
    var alloc = std.testing.allocator;
    const input = "this is a test string";

    var table = try HuffmanTable.init(alloc, input);
    defer table.deinit();

    var codebook = try table.generateCodebook(alloc);
    defer codebook.deinit();

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var writer = huffmanWriter(buf.writer(), codebook.items);
    try writer.write(input);
    try writer.finish();

    var buf_reader = std.io.fixedBufferStream(buf.items);
    var reader = huffmanReader(buf_reader.reader(), &table, input.len);

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();

    while (try reader.next()) |val| {
        try output.append(val);
    }

    try std.testing.expectEqualStrings(input, output.items);
}
