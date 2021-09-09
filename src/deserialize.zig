const std = @import("std");
const serialize = @import("main.zig").serialize;
const expect = std.testing.expect;
const eql = std.mem.eql;
const readIntSliceBig = std.mem.readIntSliceBig;
const ArrayList = std.ArrayList;

const rlpByteListShortHeader = 128;
const rlpByteListLongHeader = 183;
const rlpListShortHeader = 192;
const rlpListLongHeader = 247;

// When reading the payload, leading zeros are removed, so there might be a
// difference in byte-size between the number of bytes and the target integer.
// If so, the bytes have to be extracted into a temporary value.
inline fn safeReadSliceIntBig(comptime T: type, payload: []const u8, out: *T) void {
    // compile time constat to activate the first branch. If
    // @sizeOf(T) > 1, then it is possible (and necessary) to
    // shift temp.
    const log2tgt1 = (@sizeOf(T) > 1);
    if (log2tgt1 and @sizeOf(T) > payload.len) {
        var temp: T = 0;
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            temp = @shlExact(temp, 8); // payload.len < @sizeOf(T), should not overflow
            temp |= @as(T, payload[i]);
        }
        out.* = temp;
    } else {
        out.* = readIntSliceBig(T, payload[0..]);
    }
}

// Returns the amount of data consumed from `serialized`.
pub fn deserialize(comptime T: type, serialized: []const u8, out: *T) !usize {
    const info = @typeInfo(T);
    return switch (info) {
        .Int => {
            if (serialized[0] < rlpByteListShortHeader) {
                out.* = serialized[0];
                return 1; // consumed the byte
            } else if (serialized[0] < rlpByteListLongHeader) {
                // Recover the payload size from the header.
                const size = @as(usize, serialized[0] - rlpByteListShortHeader);

                // Special case: empty value, return 0
                if (size == 0) {
                    return 1; // consumed the header
                }

                if (size > serialized.len + 1) {
                    return error.EOF;
                }
                safeReadSliceIntBig(T, serialized[1 .. 1 + size], out);
                return 1 + size;
            } else {
                const size_size = @as(usize, serialized[0] - rlpByteListLongHeader);
                const size = readIntSliceBig(usize, serialized[1 .. 1 + size_size]);
                safeReadSliceIntBig(T, serialized[1 + size_size ..], out);
                return 1 + size_size + size;
            }
        },
        .Struct => |struc| {
            if (serialized.len == 0) {
                return error.EOF;
            }
            // A structure is encoded as a list, not
            // a bitstring.
            if (serialized[0] < rlpListShortHeader) {
                return error.NotAnRLPList;
            }
            // TODO also handle bigger payloads
            const size = @as(usize, serialized[0] - rlpListShortHeader);
            var offset: usize = 1; // TODO + size_size
            inline for (struc.fields) |field| {
                offset += try deserialize(field.field_type, serialized[offset..], &@field(out.*, field.name));
            }

            return offset;
        },
        else => return error.UnsupportedType,
    };
}

test "deserialize an integer" {
    var consumed: usize = 0;

    const su8lo = [_]u8{42};
    var u8lo: u8 = undefined;
    consumed = try deserialize(u8, su8lo[0..], &u8lo);
    try expect(u8lo == 42);
    try expect(consumed == 1);

    const su8hi = [_]u8{ 129, 192 };
    var u8hi: u8 = undefined;
    consumed = try deserialize(u8, su8hi[0..], &u8hi);
    try expect(u8hi == 192);
    try expect(consumed == su8hi.len);

    const su16small = [_]u8{ 129, 192 };
    var u16small: u16 = undefined;
    consumed = try deserialize(u16, su16small[0..], &u16small);
    try expect(u16small == 192);
    try expect(consumed == su16small.len);

    const su16long = [_]u8{ 130, 192, 192 };
    var u16long: u16 = undefined;
    consumed = try deserialize(u16, su16long[0..], &u16long);
    try expect(u16long == 0xc0c0);
    try expect(consumed == su16long.len);
}

test "deserialize a structure" {
    const Person = struct {
        age: u8,
    };
    const jc = Person{ .age = 123 };
    var list = ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();
    try serialize(Person, jc, &list);
    var p: Person = undefined;
    const consumed = try deserialize(Person, list.items[0..], &p);
    try expect(consumed == list.items.len);
    try expect(p.age == jc.age);
}
