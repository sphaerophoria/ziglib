const std = @import("std");
const Allocator = std.mem.Allocator;

const Code = struct {
    val: u64,
    num_bits: u64,
};

pub fn Node(comptime T: type) type {
    return union(enum) {
        Leaf: T,
        Branch: struct {
            left: usize,
            right: usize,
        },

        pub fn format(value: Node(T), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = options;
            _ = fmt;
            switch (value) {
                .Leaf => |v| try writer.print("Leaf {{ {} }}", .{v}),
                .Branch => |v| try writer.print("Branch {{ .left: {}, .right: {} }}", .{ v.left, v.right }),
            }
        }
    };
}

pub fn HuffmanTable(comptime T: type) type {
    return struct {
        const NodeArray = std.ArrayList(Node(T));
        const Self = @This();
        const DataType = T;

        nodes: NodeArray,
        num_elems: usize,

        pub fn init(alloc: std.mem.Allocator, freqs: []const u64) !Self {
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

        pub fn deinit(self: Self) void {
            self.nodes.deinit();
        }

        pub fn rootNodeIdx(self: *const Self) usize {
            return self.nodes.items.len - 1;
        }

        pub fn generateCodebook(self: *const Self, alloc: std.mem.Allocator) !std.ArrayList(?Code) {
            var ret = std.ArrayList(?Code).init(alloc);
            errdefer ret.deinit();

            try ret.resize(self.num_elems);
            var codebook = ret.items;
            @memset(codebook, null);

            var it = try HuffmanIt(T).init(alloc, self.nodes.items, self.rootNodeIdx());
            defer it.deinit();

            while (try it.next()) |val| {
                codebook[val.val] = pathToBitRepresentation(val.path);
            }

            return ret;
        }
    };
}

fn HuffmanIt(comptime T: type) type {
    return struct {
        const Output = struct {
            path: []const u8,
            val: T,
        };

        const Self = @This();

        path: std.ArrayList(u8),
        parents: std.ArrayList(*Node(T)),
        nodes: []Node(T),

        fn init(alloc: Allocator, nodes: []Node(T), root_idx: usize) !Self {
            var path = std.ArrayList(u8).init(alloc);
            var parents = std.ArrayList(*Node(T)).init(alloc);

            try parents.append(&nodes[root_idx]);

            return .{
                .path = path,
                .parents = parents,
                .nodes = nodes,
            };
        }

        fn deinit(self: *Self) void {
            self.path.deinit();
            self.parents.deinit();
        }

        fn currentNode(self: *Self) ?*Node(T) {
            if (self.parents.items.len == 0 or self.path.items.len == 0) {
                return null;
            }

            var last_parent = self.parents.items[self.parents.items.len - 1];
            var last_path = self.path.items[self.path.items.len - 1];
            var node_idx = switch (last_path) {
                0 => last_parent.Branch.left,
                1 => last_parent.Branch.right,
                else => unreachable,
            };
            var node = &self.nodes[node_idx];
            return node;
        }

        // Update internal state with one step along the graph
        fn step(self: *Self) !void {
            var node = self.currentNode() orelse {
                try self.path.append(0);
                return;
            };

            switch (node.*) {
                .Leaf => {},
                .Branch => {
                    try self.path.append(0);
                    try self.parents.append(node);
                    return;
                },
            }

            while (self.path.items.len > 0 and (self.path.items[self.path.items.len - 1] == 1)) {
                _ = self.path.pop();
                _ = self.parents.pop();
            }

            if (self.path.items.len == 0) {
                return;
            }

            self.path.items[self.path.items.len - 1] = 1;
        }

        // DFS, get the next leaf node
        fn next(self: *Self) !?Output {
            while (true) {
                try self.step();
                var node = self.currentNode() orelse {
                    return null;
                };

                switch (node.*) {
                    .Leaf => |leaf| {
                        return .{
                            .path = self.path.items,
                            .val = leaf,
                        };
                    },
                    .Branch => {},
                }
            }
        }
    };
}

const FreqCountedNode = struct {
    count: u64,
    node: usize,
};

fn freqCountedNodePriority(context: void, a: FreqCountedNode, b: FreqCountedNode) std.math.Order {
    _ = context;
    return std.math.order(a.count, b.count);
}

pub const CharFrequencies = [256]u64;

pub fn countCharFrequencies(s: []const u8) CharFrequencies {
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
    var code: u64 = 0;
    for (0..path.len) |i| {
        const val: u64 = @intCast(path[i]);
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
        bytes_read: usize,
        max_len: usize,

        const Self = @This();

        fn nextBit(self: *Self) !u1 {
            var num_bits: usize = 0;
            var ret = try self.reader.readBits(u1, 1, &num_bits);
            std.debug.assert(num_bits == 1);
            return ret;
        }

        pub fn next(self: *Self) !?Output {
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

// FIXME: Maybe try finding a way around this type rediculousness
// FIXME: Find way to error gracefully on invalid table input
pub fn huffmanReader(reader: anytype, table: anytype, max_len: usize) HuffmanReader(@TypeOf(table.*).DataType, @TypeOf(reader)) {
    return .{
        .reader = reader,
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

    var table = try HuffmanTable(u8).init(alloc, &countCharFrequencies(input));
    defer table.deinit();

    var codebook = try table.generateCodebook(alloc);
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
        try output.append(val);
    }

    try std.testing.expectEqualStrings(input, output.items);
}
