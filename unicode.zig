///
/// Lightweight best-effort Unicode-width heuristics for display width and
/// truncation. This is intentionally not a full Unicode grapheme-width
/// implementation. It only tries to handle the common cases for CLI output.
///

// Return an approximate display width for a UTF-8 string.
pub fn displayWidth(s: []const u8) usize {
    // early exit
    if (isAscii(s)) return s.len;

    _ = std.unicode.Utf8View.init(s) catch return s.len;
    var iter: UnitIter = .{ .text = s };
    var width: usize = 0;
    while (iter.next()) |unit| width += unit.width;
    return width;
}

// Write text truncated to approximate display width using an ellipsis.
pub fn truncate(writer: *std.Io.Writer, text: []const u8, stop: usize) !void {
    // early exits
    if (stop == 0) return;

    // byte length is a safe lower bound on display width
    if (text.len <= stop) {
        try writer.writeAll(text);
        return;
    }

    // ascii/bytes is quick
    if (isAscii(text)) {
        try truncateBytes(writer, text, stop);
        return;
    }

    //
    // not ascii, this is more complicated
    //

    // valid utf8?
    _ = std.unicode.Utf8View.init(text) catch {
        try truncateBytes(writer, text, stop);
        return;
    };

    var iter: UnitIter = .{ .text = text };
    var used: usize = 0;
    while (iter.next()) |unit| {
        // are we about to finish?
        if (used + unit.width >= stop) {
            if (used + unit.width == stop and iter.next() == null) {
                try writer.writeAll(unit.bytes);
            } else {
                try writeSpaces(writer, stop - 1 - used);
                try writer.writeAll("…");
            }
            return;
        }

        try writer.writeAll(unit.bytes);
        used += unit.width;
    }
}

//
// UnitIter - Iterate in display units
//

// Iterator that groups UTF-8 input into approximate display units.
const UnitIter = struct {
    text: []const u8,
    ii: usize = 0,

    // Return the next display unit, or null at end of string.
    fn next(self: *UnitIter) ?Unit {
        const start = self.ii;
        const first = self.nextCodepoint() orelse return null;

        // Group one or two regional indicators into a single flag-width unit.
        if (isRegionalIndicator(first.cp)) {
            if (self.peekCodepoint()) |nxt| {
                if (isRegionalIndicator(nxt.cp)) _ = self.nextCodepoint();
            }
            return .{ .bytes = self.text[start..self.ii], .width = 2 };
        }

        // Group an emoji plus its modifiers and any ZWJ-linked emoji chain.
        if (isWideEmoji(first.cp)) {
            self.consumeTrailingZeroWidth();
            while (self.peekCodepoint()) |joiner| {
                if (joiner.cp != 0x200D) break;
                var probe = self.*;
                _ = probe.nextCodepoint() orelse unreachable;

                const next_emoji = probe.nextCodepoint() orelse break;
                if (!isWideEmoji(next_emoji.cp)) break;

                self.ii = probe.ii;
                self.consumeTrailingZeroWidth();
            }
            return .{ .bytes = self.text[start..self.ii], .width = 2 };
        }

        self.consumeTrailingZeroWidth();
        return .{ .bytes = self.text[start..self.ii], .width = singleWidth(first.cp) };
    }

    // Return the next codepoint without consuming it.
    fn peekCodepoint(self: *const UnitIter) ?Codepoint {
        var probe = self.*;
        return probe.nextCodepoint();
    }

    // Consume trailing zero-width modifiers after a base glyph.
    fn consumeTrailingZeroWidth(self: *UnitIter) void {
        while (self.peekCodepoint()) |cp| {
            if (!isModifier(cp.cp)) break;
            _ = self.nextCodepoint();
        }
    }

    // Return the next decoded codepoint and advance the iterator.
    fn nextCodepoint(self: *UnitIter) ?Codepoint {
        if (self.ii >= self.text.len) return null;

        const start = self.ii;
        const len = std.unicode.utf8ByteSequenceLength(self.text[self.ii]) catch unreachable;
        self.ii += len;
        const bytes = self.text[start..self.ii];

        return .{
            .bytes = bytes,
            .cp = std.unicode.utf8Decode(bytes) catch unreachable,
        };
    }
};

