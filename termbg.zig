///
/// Query the terminal's default background color.
///
/// This is best-effort. We ask xterm-compatible terminals for OSC 11
/// (background color), then immediately send CSI 6n as a fallback marker. If
/// the first response we read is cursor position instead of OSC, we assume OSC
/// 11 was ignored and return an error.
///

// Probe the terminal and report whether its background is dark.
pub fn isDark(alloc: std.mem.Allocator) !bool {
    // open dev/tty
    var devtty = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write }) catch {
        return error.NotSupported;
    };
    defer devtty.close();
    return try isDarkWith(alloc, std.posix.getenv("TERM"), builtin.os.tag, RealTty{ .file = &devtty });
}

//
// internal
//

const bel = "\x07";
const esc = "\x1b";
const st = "\x1b\\";

// Probe terminal background color through an abstract tty interface.
fn isDarkWith(alloc: std.mem.Allocator, term_opt: ?[]const u8, os_tag: std.Target.Os.Tag, tty: anytype) !bool {
    _ = try supportedTerm(term_opt);
    const cc = try timeoutIndexes(os_tag);

    var tio = try tty.tcgetattr();
    const saved = tio;
    tio.lflag.ECHO = false;
    tio.lflag.ICANON = false;

    const timeout_in_deciseconds: u8 = 1;
    tio.cc[cc.vmin] = 0;
    tio.cc[cc.vtime] = timeout_in_deciseconds;

    try tty.tcsetattr(tio);
    defer tty.tcsetattr(saved) catch {};

    try tty.writeAll(esc ++ "]11;?\x07" ++ esc ++ "[6n");

    const response1 = try tty.readResponse(alloc);
    defer alloc.free(response1);
    if (!isOscResponse(response1)) {
        return error.NotSupported;
    }

    const response2 = tty.readResponse(alloc) catch null;
    defer if (response2) |buf| alloc.free(buf);

    const color = try parseResponse(response1);
    return color.isDark();
}

// Reject TERM values that are known not to support this probe.
fn supportedTerm(term_opt: ?[]const u8) ![]const u8 {
    const term = term_opt orelse return error.NotSupported;
    if (std.mem.startsWith(u8, term, "screen") or std.mem.startsWith(u8, term, "tmux") or std.mem.startsWith(u8, term, "dumb")) {
        return error.NotSupported;
    }
    return term;
}

// Return the cc indexes used to control non-blocking tty reads.
fn timeoutIndexes(os_tag: std.Target.Os.Tag) !struct { vmin: u8, vtime: u8 } {
    return switch (os_tag) {
        .linux => .{
            .vmin = @intFromEnum(std.os.linux.V.MIN),
            .vtime = @intFromEnum(std.os.linux.V.TIME),
        },
        .macos => .{
            // Darwin exposes these slots as constants in system headers, not Zig std.
            .vmin = 16,
            .vtime = 17,
        },
        else => error.NotSupported,
    };
}

// Report whether a response starts with an OSC sequence.
fn isOscResponse(response: []const u8) bool {
    return response.len >= 2 and response[1] == ']';
}

// Real tty adapter used by the public terminal probe.
const RealTty = struct {
    file: *std.fs.File,

    // Fetch the current terminal attributes.
    fn tcgetattr(self: @This()) !std.posix.termios {
        return try std.posix.tcgetattr(self.file.handle);
    }

    // Apply terminal attributes immediately.
    fn tcsetattr(self: @This(), tio: std.posix.termios) !void {
        try std.posix.tcsetattr(self.file.handle, .NOW, tio);
    }

    // Write raw bytes to the tty.
    fn writeAll(self: @This(), bytes: []const u8) !void {
        try self.file.writeAll(bytes);
    }

    // Read one OSC or CSI response from the tty.
    fn readResponse(self: @This(), alloc: std.mem.Allocator) ![]u8 {
        return try termReadResponse(alloc, self.file.handle);
    }
};

//
// read a response, defensively
//

