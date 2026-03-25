///
/// Format specifiers:
///  `%b`  integer as lowercase binary
///  `%c`  integer as a single byte
///  `%d`  number as a signed decimal integer
///  `%f`  number as a decimal float
///  `%i`  number as a signed decimal integer
///  `%s`  byte slice string
///  `%t`  bool as `true` or `false`
///  `%x`  integer as lowercase hexadecimal
///  `%X`  integer as uppercase hexadecimal
///  `%%`  literal percent sign
///
/// Modifiers:
///  `+`      always show the sign: `%+d` -> `+2`
///  `0`      zero-pad on the left: `%05d` -> `00042`
///  `-`      left-align within the width: `%-5s` -> `hi   `
///  `<num>`  minimum field width: `%5s` -> `   hi`
///  `.<num>` float precision only: `%.2f` -> `3.14`
///
/// Examples:
///  `sprintf(alloc, "%08b", .{2})` -> `00000010`
///  `sprintf(alloc, "%+010d", .{-123})` -> `-000000123`
///  `sprintf(alloc, "%5s", .{"<"})` -> `    <`
///  `sprintf(alloc, "%0-5s", .{">"})` -> `>    `
///  `sprintf(alloc, "%.1f", .{2.345})` -> `2.3`
///  `sprintf(alloc, "%% %X %t", .{255, true})` -> `% FF true`
///
// Format a string using a small printf-style placeholder set.
pub fn sprintf(alloc: std.mem.Allocator, fmt: []const u8, args: anytype) ![]u8 {
    const args_info = @typeInfo(@TypeOf(args));
    if (args_info != .@"struct" or !args_info.@"struct".is_tuple) {
        @compileError("sprintf args must be a tuple");
    }

    var out: std.io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var arg_index: usize = 0;
    var ii: usize = 0;
    while (ii < fmt.len) {
        // Copy literal text until the next placeholder.
        const pct = std.mem.indexOfScalarPos(u8, fmt, ii, '%') orelse {
            try out.writer.writeAll(fmt[ii..]);
            break;
        };
        try out.writer.writeAll(fmt[ii..pct]);
        ii = pct + 1;

        // Handle %% directly and reject a dangling trailing %.
        if (ii == fmt.len) return error.InvalidFormat;
        if (fmt[ii] == '%') {
            try out.writer.writeByte('%');
            ii += 1;
            continue;
        }

        // Parse the placeholder, then render the next tuple argument.
        const parsed = try parsePlaceholder(fmt[ii..]);
        try appendArg(alloc, &out.writer, args, arg_index, parsed.placeholder);
        arg_index += 1;
        ii += parsed.len;
    }

    if (arg_index != args_info.@"struct".fields.len) return error.ExtraArgument;
    return out.toOwnedSlice();
}

// Parsed placeholder state for a single `%...` sequence.
const Placeholder = struct {
    sign: bool = false,
    pad_char: u8 = ' ',
    left_align: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
    kind: u8 = undefined,
};

// Parsed placeholder plus the number of bytes consumed.
const ParsedPlaceholder = struct {
    placeholder: Placeholder,
    len: usize,
};

// Rendered argument text plus sign metadata for padding logic.
const Rendered = struct {
    text: []u8,
    positive: bool = true,
    signed_numeric: bool = false,
};

