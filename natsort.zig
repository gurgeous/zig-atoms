/// Natural/human string ordering for things like `a2 < a10`.
///
/// Patterned after Martin Pool's natural sort algorithm.
/// https://github.com/sourcefrog/natsort

// Compare two strings using natural ordering.
pub fn natsort(a_in: []const u8, b_in: []const u8) std.math.Order {
    var a = a_in;
    var b = b_in;

    while (true) {
        a = std.mem.trimLeft(u8, a, &std.ascii.whitespace);
        b = std.mem.trimLeft(u8, b, &std.ascii.whitespace);

        if (a.len > 0 and b.len > 0 and isDigit(a[0]) and isDigit(b[0])) {
            // Leading-zero runs behave more like decimal fractions; other runs compare by magnitude.
            const ord = if (a[0] == '0' or b[0] == '0') compareLeft(a, b) else compareRight(a, b);
            if (ord != .eq) return ord;

            a = skipDigits(a);
            b = skipDigits(b);
            continue;
        }

        if (a.len == 0 and b.len == 0) return .eq;
        if (a.len == 0) return .lt;
        if (b.len == 0) return .gt;
        if (a[0] < b[0]) return .lt;
        if (a[0] > b[0]) return .gt;

        a = a[1..];
        b = b[1..];
    }
}

// Skip one contiguous digit run.
fn skipDigits(text: []const u8) []const u8 {
    var ii: usize = 0;
    while (ii < text.len and isDigit(text[ii])) : (ii += 1) {}
    return text[ii..];
}

// Compare digit runs left-aligned so leading zeros remain significant.
fn compareLeft(a_in: []const u8, b_in: []const u8) std.math.Order {
    var a = a_in;
    var b = b_in;

    while (true) {
        const a_digit = a.len > 0 and isDigit(a[0]);
        const b_digit = b.len > 0 and isDigit(b[0]);

        if (!a_digit and !b_digit) return .eq;
        if (!a_digit) return .lt;
        if (!b_digit) return .gt;
        if (a[0] < b[0]) return .lt;
        if (a[0] > b[0]) return .gt;

        a = a[1..];
        b = b[1..];
    }
}

// Compare digit runs by magnitude, falling back to first differing digit as bias.
fn compareRight(a_in: []const u8, b_in: []const u8) std.math.Order {
    var a = a_in;
    var b = b_in;
    var bias: std.math.Order = .eq;

    while (true) {
        const a_digit = a.len > 0 and isDigit(a[0]);
        const b_digit = b.len > 0 and isDigit(b[0]);

        if (!a_digit and !b_digit) return bias;
        if (!a_digit) return .lt;
        if (!b_digit) return .gt;
        if (bias == .eq) {
            if (a[0] < b[0]) bias = .lt;
            if (a[0] > b[0]) bias = .gt;
        }

        a = a[1..];
        b = b[1..];
    }
}

//
// testing
//

test "natsort" {
    const cases = [_]struct { exp: std.math.Order, a: []const u8, b: []const u8 }{
        // strings
        .{ .exp = .lt, .a = "a", .b = "b" },
        .{ .exp = .gt, .a = "b", .b = "a" },
        .{ .exp = .eq, .a = "abc", .b = "abc" },
        // empty strings
        .{ .exp = .eq, .a = "", .b = "" },
        .{ .exp = .lt, .a = "", .b = "a" },
        .{ .exp = .gt, .a = "a", .b = "" },
        // simple numeric runs
        .{ .exp = .lt, .a = "a2", .b = "a10" },
        .{ .exp = .lt, .a = "rfc1.txt", .b = "rfc822.txt" },
        .{ .exp = .lt, .a = "rfc822.txt", .b = "rfc2086.txt" },
        // pure numeric strings
        .{ .exp = .lt, .a = "9", .b = "10" },
        .{ .exp = .lt, .a = "2", .b = "100" },
        .{ .exp = .gt, .a = "100", .b = "2" },
        // one side has a digit, the other does not
        .{ .exp = .lt, .a = "2", .b = "a" },
        .{ .exp = .gt, .a = "a", .b = "2" },
        // multiple numeric runs
        .{ .exp = .lt, .a = "x2-g8", .b = "x2-y08" },
        .{ .exp = .lt, .a = "x2-y08", .b = "x2-y7" },
        .{ .exp = .lt, .a = "x2-y7", .b = "x8-y8" },
        // leading whitespace
        .{ .exp = .eq, .a = "  a2", .b = "a2" },
        .{ .exp = .lt, .a = "  a2", .b = "a10" },
        // whitespace is ignored at each comparison step, not just at the start
        .{ .exp = .eq, .a = "a b", .b = "ab" },
        .{ .exp = .lt, .a = "a 2", .b = "a10" },
        // leading zeros on one side still use left-aligned comparison
        .{ .exp = .lt, .a = "01", .b = "1" },
        // "-5" sorts before "-10".
        .{ .exp = .lt, .a = "-5", .b = "-10" },
    };
    for (cases) |tc| {
        try testing.expectEqual(tc.exp, natsort(tc.a, tc.b));
    }

    // fractional-looking strings with leading zeros
    const vals = [_][]const u8{ "1.001", "1.002", "1.010", "1.02", "1.1", "1.3" };
    for (vals[0 .. vals.len - 1], vals[1..]) |a, b| {
        try testing.expectEqual(std.math.Order.lt, natsort(a, b));
    }
}

const std = @import("std");
const testing = std.testing;
const isDigit = std.ascii.isDigit;
