const std = @import("std");

pub const Code = struct {
    // FIXME: Code might not fit in in u8
    val: u8,
    num_bits: u3,
};

pub const Codebook = [256]?Code;

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

    pub fn generateCodebook(self: *const HuffmanTable, alloc: std.mem.Allocator, codebook: *Codebook) !void {
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

test "bit representation from path" {
    var path = &.{ 0, 1, 1, 0, 0, 1 };
    try std.testing.expect(std.meta.eql(pathToBitRepresentation(path), .{
        .val = 0b100110,
        .num_bits = 6,
    }));
}