// Parse one `%...` placeholder from the front of `text`.
fn parsePlaceholder(text: []const u8) !ParsedPlaceholder {
    var placeholder: Placeholder = .{};

    // Consume the small flag set supported by this port.
    var ii: usize = 0;
    while (ii < text.len) : (ii += 1) {
        switch (text[ii]) {
            '+' => placeholder.sign = true,
            '0' => {
                if (placeholder.width == null and placeholder.precision == null and !placeholder.left_align) {
                    placeholder.pad_char = '0';
                } else break;
            },
            '-' => {
                placeholder.left_align = true;
                placeholder.pad_char = ' ';
            },
            else => break,
        }
    }

    // Parse the optional width.
    const width_start = ii;
    while (ii < text.len and std.ascii.isDigit(text[ii])) : (ii += 1) {}
    if (ii > width_start) placeholder.width = try std.fmt.parseInt(usize, text[width_start..ii], 10);

    // Parse the optional precision.
    if (ii < text.len and text[ii] == '.') {
        ii += 1;
        const precision_start = ii;
        while (ii < text.len and std.ascii.isDigit(text[ii])) : (ii += 1) {}
        if (ii == precision_start) return error.InvalidFormat;
        placeholder.precision = try std.fmt.parseInt(usize, text[precision_start..ii], 10);
    }

    // The placeholder must end in a supported specifier byte.
    if (ii >= text.len) return error.InvalidFormat;
    placeholder.kind = switch (text[ii]) {
        'b', 'c', 'd', 'f', 'i', 's', 't', 'x', 'X' => text[ii],
        else => return error.InvalidFormat,
    };
    if (placeholder.precision != null and placeholder.kind != 'f') return error.InvalidFormat;
    return .{ .placeholder = placeholder, .len = ii + 1 };
}

// Append the tuple argument at `arg_index` using the parsed placeholder.
fn appendArg(
    alloc: std.mem.Allocator,
    writer: *std.io.Writer,
    args: anytype,
    arg_index: usize,
    placeholder: Placeholder,
) !void {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (fields, 0..) |field, ii| {
        if (arg_index == ii) {
            const rendered = try renderValue(alloc, @field(args, field.name), placeholder);
            defer alloc.free(rendered.text);
            return appendPadded(writer, rendered, placeholder);
        }
    }
    return error.MissingArgument;
}

// Render one argument into owned text according to its specifier.
fn renderValue(alloc: std.mem.Allocator, value: anytype, placeholder: Placeholder) !Rendered {
    return switch (placeholder.kind) {
        'b' => renderUnsigned(alloc, try toU32(value), "{b}"),
        'c' => renderByte(alloc, try toByte(value)),
        'd', 'i' => renderSigned(alloc, try toI64(value)),
        'f' => renderFloat(alloc, try toF64(value), placeholder.precision),
        's' => .{ .text = try renderString(alloc, value) },
        't' => .{ .text = try alloc.dupe(u8, if (try toBool(value)) "true" else "false") },
        'x' => renderUnsigned(alloc, try toU32(value), "{x}"),
        'X' => renderUnsigned(alloc, try toU32(value), "{X}"),
        else => error.InvalidFormat,
    };
}

// Apply sign handling and width padding around rendered text.
fn appendPadded(writer: *std.io.Writer, rendered: Rendered, placeholder: Placeholder) !void {
    var sign_slice: []const u8 = "";
    var body = rendered.text;
    if (rendered.signed_numeric and (!rendered.positive or placeholder.sign)) {
        sign_slice = if (rendered.positive) "+" else "-";
        if (body.len != 0 and (body[0] == '-' or body[0] == '+')) body = body[1..];
    }

    const total_len = sign_slice.len + body.len;
    const width = placeholder.width orelse 0;
    const pad_len = if (width > total_len) width - total_len else 0;

    // Left-aligned output pads on the right; zero padding stays between sign and body.
    if (placeholder.left_align) {
        try writer.writeAll(sign_slice);
        try writer.writeAll(body);
        for (0..pad_len) |_| try writer.writeByte(placeholder.pad_char);
        return;
    }
    if (placeholder.pad_char == '0') {
        try writer.writeAll(sign_slice);
        for (0..pad_len) |_| try writer.writeByte('0');
        try writer.writeAll(body);
        return;
    }

    for (0..pad_len) |_| try writer.writeByte(placeholder.pad_char);
    try writer.writeAll(sign_slice);
    try writer.writeAll(body);
}

// Allocate formatted output using Zig's standard writer formatting.
fn allocatePrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print(fmt, args);
    return out.toOwnedSlice();
}

//
// low-level renderXXX
//

// Render a single byte for `%c`.
fn renderByte(alloc: std.mem.Allocator, value: u8) !Rendered {
    return .{ .text = try alloc.dupe(u8, &[_]u8{value}) };
}