//
// helpers
//

// One approximate display unit plus its rendered width.
const Unit = struct { bytes: []const u8, width: usize };

// One decoded codepoint and its original byte slice.
const Codepoint = struct { bytes: []const u8, cp: u21 };

// Return the width of a single non-grouped codepoint.
fn singleWidth(cp: u21) usize {
    if (isZeroWidth(cp)) return 0;
    if (isEastAsianWide(cp)) return 2;
    return 1;
}

// Return true for common East Asian wide/full-width codepoint ranges.
fn isEastAsianWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2329 and cp <= 0x232A) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF01 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6);
}

// Return true for codepoints that modify the previous glyph without width.
fn isZeroWidth(cp: u21) bool {
    return cp == 0x200D or isModifier(cp);
}

// Return true for zero-width codepoints that trail a base glyph.
fn isModifier(cp: u21) bool {
    return isCombining(cp) or isVariationSelector(cp) or isSkinToneModifier(cp);
}

// Return true when the whole slice is ASCII.
fn isAscii(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isAscii(c)) return false;
    }
    return true;
}

// Return true for common combining-mark ranges.
// Reference: https://www.unicode.org/charts/PDF/U0300.pdf
fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

// Return true for Unicode variation selector codepoints.
// Reference: https://www.unicode.org/charts/PDF/UFE00.pdf
fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF);
}

// Return true for Fitzpatrick skin-tone modifier codepoints.
// Reference: https://unicode.org/reports/tr51/
fn isSkinToneModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

// Return true for regional-indicator letters used in flags.
// Reference: https://unicode.org/reports/tr51/
fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

// Return true for the common emoji/pictograph blocks we treat as wide.
// Reference: https://unicode.org/reports/tr51/
fn isWideEmoji(cp: u21) bool {
    return isLegacyWideEmoji(cp) or
        (cp >= 0x1F300 and cp <= 0x1FAFF);
}

// Return true for pre-1F300 emoji that terminals typically render as wide.
fn isLegacyWideEmoji(cp: u21) bool {
    return (cp >= 0x231A and cp <= 0x231B) or
        (cp >= 0x23E9 and cp <= 0x23EC) or
        cp == 0x23F0 or
        cp == 0x23F3 or
        (cp >= 0x25FD and cp <= 0x25FE) or
        (cp >= 0x2614 and cp <= 0x2615) or
        (cp >= 0x2648 and cp <= 0x2653) or
        cp == 0x267F or
        cp == 0x2693 or
        cp == 0x26A1 or
        (cp >= 0x26AA and cp <= 0x26AB) or
        (cp >= 0x26BD and cp <= 0x26BE) or
        (cp >= 0x26C4 and cp <= 0x26C5) or
        cp == 0x26CE or
        cp == 0x26D4 or
        cp == 0x26EA or
        (cp >= 0x26F2 and cp <= 0x26F3) or
        cp == 0x26F5 or
        cp == 0x26FA or
        cp == 0x26FD or
        cp == 0x2705 or
        (cp >= 0x270A and cp <= 0x270B) or
        cp == 0x2728 or
        cp == 0x274C or
        cp == 0x274E or
        (cp >= 0x2753 and cp <= 0x2755) or
        cp == 0x2757 or
        cp == 0x2764 or
        (cp >= 0x2795 and cp <= 0x2797) or
        cp == 0x27B0 or
        cp == 0x27BF;
}

// Fallback to byte-oriented truncation for invalid UTF-8 input.
fn truncateBytes(writer: *std.Io.Writer, text: []const u8, stop: usize) !void {
    try writer.writeAll(text[0 .. stop - 1]);
    try writer.writeAll("…");
}

// Write count ASCII spaces.
fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

//
// testing
//

