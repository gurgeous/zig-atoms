/// CSV writer. Escapes fields with double quotes.
/// Write a full CSV table to `out`.
pub fn write(out: *std.Io.Writer, rows: []const CsvRow, delimiter: u8) !void {
    for (rows) |row| {
        for (row, 0..) |field, ii| {
            if (ii != 0) try out.writeByte(delimiter);
            try writeField(out, field, delimiter);
        }
        try out.writeAll("\r\n");
    }
}

/// One borrowed CSV row.
pub const CsvRow = []const CsvField;
/// One CSV field (cell).
pub const CsvField = []const u8;

/// Write one CSV field, quoting only when required.
fn writeField(out: *std.Io.Writer, field: CsvField, delimiter: u8) !void {
    if (!needsQuoting(field, delimiter)) {
        try out.writeAll(field);
        return;
    }

    try out.writeByte('"');
    for (field) |ch| {
        if (ch == '"') try out.writeByte('"');
        try out.writeByte(ch);
    }
    try out.writeByte('"');
}

/// Report whether a field must be quoted for RFC 4180 output.
fn needsQuoting(field: CsvField, delimiter: u8) bool {
    for (field) |ch| {
        if (ch == delimiter or ch == '"' or ch == '\r' or ch == '\n') return true;
    }
    return false;
}

//
// testing
//

test "write" {
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    const rows: []const CsvRow = &.{&.{ "a", "b", "c" }};

    try write(&writer, rows, ',');
    try testing.expectEqualStrings("a,b,c\r\n", writer.buffered());
}

test "write quotes delimiter and quotes" {
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    const rows: []const CsvRow = &.{&.{ "x,y", "say \"hi\"" }};

    try write(&writer, rows, ',');
    try testing.expectEqualStrings("\"x,y\",\"say \"\"hi\"\"\"\r\n", writer.buffered());
}

test "write quotes newlines" {
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    const rows: []const CsvRow = &.{&.{ "a\r\nb", "x\ny", "m\rn" }};

    try write(&writer, rows, ',');
    try testing.expectEqualStrings("\"a\r\nb\",\"x\ny\",\"m\rn\"\r\n", writer.buffered());
}

test "write multiple rows" {
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    const rows: []const CsvRow = &.{
        &.{ "a", "b" },
        &.{ "", "2,3" },
    };

    try write(&writer, rows, ',');
    try testing.expectEqualStrings("a,b\r\n,\"2,3\"\r\n", writer.buffered());
}

test "round trip through csv_read" {
    var out: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    const rows: []const CsvRow = &.{
        &.{ "a", "b", "c" },
        &.{ "x,y", "say \"hi\"", "" },
        &.{ "line1\nline2", "cr\r", "tail" },
    };

    try write(&writer, rows, ',');

    const csv_read = @import("csv_read.zig");
    const data = try csv_read.readBuf(test_alloc, writer.buffered(), ',');
    defer data.deinit(test_alloc);

    try testing.expectEqual(@as(usize, 3), data.rowCount());
    try testing.expectEqualStrings("a", data.row(0)[0]);
    try testing.expectEqualStrings("b", data.row(0)[1]);
    try testing.expectEqualStrings("c", data.row(0)[2]);
    try testing.expectEqualStrings("x,y", data.row(1)[0]);
    try testing.expectEqualStrings("say \"hi\"", data.row(1)[1]);
    try testing.expectEqualStrings("", data.row(1)[2]);
    try testing.expectEqualStrings("line1\nline2", data.row(2)[0]);
    try testing.expectEqualStrings("cr\r", data.row(2)[1]);
    try testing.expectEqualStrings("tail", data.row(2)[2]);
}

const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