// Render a float in decimal notation with optional precision.
fn renderFloat(alloc: std.mem.Allocator, value: f64, precision: ?usize) !Rendered {
    return .{
        .text = if (precision) |p|
            try allocatePrint(alloc, "{d:.[1]}", .{ value, p })
        else
            try allocatePrint(alloc, "{d}", .{value}),
        .positive = !std.math.signbit(value),
        .signed_numeric = true,
    };
}

// Render a signed integer and preserve sign metadata for padding.
fn renderSigned(alloc: std.mem.Allocator, value: i64) !Rendered {
    return .{
        .text = try allocatePrint(alloc, "{}", .{value}),
        .positive = value >= 0,
        .signed_numeric = true,
    };
}

// Render an unsigned integer with the requested radix format string.
fn renderUnsigned(alloc: std.mem.Allocator, value: u32, comptime fmt: []const u8) !Rendered {
    return .{ .text = try allocatePrint(alloc, fmt, .{value}) };
}

// Duplicate a supported string argument into owned output.
fn renderString(alloc: std.mem.Allocator, value: anytype) ![]u8 {
    const slice = switch (@typeInfo(@TypeOf(value))) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) value else return error.ExpectedString,
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| if (arr.child == u8) value[0..] else return error.ExpectedString,
                else => return error.ExpectedString,
            },
            else => return error.ExpectedString,
        },
        else => return error.ExpectedString,
    };
    return alloc.dupe(u8, slice);
}

//
// conversions
//

// Convert a `bool` argument for `%t`.
fn toBool(value: anytype) !bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => value,
        else => error.ExpectedBool,
    };
}

// Convert a numeric argument to a single byte for `%c`.
fn toByte(value: anytype) !u8 {
    const widened = try toU32(value);
    if (widened > std.math.maxInt(u8)) return error.ExpectedNumber;
    return @intCast(widened);
}

// Convert a numeric argument to `f64`.
fn toF64(value: anytype) !f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .float, .comptime_float => value,
        .int, .comptime_int => @floatFromInt(value),
        else => error.ExpectedNumber,
    };
}

// Convert a numeric argument to signed integer form.
fn toI64(value: anytype) !i64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (value < std.math.minInt(i64) or value > std.math.maxInt(i64)) return error.ExpectedNumber;
            return value;
        },
        .int => {
            const info = @typeInfo(@TypeOf(value)).int;
            if (info.signedness == .signed) return @intCast(value);
            const widened: u128 = @intCast(value);
            if (widened > std.math.maxInt(i64)) return error.ExpectedNumber;
            return @intCast(widened);
        },
        .float, .comptime_float => {
            const float: f64 = value;
            const min_i64 = @as(f64, @floatFromInt(std.math.minInt(i64)));
            const max_i64 = @as(f64, @floatFromInt(std.math.maxInt(i64)));
            if (!std.math.isFinite(float)) return error.ExpectedNumber;
            if (float < min_i64 or float > max_i64) return error.ExpectedNumber;
            return @intFromFloat(float);
        },
        else => error.ExpectedNumber,
    };
}

// Convert a numeric argument to 32-bit unsigned form, preserving negative wrap.
fn toU32(value: anytype) !u32 {
    return switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (value < 0) {
                const widened: i128 = value;
                return @truncate(@as(u128, @bitCast(widened)));
            }
            const widened: u128 = value;
            if (widened > std.math.maxInt(u32)) return error.ExpectedNumber;
            return @truncate(widened);
        },
        .int => {
            const info = @typeInfo(@TypeOf(value)).int;
            if (info.signedness == .signed) {
                const widened: i128 = @intCast(value);
                return @truncate(@as(u128, @bitCast(widened)));
            }
            const widened: u128 = @intCast(value);
            if (widened > std.math.maxInt(u32)) return error.ExpectedNumber;
            return @truncate(widened);
        },
        .float, .comptime_float => {
            const float: f64 = value;
            const min_i64 = @as(f64, @floatFromInt(std.math.minInt(i64)));
            const max_u32 = @as(f64, @floatFromInt(std.math.maxInt(u32)));
            if (!std.math.isFinite(float)) return error.ExpectedNumber;
            if (float < min_i64 or float > max_u32) return error.ExpectedNumber;
            const signed: i64 = @intFromFloat(float);
            return @truncate(@as(u64, @bitCast(signed)));
        },
        else => error.ExpectedNumber,
    };
}

