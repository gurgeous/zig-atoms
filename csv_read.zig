/// CSV loader. Supports delimiters, quoted fields, and the various newline
/// characters.

// Parse CSV from a reader and return owned table data.
pub fn read(alloc: std.mem.Allocator, reader: anytype, delimiter: u8) !CsvData {
    var csv_reader = CsvReader.init(alloc, delimiter);
    defer csv_reader.deinit();
    return csv_reader.read(reader);
}

// Parse `bytes` as CSV input and return owned table data. See sniffDelimiter
// if you want to detect the correct delimiter.
pub fn readBuf(alloc: std.mem.Allocator, bytes: []const u8, delimiter: u8) !CsvData {
    var stream = std.io.fixedBufferStream(bytes);
    return read(alloc, stream.reader(), delimiter);
}

const sniffDelims = [_]u8{ ',', '\t', ';', '|' };

// Guess a delimiter from the first 4 KiB of `bytes`. Using `strict` ignores
// delims that parse with blank or jagged rows.
pub fn sniffDelimiter(alloc: std.mem.Allocator, bytes: []const u8, strict: bool) !?u8 {
    const sample = bytes[0..@min(bytes.len, 4 * 1024)];

    var best_delimiter: ?u8 = null;
    var best_ncols: usize = 0;
    for (sniffDelims) |d| {
        const data = readBuf(alloc, sample, d) catch continue;
        defer data.deinit(alloc);

        const ncols = scoreDelimiter(data, strict) orelse continue;
        if (ncols > best_ncols) {
            best_ncols = ncols;
            best_delimiter = d;
        }
    }

    return best_delimiter;
}

/// Owned CSV table data.
pub const CsvData = struct {
    rows: []Span, // each row is a span of fields
    fields: []CsvField, // each field is a slice from buf
    buf: []u8,

    // Free all data
    pub fn deinit(self: CsvData, alloc: std.mem.Allocator) void {
        alloc.free(self.rows);
        alloc.free(self.fields);
        alloc.free(self.buf);
    }

    // Return the borrowed fields for one row.
    pub fn row(self: CsvData, index: usize) CsvRow {
        const span = self.rows[index];
        return self.fields[span.start .. span.start + span.len];
    }

    // Return the number of parsed rows.
    pub fn rowCount(self: CsvData) usize {
        return self.rows.len;
    }
};

/// One borrowed CSV row.
pub const CsvRow = []const CsvField;
/// One CSV field (cell).
pub const CsvField = []const u8;

//
// internals
//

// One contiguous span within a backing slice.
const Span = struct { start: usize, len: usize };

// Stateful CSV parser over one buffered input.
const CsvReader = struct {
    alloc: std.mem.Allocator,
    delimiter: u8,
    rows: std.ArrayList(Span) = .empty,
    fields: std.ArrayList(Span) = .empty,
    buf: std.ArrayList(u8) = .empty,
    pending: ?u8 = null,

    const Self = @This();

    // Initialize a parser over one CSV reader.
    fn init(alloc: std.mem.Allocator, delimiter: u8) CsvReader {
        return .{ .alloc = alloc, .delimiter = delimiter };
    }

    // Release any parsed data still owned by the reader.
    fn deinit(self: *Self) void {
        self.rows.deinit(self.alloc);
        self.fields.deinit(self.alloc);
        self.buf.deinit(self.alloc);
    }

    // Parse the full input and transfer ownership into a CsvData value.
    fn read(self: *Self, in: anytype) !CsvData {
        // eof?
        while (try self.peekByte(in) != null) try self.parseRow(in);

        // rows => owned
        const rows = try self.rows.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(rows);

        // buf => owned
        const buf = try self.buf.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(buf);

        // fields => owned
        const fields = try self.alloc.alloc(CsvField, self.fields.items.len);
        errdefer self.alloc.free(fields);
        for (self.fields.items, 0..) |span, ii| {
            fields[ii] = buf[span.start .. span.start + span.len];
        }

        return .{ .rows = rows, .fields = fields, .buf = buf };
    }

    // Parse one row from the current reader position and append it.
    fn parseRow(self: *Self, in: anytype) !void {
        const row_start = self.fields.items.len;
        while (true) {
            const buf_start = self.buf.items.len;
            const done = try self.parseField(in);
            try self.fields.append(self.alloc, .{
                .start = buf_start,
                .len = self.buf.items.len - buf_start,
            });
            if (done) break;
        }
        try self.rows.append(self.alloc, .{
            .start = row_start,
            .len = self.fields.items.len - row_start,
        });
    }

    // Parse one field until the next delimiter, row end, or EOF.
    fn parseField(self: *Self, in: anytype) !bool {
        return if (try self.eatByte(in, '"')) self.quoted(in) else self.unquoted(in);
    }

    // Parse unquoted field
    fn unquoted(self: *Self, in: anytype) !bool {
        while (true) {
            const ch = try self.readByte(in) orelse return true;
            if (ch == '"') return error.InvalidQuote;
            if (ch == '\r' or ch == '\n') {
                if (ch == '\r') _ = try self.eatByte(in, '\n');
                return true;
            }
            if (ch == self.delimiter) return false;
            try self.buf.append(self.alloc, ch);
        }
    }

    // Parse quoted field
    fn quoted(self: *Self, in: anytype) !bool {
        while (true) {
            const ch = try self.readByte(in) orelse return error.UnexpectedEndOfFile;
            if (ch != '"') {
                try self.buf.append(self.alloc, ch);
                continue;
            }

            // We hit a quote.

            // `""` is an escaped quote
            if (try self.eatByte(in, '"')) {
                try self.buf.append(self.alloc, '"');
                continue;
            }

            // end of field - next byte must be delim or EOF
            const nxt = try self.readByte(in) orelse return true;
            if (nxt == '\r' or nxt == '\n') {
                if (nxt == '\r') _ = try self.eatByte(in, '\n');
                return true;
            }
            if (nxt == self.delimiter) return false;

            // nope
            return error.InvalidQuote;
        }
    }

    //
    // read/peek/eat
    //

    // Return the next byte without consuming it.
    fn peekByte(self: *Self, in: anytype) !?u8 {
        if (self.pending == null) {
            self.pending = in.readByte() catch |err| switch (err) {
                error.EndOfStream => null,
            };
        }
        return self.pending;
    }

    // Return the next byte from the reader, or null at EOF.
    fn readByte(self: *Self, in: anytype) !?u8 {
        if (self.pending) |byte| {
            self.pending = null;
            return byte;
        }
        return in.readByte() catch |err| switch (err) {
            error.EndOfStream => null,
        };
    }

    // If next byte == ch, eat it and return true
    fn eatByte(self: *Self, in: anytype, ch: u8) !bool {
        const nxt = try self.peekByte(in);
        if (nxt != ch) return false;
        self.pending = null;
        return true;
    }
};