// Read one OSC or CSI response from a terminal file descriptor.
fn termReadResponse(alloc: std.mem.Allocator, fd: std.posix.fd_t) ![]u8 {
    // fast forward to ESC
    while (try readByte(fd) != esc[0]) {}

    // next char should be either [ or ]
    const rtype = try readByte(fd);
    if (!(rtype == '[' or rtype == ']')) return error.InvalidData;

    // append first two bytes
    var out = try std.ArrayList(u8).initCapacity(alloc, 32);
    errdefer out.deinit(alloc);
    try out.append(alloc, esc[0]);
    try out.append(alloc, rtype);

    // now read the response
    while (true) {
        const ch = try readByte(fd);
        try out.append(alloc, ch);
        if (rtype == '[' and ch == 'R') break;
        if (rtype == ']' and ch == bel[0]) break;
        if (rtype == ']' and std.mem.endsWith(u8, out.items, st)) break;
    }

    return out.toOwnedSlice(alloc);
}

// Parse an OSC 11 response into a concrete RGB color.
fn parseResponse(s: []const u8) !Color {
    // ESC ]11;rgb:0b0b/2727/3232 BEL
    const prefix = esc ++ "]11;rgb:";
    if (!std.mem.startsWith(u8, s, prefix)) return error.InvalidData;

    const slashed = if (std.mem.endsWith(u8, s, bel))
        s[prefix.len .. s.len - bel.len]
    else if (std.mem.endsWith(u8, s, st))
        s[prefix.len .. s.len - st.len]
    else
        return error.InvalidData;

    var it = std.mem.splitScalar(u8, slashed, '/');
    const r = it.next() orelse return error.InvalidData;
    const g = it.next() orelse return error.InvalidData;
    const b = it.next() orelse return error.InvalidData;
    if (it.next() != null) return error.InvalidData;

    return .{
        .r = try parseHex(r),
        .g = try parseHex(g),
        .b = try parseHex(b),
    };
}

// One decoded RGB color plus helpers for OSC 11 parsing.
const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    // Parse a 3/6/9/12-digit RGB hex string, with optional leading '#'.
    fn initHex(hex: []const u8) !Color {
        const rgb = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
        if (rgb.len % 3 != 0) return error.InvalidHex;
        const n = rgb.len / 3;
        return .{
            .r = try parseHex(rgb[0 * n .. 1 * n]),
            .g = try parseHex(rgb[1 * n .. 2 * n]),
            .b = try parseHex(rgb[2 * n .. 3 * n]),
        };
    }

    // Format this color as a canonical lowercase hex string.
    fn toHex(self: Color, alloc: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(alloc, "#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
    }

    // Return relative luminance for the dark/light heuristic.
    fn luma(self: Color) f64 {
        const coeff = [3]f64{ 0.2126, 0.7152, 0.0722 };
        const rgb = [3]f64{
            @as(f64, @floatFromInt(self.r)) / 255.0,
            @as(f64, @floatFromInt(self.g)) / 255.0,
            @as(f64, @floatFromInt(self.b)) / 255.0,
        };
        var sum: f64 = 0;
        for (rgb, coeff) |x, c| {
            sum += (if (x == 0) 0 else @exp(@log(x) * 2.2)) * c;
        }
        return @round(sum * 1000.0) / 1000.0;
    }

    // Report whether this color is perceptually dark.
    fn isDark(self: Color) bool {
        return self.luma() < 0.36;
    }

    // Report whether this color is perceptually light.
    fn isLight(self: Color) bool {
        return !self.isDark();
    }
};

// Parse one RGB channel from 1/2/3/4 hex digits.
fn parseHex(hex: []const u8) !u8 {
    return switch (hex.len) {
        1 => blk: {
            const n = try std.fmt.parseInt(u8, hex, 16);
            break :blk (n << 4) | n;
        },
        2 => try std.fmt.parseInt(u8, hex, 16),
        3, 4 => try std.fmt.parseInt(u8, hex[0..2], 16),
        else => error.InvalidHex,
    };
}

// Read one byte from a file descriptor.
fn readByte(fd: std.posix.fd_t) !u8 {
    var buf: [1]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n != 1) return error.EndOfStream;
    return buf[0];
}

//
// testing
//

test "parse osc11 response" {
    try testing.expect((try parseResponse("\x1b]11;rgb:0000/0000/0000\x1b\\")).isDark());
    try testing.expect((try parseResponse("\x1b]11;rgb:ffff/ffff/ffff\x1b\\")).isLight());
}

test "parse osc11 response accepts bel terminator" {
    try testing.expect((try parseResponse("\x1b]11;rgb:ffff/ffff/ffff\x07")).isLight());
}