//
// testing
//

test "simple placeholders" {
    try expectSprintfCases(.{
        .{ .exp = "a%b", .fmt = "a%%b", .args = .{} },
        .{ .exp = "%", .fmt = "%%", .args = .{} },
        .{ .exp = "10", .fmt = "%b", .args = .{2} },
        .{ .exp = "A", .fmt = "%c", .args = .{65} },
        .{ .exp = "\x00", .fmt = "%c", .args = .{0} },
        .{ .exp = "\xFF", .fmt = "%c", .args = .{255} },
        .{ .exp = "2", .fmt = "%d", .args = .{2} },
        .{ .exp = "2", .fmt = "%i", .args = .{2} },
        .{ .exp = "2", .fmt = "%d", .args = .{2.9} },
        .{ .exp = "-2", .fmt = "%i", .args = .{-2.9} },
        .{ .exp = "2.2", .fmt = "%f", .args = .{2.2} },
        .{ .exp = "nan", .fmt = "%f", .args = .{std.math.nan(f64)} },
        .{ .exp = "inf", .fmt = "%f", .args = .{std.math.inf(f64)} },
        .{ .exp = "-inf", .fmt = "%f", .args = .{-std.math.inf(f64)} },
        .{ .exp = "%s", .fmt = "%s", .args = .{"%s"} },
        .{ .exp = "ff", .fmt = "%x", .args = .{255} },
        .{ .exp = "ffffff01", .fmt = "%x", .args = .{-255} },
        .{ .exp = "FF", .fmt = "%X", .args = .{255} },
        .{ .exp = "FFFFFF01", .fmt = "%X", .args = .{-255} },
        .{ .exp = "true", .fmt = "%t", .args = .{true} },
        .{ .exp = "false", .fmt = "%t", .args = .{false} },
        .{ .exp = "0", .fmt = "%.0f", .args = .{0.49} },
    });
}

test "complex placeholders" {
    try expectSprintfCases(.{
        .{ .exp = "+2", .fmt = "%+d", .args = .{2} },
        .{ .exp = "-2", .fmt = "%+d", .args = .{-2} },
        .{ .exp = "-2", .fmt = "%i", .args = .{-2} },
        .{ .exp = "+2", .fmt = "%+i", .args = .{2} },
        .{ .exp = "-2", .fmt = "%+i", .args = .{-2} },
        .{ .exp = "2.2", .fmt = "%f", .args = .{2.2} },
        .{ .exp = "-2.2", .fmt = "%f", .args = .{-2.2} },
        .{ .exp = "+2.2", .fmt = "%+f", .args = .{2.2} },
        .{ .exp = "-2.2", .fmt = "%+f", .args = .{-2.2} },
        .{ .exp = "+nan", .fmt = "%+f", .args = .{std.math.nan(f64)} },
        .{ .exp = "+inf", .fmt = "%+f", .args = .{std.math.inf(f64)} },
        .{ .exp = "-inf", .fmt = "%+f", .args = .{-std.math.inf(f64)} },
        .{ .exp = "-2.3", .fmt = "%+.1f", .args = .{-2.34} },
        .{ .exp = "-0.0", .fmt = "%+.1f", .args = .{-0.01} },
        .{ .exp = "+inf", .fmt = "%+.1f", .args = .{std.math.inf(f64)} },
        .{ .exp = "+nan", .fmt = "%+.1f", .args = .{std.math.nan(f64)} },
        .{ .exp = "-000000123", .fmt = "%+010d", .args = .{-123} },
        .{ .exp = "00000010", .fmt = "%08b", .args = .{2} },
        .{ .exp = "-0002", .fmt = "%05d", .args = .{-2} },
        .{ .exp = "-0002", .fmt = "%05i", .args = .{-2} },
        .{ .exp = "    <", .fmt = "%5s", .args = .{"<"} },
        .{ .exp = "     ", .fmt = "%5s", .args = .{""} },
        .{ .exp = "0000<", .fmt = "%05s", .args = .{"<"} },
        .{ .exp = ">    ", .fmt = "%-5s", .args = .{">"} },
        .{ .exp = ">    ", .fmt = "%0-5s", .args = .{">"} },
        .{ .exp = ">    ", .fmt = "%-05s", .args = .{">"} },
        .{ .exp = "xxxxxx", .fmt = "%5s", .args = .{"xxxxxx"} },
        .{ .exp = " -10.235", .fmt = "%8.3f", .args = .{-10.23456} },
        .{ .exp = "-12.34 xxx", .fmt = "%f %s", .args = .{ -12.34, "xxx" } },
        .{ .exp = "2.3", .fmt = "%.1f", .args = .{2.345} },
    });
}