//
// sniffing
//

// Return a column score for one parsed delimiter candidate.
fn scoreDelimiter(data: CsvData, strict: bool) ?usize {
    // can't score empty
    if (data.rows.len == 0) return null;

    var ncols = data.row(0).len;
    if (ncols < 2) return null; // can't score if no delims
    for (data.rows, 0..) |_, ii| {
        const row = data.row(ii);
        if (strict) {
            if (isBlankRow(row)) return null;
            if (row.len != ncols) return null;
        } else if (row.len > ncols) {
            // we have MORE of this delim in this row
            ncols = row.len;
        }
    }

    return ncols;
}

// Report whether a parsed row came from a blank input line.
fn isBlankRow(row: CsvRow) bool {
    return row.len == 1 and row[0].len == 0;
}

//
// testing
//

test "readBuf" {
    const data = try readBuf(test_alloc, "a,b\n\"x,y\",\"say \"\"hi\"\"\"\n", ',');
    defer data.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 2), data.rowCount());
    try testing.expectEqualStrings("a", data.row(0)[0]);
    try testing.expectEqualStrings("b", data.row(0)[1]);
    try testing.expectEqualStrings("x,y", data.row(1)[0]);
    try testing.expectEqualStrings("say \"hi\"", data.row(1)[1]);
}

test "read" {
    var stream = std.io.fixedBufferStream("a,b\nc,d\n");
    const data = try read(test_alloc, stream.reader(), ',');
    defer data.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 2), data.rowCount());
    try testing.expectEqualStrings("c", data.row(1)[0]);
    try testing.expectEqualStrings("d", data.row(1)[1]);
}

test "sniffDelimiter" {
    // strict=false
    try testing.expectEqual(@as(?u8, ','), try sniffDelimiter(test_alloc, "a,b,c\n1,2,3\n4,5,6\n", false));
    try testing.expectEqual(@as(?u8, ';'), try sniffDelimiter(test_alloc, "a;b;c\n1;2;3\n4;5;6\n", false));
    try testing.expectEqual(@as(?u8, '\t'), try sniffDelimiter(test_alloc, "a\tb\tc\n1\t2\t3\n4\t5\t6\n", false));
    try testing.expectEqual(@as(?u8, '|'), try sniffDelimiter(test_alloc, "a|b|c\n1|2|3\n4|5|6\n", false));
    // strict=false but still fails
    try testing.expectEqual(@as(?u8, null), try sniffDelimiter(test_alloc, "", false));
    try testing.expectEqual(@as(?u8, null), try sniffDelimiter(test_alloc, "hello\nworld\n", false));
    try testing.expectEqual(@as(?u8, null), try sniffDelimiter(test_alloc, "abcdef", false));
    // strict=false w/blanks or jagged
    try testing.expectEqual(@as(?u8, ','), try sniffDelimiter(test_alloc, "a,b\n\nc,d\n", false));
    try testing.expectEqual(@as(?u8, ','), try sniffDelimiter(test_alloc, "a,b\nc\n1,2,3\n", false));
    // strict=true
    try testing.expectEqual(@as(?u8, ';'), try sniffDelimiter(test_alloc, "a;b;c\n1;2;3\n4;5;6\n", true));
    try testing.expectEqual(@as(?u8, null), try sniffDelimiter(test_alloc, "a,b\n\nc,d\n", true));
    try testing.expectEqual(@as(?u8, null), try sniffDelimiter(test_alloc, "a,b\nc\n1,2,3\n", true));
}