test "displayWidth" {
    const cases = [_]struct { text: []const u8, exp: usize }{
        .{ .text = "", .exp = 0 },
        .{ .text = "abc", .exp = 3 },
        .{ .text = "éé", .exp = 2 },
        .{ .text = "—", .exp = 1 },
        .{ .text = "中文", .exp = 4 },
        .{ .text = "cafe\u{0301}", .exp = 4 },
        .{ .text = "ok ✅", .exp = 5 },
        .{ .text = "❤️", .exp = 2 },
        .{ .text = "👍🏽", .exp = 2 },
        .{ .text = "🇺", .exp = 2 },
        .{ .text = "go 🇺🇸", .exp = 5 },
        .{ .text = "🇺🇸🇨", .exp = 4 },
        .{ .text = "family 👨‍👩‍👧‍👦", .exp = 9 },
        .{ .text = &[_]u8{ 0xff, 0x61 }, .exp = 2 },
    };

    for (cases) |tc| {
        try testing.expectEqual(tc.exp, displayWidth(tc.text));
    }
}

test "truncate" {
    const cases = [_]struct { text: []const u8, stop: usize, exp: []const u8 }{
        .{ .text = "", .stop = 0, .exp = "" },
        .{ .text = "", .stop = 1, .exp = "" },
        .{ .text = "this is too long", .stop = 8, .exp = "this is…" },
        .{ .text = "abcdef", .stop = 0, .exp = "" },
        .{ .text = "cafe\u{0301}", .stop = 4, .exp = "cafe\u{0301}" },
        .{ .text = "cafe\u{0301}", .stop = 5, .exp = "cafe\u{0301}" },
        .{ .text = "cafe\u{0301}", .stop = 6, .exp = "cafe\u{0301}" },
        .{ .text = "cafe\u{0301} noir", .stop = 6, .exp = "cafe\u{0301} …" },
        .{ .text = "éé", .stop = 1, .exp = "…" },
        .{ .text = "✅", .stop = 1, .exp = "…" },
        .{ .text = "✅x", .stop = 2, .exp = " …" },
        .{ .text = "❤️", .stop = 6, .exp = "❤️" },
        .{ .text = "❤️", .stop = 7, .exp = "❤️" },
        .{ .text = "❤️", .stop = 8, .exp = "❤️" },
        .{ .text = "👍🏽", .stop = 7, .exp = "👍🏽" },
        .{ .text = "👍🏽", .stop = 8, .exp = "👍🏽" },
        .{ .text = "👍🏽", .stop = 9, .exp = "👍🏽" },
        .{ .text = "🇺🇸", .stop = 8, .exp = "🇺🇸" },
        .{ .text = "🇺🇸", .stop = 9, .exp = "🇺🇸" },
        .{ .text = "🇺🇸", .stop = 10, .exp = "🇺🇸" },
        .{ .text = "👨‍👩‍👧‍👦", .stop = 25, .exp = "👨‍👩‍👧‍👦" },
        .{ .text = "👨‍👩‍👧‍👦", .stop = 26, .exp = "👨‍👩‍👧‍👦" },
        .{ .text = "👨‍👩‍👧‍👦", .stop = 27, .exp = "👨‍👩‍👧‍👦" },
        .{ .text = "ok ✅ yes", .stop = 6, .exp = "ok ✅…" },
        .{ .text = "ok ✅ yes", .stop = 5, .exp = "ok  …" },
        .{ .text = "❤️ ok", .stop = 3, .exp = "❤️…" },
        .{ .text = "👍🏽 ok", .stop = 3, .exp = "👍🏽…" },
        .{ .text = "thumbs 👍🏽 up", .stop = 9, .exp = "thumbs  …" },
        .{ .text = "go 🇺🇸 now", .stop = 6, .exp = "go 🇺🇸…" },
        .{ .text = "go 🇺🇸🇨 now", .stop = 6, .exp = "go 🇺🇸…" },
        .{ .text = "中文", .stop = 4, .exp = "中文" },
        .{ .text = "family 👨‍👩‍👧‍👦 test", .stop = 10, .exp = "family 👨‍👩‍👧‍👦…" },
        .{ .text = &[_]u8{ 0xff, 0x61, 0x62, 0x63 }, .stop = 3, .exp = &[_]u8{ 0xff, 0x61, 0xe2, 0x80, 0xa6 } },
    };

    var buf: [256]u8 = undefined;
    for (cases) |tc| {
        var writer = std.Io.Writer.fixed(&buf);
        try truncate(&writer, tc.text, tc.stop);
        try testing.expectEqualStrings(tc.exp, writer.buffered());
    }
}

const std = @import("std");
const testing = std.testing;