test "extra arguments are rejected" {
    try expectSprintfError(error.ExtraArgument, "%d", .{ 1, 2, 3 });
}

test "errors" {
    // invalid format
    try expectSprintfErrorCases(.{
        .{ .exp = error.InvalidFormat, .fmt = "%", .args = .{} },
        .{ .exp = error.InvalidFormat, .fmt = "%.", .args = .{1} },
        .{ .exp = error.InvalidFormat, .fmt = "%.f", .args = .{1} },
        .{ .exp = error.InvalidFormat, .fmt = "%q", .args = .{1} },
        .{ .exp = error.InvalidFormat, .fmt = "%e", .args = .{1} },
        .{ .exp = error.InvalidFormat, .fmt = "%.3d", .args = .{1} },
        .{ .exp = error.InvalidFormat, .fmt = "%.3s", .args = .{"x"} },
        .{ .exp = error.InvalidFormat, .fmt = "%.3t", .args = .{true} },
    });

    // mismatched types
    try expectSprintfErrorCases(.{
        .{ .exp = error.ExpectedNumber, .fmt = "%d", .args = .{"42"} },
        .{ .exp = error.ExpectedNumber, .fmt = "%b", .args = .{"42"} },
        .{ .exp = error.ExpectedNumber, .fmt = "%d", .args = .{@as(u64, std.math.maxInt(u64))} },
        .{ .exp = error.ExpectedNumber, .fmt = "%d", .args = .{std.math.nan(f64)} },
        .{ .exp = error.ExpectedNumber, .fmt = "%i", .args = .{std.math.inf(f64)} },
        .{ .exp = error.ExpectedNumber, .fmt = "%b", .args = .{@as(u64, std.math.maxInt(u32) + 1)} },
        .{ .exp = error.ExpectedNumber, .fmt = "%x", .args = .{@as(u64, std.math.maxInt(u32) + 1)} },
        .{ .exp = error.ExpectedNumber, .fmt = "%X", .args = .{@as(u64, std.math.maxInt(u32) + 1)} },
        .{ .exp = error.ExpectedNumber, .fmt = "%c", .args = .{256} },
        .{ .exp = error.ExpectedNumber, .fmt = "%c", .args = .{-1} },
        .{ .exp = error.ExpectedBool, .fmt = "%t", .args = .{1} },
        .{ .exp = error.ExpectedString, .fmt = "%s", .args = .{1} },
    });

    // too few or too many args
    try expectSprintfError(error.MissingArgument, "%d %d", .{1});
    try expectSprintfError(error.ExtraArgument, "%d", .{ 1, 2, 3 });
}

// Assert one call to sprintf() matches the expected string.
fn expectSprintf(expected: []const u8, fmt: []const u8, args: anytype) !void {
    const actual = try sprintf(testing.allocator, fmt, args);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

// Assert one call to sprintf() fails with the expected error.
fn expectSprintfError(expected: anyerror, fmt: []const u8, args: anytype) !void {
    try testing.expectError(expected, sprintf(testing.allocator, fmt, args));
}

// Assert a batch of sprintf success cases.
fn expectSprintfCases(comptime cases: anytype) !void {
    inline for (cases) |case| {
        try expectSprintf(case.exp, case.fmt, case.args);
    }
}

// Assert a batch of sprintf failure cases.
fn expectSprintfErrorCases(comptime cases: anytype) !void {
    inline for (cases) |case| {
        try expectSprintfError(case.exp, case.fmt, case.args);
    }
}

const std = @import("std");
const testing = std.testing;