test "empty input" {
    const data = try readBuf(test_alloc, "", ',');
    defer data.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 0), data.rowCount());
}

test "edge cases" {
    // blank lines
    const data1 = try readBuf(test_alloc, "a,b\n\nc,d\n", ',');
    defer data1.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 3), data1.rowCount());
    try testing.expectEqual(@as(usize, 1), data1.row(1).len);
    try testing.expectEqualStrings("", data1.row(1)[0]);
    try testing.expectEqualStrings("c", data1.row(2)[0]);
    try testing.expectEqualStrings("d", data1.row(2)[1]);

    // jagged
    const data2 = try readBuf(test_alloc, "a,b\nc\n1,2,3\n", ',');
    defer data2.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 3), data2.rowCount());
    try testing.expectEqual(@as(usize, 2), data2.row(0).len);
    try testing.expectEqual(@as(usize, 1), data2.row(1).len);
    try testing.expectEqual(@as(usize, 3), data2.row(2).len);

    // empty fields
    const data3 = try readBuf(test_alloc, "a,b,c\n1,,3\n", ',');
    defer data3.deinit(test_alloc);
    try testing.expectEqualStrings("1", data3.row(1)[0]);
    try testing.expectEqualStrings("", data3.row(1)[1]);
    try testing.expectEqualStrings("3", data3.row(1)[2]);

    // leading and trailing empty fields"
    const data4 = try readBuf(test_alloc, "a,b,c\n,2,3\n1,2,\n", ',');
    defer data4.deinit(test_alloc);
    try testing.expectEqualStrings("", data4.row(1)[0]);
    try testing.expectEqualStrings("2", data4.row(1)[1]);
    try testing.expectEqualStrings("3", data4.row(1)[2]);
    try testing.expectEqualStrings("1", data4.row(2)[0]);
    try testing.expectEqualStrings("2", data4.row(2)[1]);
    try testing.expectEqualStrings("", data4.row(2)[2]);
}

test "CR" {
    // crlf
    const data1 = try readBuf(test_alloc, "a,b\r\nc,d\r\n", ',');
    defer data1.deinit(test_alloc);
    try testing.expectEqualStrings("c", data1.row(1)[0]);
    try testing.expectEqualStrings("d", data1.row(1)[1]);

    // cr
    const data2 = try readBuf(test_alloc, "a,b\rc,d\r", ',');
    defer data2.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 2), data2.rowCount());
    try testing.expectEqualStrings("a", data2.row(0)[0]);
    try testing.expectEqualStrings("b", data2.row(0)[1]);
    try testing.expectEqualStrings("c", data2.row(1)[0]);
    try testing.expectEqualStrings("d", data2.row(1)[1]);
}

test "trailing newline" {
    // no trailing newline
    const data1 = try readBuf(test_alloc, "a,b\nc,d", ',');
    defer data1.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 2), data1.rowCount());
    try testing.expectEqualStrings("c", data1.row(1)[0]);
    try testing.expectEqualStrings("d", data1.row(1)[1]);

    // quoted without trailing newline
    const data2 = try readBuf(test_alloc, "a,b\n\"x,y\",z", ',');
    defer data2.deinit(test_alloc);
    try testing.expectEqual(@as(usize, 2), data2.rowCount());
    try testing.expectEqualStrings("x,y", data2.row(1)[0]);
    try testing.expectEqualStrings("z", data2.row(1)[1]);
}

test "embedded newlines" {
    // \n
    const data1 = try readBuf(test_alloc, "a,b\n\"x\ny\",z\n", ',');
    defer data1.deinit(test_alloc);
    try testing.expectEqualStrings("x\ny", data1.row(1)[0]);
    try testing.expectEqualStrings("z", data1.row(1)[1]);

    // \r\n
    const data2 = try readBuf(test_alloc, "a,b\r\n\"x\r\ny\",z\r\n", ',');
    defer data2.deinit(test_alloc);
    try testing.expectEqualStrings("x\r\ny", data2.row(1)[0]);
    try testing.expectEqualStrings("z", data2.row(1)[1]);
}

test "bad csv" {
    // malformed CSV
    try testing.expectError(error.UnexpectedEndOfFile, readBuf(test_alloc, "a,b\n\"oops\n", ','));
    // quoted fields must start at the beginning of the field
    try testing.expectError(error.InvalidQuote, readBuf(test_alloc, "a\tb\n  \"x\"\t  \"y\"\n", '\t'));
    // quoted fields may not have content after the closing quote
    try testing.expectError(error.InvalidQuote, readBuf(test_alloc, "\"hello\" world,x\n", ','));
}

const std = @import("std");
const testing = std.testing;
const test_alloc = testing.allocator;
