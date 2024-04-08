const std = @import("std");

const c = @cImport({
    @cInclude("zlib.h");
});

// NOTE: z_stream holds internal state that is a self referential pointer.
// Copying of z_stream is a big no no no no no no
pub fn initZStream(z_stream: *c.z_stream, input_data: []const u8, output_buf: []u8) !void {
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