test "parse osc11 response accepts 2-digit channels" {
    const color = try parseResponse("\x1b]11;rgb:ff/ff/ff\x07");
    try testing.expectEqual(@as(u8, 0xff), color.r);
    try testing.expectEqual(@as(u8, 0xff), color.g);
    try testing.expectEqual(@as(u8, 0xff), color.b);
}

test "parse osc11 response rejects invalid prefix" {
    try testing.expectError(error.InvalidData, parseResponse("\x1b]10;rgb:ffff/ffff/ffff\x07"));
}

test "parse osc11 response rejects malformed payload" {
    try testing.expectError(error.InvalidCharacter, parseResponse("\x1b]11;rgb:zzzz/ffff/ffff\x07"));
}

test "supportedTerm validates TERM" {
    try testing.expectEqualStrings("xterm-256color", try supportedTerm("xterm-256color"));
    try testing.expectError(error.NotSupported, supportedTerm(null));
    try testing.expectError(error.NotSupported, supportedTerm("screen-256color"));
    try testing.expectError(error.NotSupported, supportedTerm("tmux-256color"));
    try testing.expectError(error.NotSupported, supportedTerm("dumb"));
}

test "timeoutIndexes supports linux and macos" {
    const linux = try timeoutIndexes(.linux);
    try testing.expectEqual(@as(u8, @intFromEnum(std.os.linux.V.MIN)), linux.vmin);
    try testing.expectEqual(@as(u8, @intFromEnum(std.os.linux.V.TIME)), linux.vtime);

    const macos = try timeoutIndexes(.macos);
    try testing.expectEqual(@as(u8, 16), macos.vmin);
    try testing.expectEqual(@as(u8, 17), macos.vtime);

    try testing.expectError(error.NotSupported, timeoutIndexes(.windows));
}

test "isOscResponse distinguishes osc and csi" {
    try testing.expect(isOscResponse("\x1b]11;rgb:ffff/ffff/ffff\x07"));
    try testing.expect(isOscResponse("\x1b]10;rgb:ffff/ffff/ffff\x07"));
    try testing.expect(!isOscResponse(""));
    try testing.expect(!isOscResponse("\x1b[1;1R"));
}

test "isDarkWith returns parsed darkness and restores tty state" {
    const FakeTty = struct {
        tio: std.posix.termios = std.mem.zeroes(std.posix.termios),
        configured: std.posix.termios = std.mem.zeroes(std.posix.termios),
        set_count: usize = 0,
        write_buf: [32]u8 = undefined,
        write_len: usize = 0,
        first: []const u8,
        second: ?[]const u8 = null,
        reads: usize = 0,

        // Return the current fake termios state.
        fn tcgetattr(self: *@This()) !std.posix.termios {
            return self.tio;
        }

        // Record the last requested termios state.
        fn tcsetattr(self: *@This(), tio: std.posix.termios) !void {
            if (self.set_count == 0) self.configured = tio;
            self.tio = tio;
            self.set_count += 1;
        }

        // Record the bytes written during probing.
        fn writeAll(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.write_buf[0..bytes.len], bytes);
            self.write_len = bytes.len;
        }

        // Return the scripted fake terminal responses.
        fn readResponse(self: *@This(), alloc: std.mem.Allocator) ![]u8 {
            defer self.reads += 1;
            return switch (self.reads) {
                0 => try alloc.dupe(u8, self.first),
                1 => if (self.second) |response| try alloc.dupe(u8, response) else error.WouldBlock,
                else => error.WouldBlock,
            };
        }
    };

    var tty = FakeTty{
        .first = "\x1b]11;rgb:0000/0000/0000\x07",
        .second = "\x1b[1;1R",
    };
    try testing.expect(try isDarkWith(testing.allocator, "xterm-256color", .linux, &tty));
    try testing.expectEqualStrings(esc ++ "]11;?\x07" ++ esc ++ "[6n", tty.write_buf[0..tty.write_len]);
    try testing.expectEqual(@as(usize, 2), tty.set_count);
    try testing.expectEqual(@as(u8, 1), tty.configured.cc[@intFromEnum(std.os.linux.V.TIME)]);
}

test "isDarkWith returns false for a light background" {
    const FakeTty = struct {
        tio: std.posix.termios = std.mem.zeroes(std.posix.termios),

        fn tcgetattr(self: *@This()) !std.posix.termios {
            return self.tio;
        }

        fn tcsetattr(self: *@This(), tio: std.posix.termios) !void {
            self.tio = tio;
        }

        fn writeAll(_: *@This(), _: []const u8) !void {}

        fn readResponse(self: *@This(), alloc: std.mem.Allocator) ![]u8 {
            _ = self;
            return try alloc.dupe(u8, "\x1b]11;rgb:ffff/ffff/ffff\x07");
        }
    };

    var tty = FakeTty{};
    try testing.expect(!(try isDarkWith(testing.allocator, "xterm-256color", .linux, &tty)));
}

test "isDarkWith returns not supported when osc11 is ignored" {
    const FakeTty = struct {
        // Return a zeroed fake termios state.
        fn tcgetattr(_: *@This()) !std.posix.termios {
            return std.mem.zeroes(std.posix.termios);
        }

        // Ignore terminal mode updates in this fake tty.
        fn tcsetattr(_: *@This(), _: std.posix.termios) !void {}

        // Ignore writes in this fake tty.
        fn writeAll(_: *@This(), _: []const u8) !void {}

        // Return a CSI response to simulate ignored OSC 11 support.
        fn readResponse(_: *@This(), alloc: std.mem.Allocator) ![]u8 {
            return try alloc.dupe(u8, "\x1b[1;1R");
        }
    };

    var tty = FakeTty{};
    try testing.expectError(error.NotSupported, isDarkWith(testing.allocator, "xterm-256color", .linux, &tty));
}

test "isDarkWith returns not supported for unsupported TERM" {
    const FakeTty = struct {
        fn tcgetattr(_: *@This()) !std.posix.termios {
            return std.mem.zeroes(std.posix.termios);
        }

        fn tcsetattr(_: *@This(), _: std.posix.termios) !void {}

        fn writeAll(_: *@This(), _: []const u8) !void {}

        fn readResponse(_: *@This(), alloc: std.mem.Allocator) ![]u8 {
            return try alloc.dupe(u8, "\x1b]11;rgb:0000/0000/0000\x07");
        }
    };

    var tty = FakeTty{};
    try testing.expectError(error.NotSupported, isDarkWith(testing.allocator, "tmux-256color", .linux, &tty));
}

test "readResponse reads csi response" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    _ = try std.posix.write(fds[1], "junk\x1b[12;34R");
    const out = try termReadResponse(testing.allocator, fds[0]);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[12;34R", out);
}

test "readResponse reads osc bel response" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    _ = try std.posix.write(fds[1], "\x1b]11;rgb:ffff/ffff/ffff\x07");
    const out = try termReadResponse(testing.allocator, fds[0]);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x07", out);
}

test "readResponse reads osc st response" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    _ = try std.posix.write(fds[1], "\x1b]11;rgb:ffff/ffff/ffff\x1b\\");
    const out = try termReadResponse(testing.allocator, fds[0]);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x1b\\", out);
}

test "readResponse rejects invalid response type" {
    const fds = try std.posix.pipe();
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    _ = try std.posix.write(fds[1], "\x1bXoops");
    try testing.expectError(error.InvalidData, termReadResponse(testing.allocator, fds[0]));
}

test "Color.initHex parses variable channel widths" {
    const short = try Color.initHex("abc");
    const long = try Color.initHex("#111122223333");
    try testing.expectEqual(@as(u8, 0xaa), short.r);
    try testing.expectEqual(@as(u8, 0xbb), short.g);
    try testing.expectEqual(@as(u8, 0xcc), short.b);
    try testing.expectEqual(@as(u8, 0x11), long.r);
    try testing.expectEqual(@as(u8, 0x22), long.g);
    try testing.expectEqual(@as(u8, 0x33), long.b);
}

test "Color.initHex rejects empty input" {
    try testing.expectError(error.InvalidHex, Color.initHex(""));
}

test "Color helpers report hex and brightness" {
    const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    const threshold: Color = .{ .r = 148, .g = 148, .b = 148 };
    const hex = try white.toHex(testing.allocator);
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings("#ffffff", hex);
    try testing.expect(black.isDark());
    try testing.expect(white.isLight());
    try testing.expect(threshold.luma() < 0.36);
    try testing.expect(threshold.isDark());
}

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
