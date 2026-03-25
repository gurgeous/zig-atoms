/// zig-re - Single-file Zig regex library. ASCII only, no Unicode.
///
/// This is a zig port of Tiny-Rex, a C regex lib. By Alberto Demichelis and
/// Oscar Martinez, see github.com/omtinez/tiny-rex. zlib/libpng license below.
///
/// ── Supported syntax ────────────────────────────────────────────────────────
///   .          any character
///   ^  $       start / end of string anchors
///   |          alternation
///   (...)      capturing group
///   (?:...)    non-capturing group
///   [...]      character class          [abc]  [a-z]
///   [^...]     negated character class
///   *  +  ?    greedy: 0+, 1+, 0-or-1
///   {n}        exactly n times
///   {n,}       at least n times
///   {n,m}      between n and m times
///
///   \w \W   word / non-word  ([0-9A-Za-z_])
///   \s \S   whitespace / non-whitespace
///   \d \D   digit / non-digit
///   \b \B   word boundary / non-word-boundary
///
/// ── Differences from PCRE ───────────────────────────────────────────────────
///   - No lazy quantifiers (*? +? ??)   — greedy only
///   - No backreferences                — \1 \2 etc.
///   - No named groups                  — (?<name>...)
///   - No flags in pattern              — (?i) (?m) etc.
///   - No Unicode                       — byte-level ASCII matching only
///   - \A start-of-string anchor        — use ^ instead
///   - \z / \Z end-of-string anchors    — use $ instead
///   - No lookahead/lookbehind          — (?=) (?!) (?<=) (?<!)
///
/// ── Differences from C original ─────────────────────────────────────────────
///   - \l, \u, \x/\X, \c/\C, and \p/\P removed
///   - \b uses \w/\W boundary transition (not isspace)
///
/// zlib/libpng License
///
/// Copyright (C) 2026 gurgeous
/// Copyright (C) 2014 Oscar Martinez
/// Copyright (C) 2003-2006 Alberto Demichelis
///
/// This software is provided 'as-is', without any express or implied warranty.
/// In no event will the authors be held liable for any damages arising from the
/// use of this software.
///
/// Permission is granted to anyone to use this software for any purpose,
/// including commercial applications, and to alter it and redistribute it
/// freely, subject to the following restrictions:
///
/// 1. The origin of this software must not be misrepresented; you must not claim
///    that you wrote the original software. If you use this software in a product,
///    an acknowledgment in the product documentation would be appreciated but is
///    not required.
///
/// 2. Altered source versions must be plainly marked as such, and must not be
///    misrepresented as being the original software.
///
/// 3. This notice may not be removed or altered from any source distribution.
///

//
// constructor
//

// A compiled regular expression. Create with `init()`, free with `deinit()`.
pub const Regex = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty, // compiled re
    nsubexpr: usize = 0, // total capture slots
    opts: RegexOptions = .{}, // compile-time matcher options

    // Compile a pattern string into a Regex.
    pub fn init(alloc: std.mem.Allocator, pattern: []const u8, opts: RegexOptions) RegexError!Regex {
        var re = Regex.initEmpty(alloc, opts);
        errdefer re.deinit();

        // Node 0 is always the root OP_EXPR; subexpr 0 is the whole match.
        var c = Compiler{ .re = &re, .pat = pattern };
        const root = try c.newNode(OP_EXPR);
        const inner = try c.parseList();
        re.nodes.items[@intCast(root)].left = inner;
        if (c.pos != pattern.len) return error.UnexpectedChar;

        return re;
    }

    // Allocate an empty Regex; used only by `init()`.
    fn initEmpty(alloc: std.mem.Allocator, options: RegexOptions) Regex {
        return .{ .alloc = alloc, .opts = options };
    }

    // Free all memory owned by this Regex.
    pub fn deinit(self: *Regex) void {
        self.nodes.deinit(self.alloc);
    }

    // Returns true if matches anywhere in string.
    pub fn isMatch(self: *const Regex, text: []const u8) RegexError!bool {
        var md = try self.match(text);
        defer if (md) |*m| m.deinit();
        return md != null;
    }

    // Find the first occurrence of the pattern anywhere in text (like re.search).
    // The caller owns the returned result and must call `deinit()`.
    pub fn match(self: *const Regex, text: []const u8) RegexError!?RegexMatchData {
        var it = self.scan(text);
        return it.next();
    }

    // Returns true if full-string match.
    pub fn isFullmatch(self: *const Regex, text: []const u8) RegexError!bool {
        var md = try self.fullmatch(text);
        defer if (md) |*m| m.deinit();
        return md != null;
    }

    // Full-string match with owned capture data for the successful match.
    // The caller owns the returned result and must call `deinit()`.
    pub fn fullmatch(self: *const Regex, text: []const u8) RegexError!?RegexMatchData {
        var md = try RegexMatchData.init(self.alloc, text, self.nsubexpr);
        errdefer md.deinit();

        const result = try matchNode(self, &md, 0, 0, MATCH_END_SENTINEL);
        const end = result orelse {
            md.deinit();
            return null;
        };
        if (end != md.text.len) {
            md.deinit();
            return null;
        }
        return md;
    }

    // Return an iterator that yields successive non-overlapping matches of the
    // pattern within text. The caller must keep both self and text alive for
    // the lifetime of the returned iterator. Each yielded result is owned by
    // the caller and must be deinitialized. Each result borrows `text`.
    pub fn scan(self: *const Regex, text: []const u8) RegexSearchIterator {
        return .{ .re = self, .text = text };
    }
};

// ── public types ──────────────────────────────────────────────────────────────

// All errors that `Regex.init()` can return.
pub const RegexError = error{
    EmptyClass, // [] has no members
    ExpectedBracket, // missing closing ]
    ExpectedColon, // missing : in (?:
    ExpectedCommaOrBrace, // bad {n,m} separator or terminator
    ExpectedLetter, // expected printable character
    ExpectedNumber, // expected decimal digit sequence
    ExpectedParenthesis, // missing closing )
    InvalidRangeChar, // range endpoint used a character class
    InvalidRangeNum, // range bounds are reversed
    NumericOverflow, // parsed number exceeds u16
    OutOfMemory, // alloc failed
    UnexpectedChar, // trailing or unsupported syntax
    UnfinishedRange, // class range ends before upper bound
};

// Compile-time options passed to `Regex.init()`.
pub const RegexOptions = struct {
    case_insensitive: bool = false, // ASCII case-fold literal/class matching
    multiline: bool = false, // ^ and $ also match around newlines
};

// A matched region: byte offset and length within the input text.
// `matched = false` means the capture group did not participate.
pub const RegexMatch = struct {
    matched: bool = false,
    begin: usize = 0,
    len: usize = 0,

    fn clear(self: *RegexMatch) void {
        self.* = .{};
    }
};

// An owned match result, including all captures for a single match attempt.
// `text` is borrowed: the caller must keep the input text alive while using this result.
// This is an owning type: shallow copies alias the same allocation.
// The caller must call `deinit()` exactly once for each live result.
pub const RegexMatchData = struct {
    alloc: std.mem.Allocator,
    text: []const u8,
    matches: []RegexMatch,

    fn init(alloc: std.mem.Allocator, text: []const u8, nsubexpr: usize) std.mem.Allocator.Error!RegexMatchData {
        const matches = try alloc.alloc(RegexMatch, nsubexpr);
        var md: RegexMatchData = .{ .alloc = alloc, .text = text, .matches = matches };
        md.clear();
        return md;
    }

    // Free the capture buffer owned by this result.
    pub fn deinit(self: *RegexMatchData) void {
        self.alloc.free(self.matches);
        self.* = undefined;
    }

    fn clear(self: *RegexMatchData) void {
        for (self.matches) |*m| m.clear();
    }

    // Return the total number of subexpressions in this result.
    pub fn subexpCount(self: RegexMatchData) usize {
        return self.matches.len;
    }

    // Return the nth subexpression, or null if n is out of range.
    // In-range groups that did not participate return `matched = false`.
    pub fn subexp(self: RegexMatchData, n: usize) ?RegexMatch {
        return if (n < self.matches.len) self.matches[n] else null;
    }
};

// Stateful iterator returned by scan(); holds borrowed references to the
// Regex and input text.
pub const RegexSearchIterator = struct {
    re: *const Regex,
    text: []const u8,
    pos: usize = 0,

    // Return the next non-overlapping match, or null when the text is exhausted.
    // The caller owns each returned result and must call `deinit()`.
    pub fn next(self: *RegexSearchIterator) RegexError!?RegexMatchData {
        if (self.pos > self.text.len) return null;

        var md = try RegexMatchData.init(self.re.alloc, self.text, self.re.nsubexpr);
        errdefer md.deinit();

        var idx = self.pos;
        while (idx <= self.text.len) {
            md.clear();
            if (try matchNode(self.re, &md, 0, idx, -1)) |end| {
                // Advance past this match. For zero-width matches step by 1 so
                // the same position is never returned twice.
                self.pos = if (end > idx) end else end + 1;
                return md;
            }
            idx += 1;
        }

        // done, mark exhausted
        self.pos = self.text.len + 1;
        md.deinit();
        return null;
    }
};

// ── internal node representation ──────────────────────────────────────────────

// One node in the compiled re NFA;
const Node = struct {
    kind: i32, // kind encodes the node op or a literal byte
    left: i32 = -1, // child / class-head / repeat-target
    right: i32 = -1, // OR right-branch / repeat-bounds / subexpr index
    next: i32 = -1, // sibling in sequence
};

// ── pattern compiler ──────────────────────────────────────────────────────────
// Recursive-descent parser that builds the node array from a pattern string.

// ── node type constants ───────────────────────────────────────────────────────
// Values > 255 so they can't collide with literal byte values stored as i32.
const OP_GREEDY: i32 = 256; // * + ? {n,m}
const OP_OR: i32 = 257; // |
const OP_EXPR: i32 = 258; // capturing group (...)
const OP_NOCAPEXPR: i32 = 259; // non-capturing group (?:...)
const OP_DOT: i32 = 260; // . — any character
const OP_CLASS: i32 = 261; // [...] — character class
const OP_CCLASS: i32 = 262; // \w \d etc. — named character class
const OP_NCLASS: i32 = 263; // [^...] — negated character class
const OP_RANGE: i32 = 264; // a-z inside [...]
const OP_EOL: i32 = 265; // $ — end of string
const OP_BOL: i32 = 266; // ^ — beginning of string
const OP_WB: i32 = 267; // \b \B — word boundary
const MATCH_END_SENTINEL: i32 = -2; // internal full-match continuation

// Parser state while compiling a pattern string into nodes.
const Compiler = struct {
    re: *Regex,
    pat: []const u8,
    pos: usize = 0,

    // Allocate a new node of the given kind, returning its index.
    fn newNode(c: *Compiler, kind: i32) RegexError!i32 {
        var n = Node{ .kind = kind };
        if (kind == OP_EXPR) {
            n.right = @intCast(c.re.nsubexpr);
            c.re.nsubexpr += 1;
        }
        try c.re.nodes.append(c.re.alloc, n);
        return @intCast(c.re.nodes.items.len - 1);
    }

    // Return the current character without advancing, or 0 at end of pattern.
    fn peek(c: *Compiler) u8 {
        return if (c.pos < c.pat.len) c.pat[c.pos] else 0;
    }

    // Return and consume the current character.
    fn advance(c: *Compiler) u8 {
        const ch = c.peek();
        c.pos += 1;
        return ch;
    }

    // Consume the expected character or return err.
    fn expectChar(c: *Compiler, ch: u8, err: RegexError) RegexError!void {
        if (c.peek() != ch) return err;
        c.pos += 1;
    }

    // Decode a single escape sequence to its raw byte value (used inside [...]).
    fn escapeChar(c: *Compiler) RegexError!u8 {
        if (c.peek() == '\\') {
            c.pos += 1;
            if (c.pos >= c.pat.len) return error.UnexpectedChar;
            return switch (c.advance()) {
                'a' => '\x07',
                'f' => '\x0C',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => '\x0B',
                else => |ch| ch,
            };
        }
        const ch = c.peek();
        if (!std.ascii.isPrint(ch)) return error.ExpectedLetter;
        c.pos += 1;
        return ch;
    }

    // Parse one character or escape sequence into a node; in_class=true disables \b as anchor.
    fn charNode(c: *Compiler, in_class: bool) RegexError!i32 {
        if (c.peek() == '\\') {
            c.pos += 1;
            if (c.pos >= c.pat.len) return error.UnexpectedChar;
            const ch = c.advance();
            return switch (ch) {
                'a' => c.newNode('\x07'),
                'f' => c.newNode('\x0C'),
                'n' => c.newNode('\n'),
                'r' => c.newNode('\r'),
                't' => c.newNode('\t'),
                'v' => c.newNode('\x0B'),
                'w', 'W', 's', 'S', 'd', 'D' => blk: {
                    const n = try c.newNode(OP_CCLASS);
                    c.re.nodes.items[@intCast(n)].left = ch;
                    break :blk n;
                },
                'b', 'B' => if (!in_class) blk: {
                    const nd = try c.newNode(OP_WB);
                    c.re.nodes.items[@intCast(nd)].left = ch;
                    break :blk nd;
                } else c.newNode(ch), // inside [...], \b/\B are literal b/B
                else => c.newNode(ch),
            };
        }

        const ch = c.peek();
        if (!std.ascii.isPrint(ch)) return error.ExpectedLetter;
        c.pos += 1;
        return c.newNode(ch);
    }

    // Parse a [...] or [^...] character class into a linked chain of nodes.
    fn parseClass(c: *Compiler) RegexError!i32 {
        const ret: i32 = if (c.peek() == '^') blk: {
            c.pos += 1;
            break :blk try c.newNode(OP_NCLASS);
        } else try c.newNode(OP_CLASS);

        if (c.peek() == ']') return error.EmptyClass;

        var chain = ret;
        var first: i32 = -1;
        while (c.peek() != ']' and c.pos < c.pat.len) {
            if (c.peek() == '-' and first != -1) {
                // Range: e.g. a-z. Validate that lo <= hi and that lo is not a class.
                c.pos += 1;
                if (c.peek() == ']') return error.UnfinishedRange;
                const r = try c.newNode(OP_RANGE);
                const first_kind = c.re.nodes.items[@intCast(first)].kind;
                if (first_kind == OP_CCLASS) return error.InvalidRangeChar;
                const lo: u8 = @intCast(first_kind);
                const hi = try c.escapeChar();
                if (lo > hi) return error.InvalidRangeNum;
                c.re.nodes.items[@intCast(r)].left = lo;
                c.re.nodes.items[@intCast(r)].right = hi;
                c.re.nodes.items[@intCast(chain)].next = r;
                chain = r;
                first = -1;
            } else {
                if (first != -1) {
                    c.re.nodes.items[@intCast(chain)].next = first;
                    chain = first;
                }
                first = try c.charNode(true);
            }
        }
        if (first != -1) {
            c.re.nodes.items[@intCast(chain)].next = first;
        }
        // The class/nclass node's left points to the first member of the chain.
        c.re.nodes.items[@intCast(ret)].left = c.re.nodes.items[@intCast(ret)].next;
        c.re.nodes.items[@intCast(ret)].next = -1;
        return ret;
    }

    // Parse a decimal integer for {n} / {n,m} quantifiers.
    fn parseNumber(c: *Compiler) RegexError!u16 {
        if (!std.ascii.isDigit(c.peek())) return error.ExpectedNumber;
        var val: u32 = 0;
        while (std.ascii.isDigit(c.peek())) {
            val = val * 10 + (c.advance() - '0');
            if (val > 0xFFFF) return error.NumericOverflow;
        }
        return @intCast(val);
    }

    // Parse one atomic element (literal, group, class, anchor) plus any quantifier, then chain the next element.
    fn parseElement(c: *Compiler) RegexError!i32 {
        var ret: i32 = switch (c.peek()) {
            '(' => blk: {
                c.pos += 1;
                const expr: i32 = if (c.peek() == '?') inner: {
                    c.pos += 1;
                    try c.expectChar(':', error.ExpectedColon);
                    break :inner try c.newNode(OP_NOCAPEXPR);
                } else try c.newNode(OP_EXPR);
                const inner = try c.parseList();
                c.re.nodes.items[@intCast(expr)].left = inner;
                try c.expectChar(')', error.ExpectedParenthesis);
                break :blk expr;
            },
            '[' => blk: {
                c.pos += 1;
                const cls = try c.parseClass();
                try c.expectChar(']', error.ExpectedBracket);
                break :blk cls;
            },
            '$' => blk: {
                c.pos += 1;
                break :blk try c.newNode(OP_EOL);
            },
            '^' => blk: {
                c.pos += 1;
                break :blk try c.newNode(OP_BOL);
            },
            '.' => blk: {
                c.pos += 1;
                break :blk try c.newNode(OP_DOT);
            },
            else => try c.charNode(false),
        };

        // Attach a greedy quantifier wrapper if one follows.
        var bounds = RepeatBounds{};
        var is_greedy = false;
        switch (c.peek()) {
            '*' => {
                c.pos += 1;
                bounds = .{ .max = 0xFFFF };
                is_greedy = true;
            },
            '+' => {
                c.pos += 1;
                bounds = .{ .min = 1, .max = 0xFFFF };
                is_greedy = true;
            },
            '?' => {
                c.pos += 1;
                bounds = .{ .max = 1 };
                is_greedy = true;
            },
            '{' => {
                c.pos += 1;
                bounds.min = try c.parseNumber();
                switch (c.peek()) {
                    '}' => {
                        c.pos += 1;
                        bounds.max = bounds.min;
                    },
                    ',' => {
                        c.pos += 1;
                        bounds.max = if (std.ascii.isDigit(c.peek())) try c.parseNumber() else 0xFFFF;
                        try c.expectChar('}', error.ExpectedCommaOrBrace);
                    },
                    else => return error.ExpectedCommaOrBrace,
                }
                if (!bounds.isUnbounded() and bounds.min > bounds.max) return error.InvalidRangeNum;
                is_greedy = true;
            },
            else => {},
        }
        if (is_greedy) {
            // Reject lazy-quantifier spellings (*? +? ??) — not supported.
            if (c.peek() == '?') return error.UnexpectedChar;
            const gn = try c.newNode(OP_GREEDY);
            c.re.nodes.items[@intCast(gn)].left = ret;
            c.re.nodes.items[@intCast(gn)].right = bounds.encode();
            ret = gn;
        }

        // Chain the next element unless we are at a boundary character.
        const ch = c.peek();
        if (ch != '|' and ch != ')' and ch != '*' and ch != '+' and ch != 0) {
            const nxt = try c.parseElement();
            c.re.nodes.items[@intCast(ret)].next = nxt;
        }
        return ret;
    }

    // Parse an alternation expression (a sequence optionally followed by | and another list).
    fn parseList(c: *Compiler) RegexError!i32 {
        // Only parse an element if we are not at a boundary (end, '|', ')').
        const ch0 = c.peek();
        var ret: i32 = if (ch0 != 0 and ch0 != '|' and ch0 != ')') try c.parseElement() else -1;
        if (c.peek() == '|') {
            c.pos += 1;
            const or_node = try c.newNode(OP_OR);
            c.re.nodes.items[@intCast(or_node)].left = ret;
            // Evaluate parseList first: it may grow nodes and reallocate the backing
            // array, which would invalidate any pointer into items computed beforehand.
            const right = try c.parseList();
            c.re.nodes.items[@intCast(or_node)].right = right;
            ret = or_node;
        }
        return ret;
    }
};

// ── character-class helpers ───────────────────────────────────────────────────

// True if ch is a "word" character: alphanumeric or underscore.
fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

// Test ch against a named character class (the letter after \).
fn matchCClass(classid: u8, ch: u8) bool {
    return switch (classid) {
        'd' => std.ascii.isDigit(ch),
        's' => std.ascii.isWhitespace(ch),
        'w' => isWordChar(ch),
        'D' => !std.ascii.isDigit(ch),
        'S' => !std.ascii.isWhitespace(ch),
        'W' => !isWordChar(ch),
        else => false,
    };
}

// Inclusive repetition bounds for a greedy quantifier.
const RepeatBounds = struct {
    min: u16 = 0,
    max: u16 = 0,

    fn encode(self: RepeatBounds) i32 {
        return (@as(i32, self.min) << 16) | self.max;
    }

    fn decode(encoded: i32) RepeatBounds {
        return .{
            .min = @intCast((encoded >> 16) & 0xFFFF),
            .max = @intCast(encoded & 0xFFFF),
        };
    }

    fn isUnbounded(self: RepeatBounds) bool {
        return self.max == 0xFFFF;
    }
};

// Saved capture slots used to restore state during backtracking.
const MatchState = struct {
    matches: []RegexMatch,

    fn deinit(self: *MatchState, alloc: std.mem.Allocator) void {
        alloc.free(self.matches);
    }

    fn capture(alloc: std.mem.Allocator, md: *const RegexMatchData) std.mem.Allocator.Error!MatchState {
        const matches = try alloc.dupe(RegexMatch, md.matches);
        return .{ .matches = matches };
    }

    fn restore(self: *const MatchState, md: *RegexMatchData) void {
        std.mem.copyForwards(RegexMatch, md.matches, self.matches);
    }
};

// True if pos is a valid start-of-line anchor position within the current text.
fn isBolMatch(re: *const Regex, md: *const RegexMatchData, pos: usize) bool {
    if (pos == 0) return true;
    if (!re.opts.multiline or pos > md.text.len) return false;
    return md.text[pos - 1] == '\n';
}

// True if pos is a valid end-of-line anchor position within the current text.
fn isEolMatch(re: *const Regex, md: *const RegexMatchData, pos: usize) bool {
    if (pos == md.text.len) return true;
    if (!re.opts.multiline or pos >= md.text.len) return false;
    return md.text[pos] == '\n';
}

// Test ch against the member-chain of an OP_CLASS or OP_NCLASS node.
fn matchClass(re: *const Regex, node_idx: i32, ch: u8) bool {
    var idx = node_idx;
    while (idx != -1) {
        const node = &re.nodes.items[@intCast(idx)];
        switch (node.kind) {
            OP_RANGE => {
                const lo: u8 = @intCast(node.left);
                const hi: u8 = @intCast(node.right);
                if (re.opts.case_insensitive) {
                    // Check both the raw byte value (preserves non-letter chars
                    // that lie within the range, e.g. '_' inside [A-z]) and the
                    // case-folded value (so [A-Z] matches lowercase letters).
                    const raw_match = ch >= lo and ch <= hi;
                    const c2 = std.ascii.toLower(ch);
                    const folded_match = c2 >= std.ascii.toLower(lo) and c2 <= std.ascii.toLower(hi);
                    if (raw_match or folded_match) return true;
                } else {
                    if (ch >= lo and ch <= hi) return true;
                }
            },
            OP_CCLASS => if (matchCClass(@intCast(node.left), ch)) return true,
            else => {
                const pat: u8 = @intCast(node.kind);
                if (re.opts.case_insensitive) {
                    if (std.ascii.toLower(ch) == std.ascii.toLower(pat)) return true;
                } else {
                    if (ch == pat) return true;
                }
            },
        }
        idx = node.next;
    }
    return false;
}

// ── recursive matcher ─────────────────────────────────────────────────────────

// Walk a next-chained sequence starting at start_idx, returning the end position or null.
fn matchSequence(re: *const Regex, md: *RegexMatchData, start_idx: i32, pos: usize) RegexError!?usize {
    if (start_idx == MATCH_END_SENTINEL) {
        return if (isEolMatch(re, md, pos)) pos else null;
    }
    var temp = start_idx;
    var cur = pos;
    while (true) {
        const next_idx = re.nodes.items[@intCast(temp)].next;
        cur = try matchNode(re, md, temp, cur, -1) orelse return null;
        if (next_idx != -1) temp = next_idx else return cur;
    }
}

// Attempt to match node_idx at pos; return the new position on success or null on failure.
fn matchNode(re: *const Regex, md: *RegexMatchData, node_idx: i32, pos: usize, next_idx: i32) RegexError!?usize {
    const node = &re.nodes.items[@intCast(node_idx)];
    switch (node.kind) {
        OP_GREEDY => {
            // Greedy with backtracking: collect positions for each repetition of the
            // sub-node (most reps first), then try the continuation from the longest
            // match downward until one succeeds.
            const bounds = RepeatBounds.decode(node.right);
            const p0: usize = bounds.min;
            const p1: usize = bounds.max;
            const continuation: i32 = if (node.next != -1) node.next else next_idx;

            // positions[k] = text offset after k repetitions of the sub-node.
            var positions: std.ArrayList(usize) = .empty;
            defer positions.deinit(re.alloc);
            try positions.append(re.alloc, pos);

            // states[k] = capture state after k repetitions of the sub-node.
            var states: std.ArrayList(MatchState) = .empty;
            defer {
                for (states.items) |*state| state.deinit(re.alloc);
                states.deinit(re.alloc);
            }
            try states.append(re.alloc, try MatchState.capture(re.alloc, md));

            var s = pos;
            while (bounds.isUnbounded() or positions.items.len - 1 < p1) {
                // Collect one repetition with the greedy node itself as the
                // continuation. This lets alternation inside the repeated
                // subpattern choose a branch that can continue through another
                // repetition or the eventual post-greedy continuation.
                const ns = try matchNode(re, md, node.left, s, node_idx) orelse break;
                if (ns == s) break; // zero-width match: prevent infinite loop
                try positions.append(re.alloc, ns);
                try states.append(re.alloc, try MatchState.capture(re.alloc, md));
                s = ns;
                if (s >= md.text.len) break;
            }

            const nmatches = positions.items.len - 1;

            // Try from most-greedy to least-greedy.
            var i: usize = nmatches;
            while (true) {
                if (i >= p0 and (bounds.isUnbounded() or i <= p1)) {
                    const cur_pos = positions.items[i];
                    states.items[i].restore(md);
                    if (continuation == -1) return cur_pos;
                    if (try matchSequence(re, md, continuation, cur_pos) != null) {
                        return cur_pos;
                    }
                }
                if (i == 0) break;
                i -= 1;
            }
            states.items[0].restore(md);
            return null;
        },
        OP_OR => {
            // Either branch may be -1 when a pattern ends with | or starts with |.
            // An empty branch matches here without consuming any input.
            var initial_state = try MatchState.capture(re.alloc, md);
            defer initial_state.deinit(re.alloc);

            const left_pos: ?usize = if (node.left != -1)
                try matchSequence(re, md, node.left, pos)
            else
                pos;

            if (left_pos) |lp| {
                // If a continuation is known, verify it can succeed before
                // committing to the left branch. This enables alternation
                // backtracking: /a|ab/ can match "ab" by yielding 'a' when the
                // continuation (here, an implicit OP_EOL sentinel) fails after
                // consuming only one character.
                if (next_idx == -1 or try matchSequence(re, md, next_idx, lp) != null) {
                    return lp;
                }
                // Left matched but the continuation can't proceed; try right.
            }

            initial_state.restore(md);
            if (node.right == -1) return pos; // empty right branch
            return try matchSequence(re, md, node.right, pos);
        },
        OP_EXPR, OP_NOCAPEXPR => {
            // Match all child nodes in sequence; record begin/len for capturing groups.
            var n_idx = node.left;
            var cur = pos;
            var capture: i32 = -1;
            if (node.kind == OP_EXPR) {
                capture = node.right;
                md.matches[@intCast(capture)].begin = cur;
                md.matches[@intCast(capture)].matched = false;
            }
            while (n_idx != -1) {
                const n = &re.nodes.items[@intCast(n_idx)];
                const subnext: i32 = if (n.next != -1) n.next else next_idx;
                cur = try matchNode(re, md, n_idx, cur, subnext) orelse {
                    if (capture != -1)
                        md.matches[@intCast(capture)].clear();
                    return null;
                };
                n_idx = n.next;
            }
            if (capture != -1) {
                md.matches[@intCast(capture)].matched = true;
                md.matches[@intCast(capture)].len =
                    cur - md.matches[@intCast(capture)].begin;
            }
            return cur;
        },
        OP_WB => {
            // Word boundary: \w/\W transition; consistent with PCRE (not isspace).
            const cur_w = if (pos < md.text.len) isWordChar(md.text[pos]) else false;
            const prev_w = if (pos > 0) isWordChar(md.text[pos - 1]) else false;
            const is_wb = if (pos == 0) cur_w else if (pos == md.text.len) prev_w else cur_w != prev_w;
            return if ((node.left == 'b') == is_wb) pos else null;
        },
        OP_BOL => return if (isBolMatch(re, md, pos)) pos else null,
        OP_EOL => return if (isEolMatch(re, md, pos)) pos else null,
        OP_DOT => {
            // Match any single character; fail at end of string.
            if (pos >= md.text.len) return null;
            return pos + 1;
        },
        OP_CLASS, OP_NCLASS => {
            // Match (or reject) the current character against the class member chain.
            if (pos >= md.text.len) return null;
            const ch = md.text[pos];
            const hit = matchClass(re, node.left, ch);
            return if (hit == (node.kind == OP_CLASS)) pos + 1 else null;
        },
        OP_CCLASS => {
            // Match a standalone named class outside [...].
            if (pos >= md.text.len) return null;
            return if (matchCClass(@intCast(node.left), md.text[pos])) pos + 1 else null;
        },
        else => {
            // Literal byte comparison, with optional case folding.
            if (pos >= md.text.len) return null;
            const pat: u8 = @intCast(node.kind);
            const ch = md.text[pos];
            const eq = if (re.opts.case_insensitive) std.ascii.toLower(ch) == std.ascii.toLower(pat) else ch == pat;
            return if (eq) pos + 1 else null;
        },
    }
}

//
// testing
//

const ci_opts = RegexOptions{ .case_insensitive = true };
const default_opts = RegexOptions{};
const multiline_opts = RegexOptions{ .multiline = true };

test "re" {
    // basics
    try expectSearch("\\d+", "abc123def456", 3, 6);
    try expectNoSearch("\\d+", "abcdef");

    // literals
    try expectMatch("hello", "hello", true);
    try expectMatch("hello", "hell", false);
    try expectMatch("hello", "helloo", false);

    // dots
    try expectMatch("h.llo", "hello", true);
    try expectMatch("h.llo", "hXllo", true);
    try expectMatch("...", "abc", true);
    try expectMatch("...", "ab", false);

    // anchors
    try expectSearch("^foo", "foobar", 0, 3);
    try expectSearch("bar$", "foobar", 3, 6);
    try expectNoSearch("^foo", "barfoo");
    try expectNoSearch("bar$", "barfoo");
    try expectMatch("^hello$", "hello", true);
    try expectMatch("^hello$", "hello!", false);

    // star
    try expectMatch("ab*c", "ac", true);
    try expectMatch("ab*c", "abc", true);
    try expectMatch("ab*c", "abbbbc", true);
    // plus
    try expectMatch("ab+c", "ac", false);
    try expectMatch("ab+c", "abc", true);
    try expectMatch("ab+c", "abbbbc", true);
    // question
    try expectMatch("ab?c", "ac", true);
    try expectMatch("ab?c", "abc", true);
    try expectMatch("ab?c", "abbc", false);

    // braces
    try expectMatch("x{2}yy", "xxyy", true);
    try expectMatch("x{2}yy", "xxxyy", false);
    try expectMatch("x{2}yy", "xyy", false);
    // min
    try expectMatch("x{2,}y", "xxy", true);
    try expectMatch("x{2,}y", "xxxxy", true);
    try expectMatch("x{2,}y", "xy", false);
    // range
    try expectMatch("x{2,4}", "xx", true);
    try expectMatch("x{2,4}", "xxx", true);
    try expectMatch("x{2,4}", "xxxx", true);
    try expectMatch("x{2,4}", "x", false);
    try expectMatch("x{2,4}", "xxxxx", false);
    // zero
    try expectMatch("a{0}b", "b", true);
    try expectMatch("a{0}b", "ab", false);
    try expectMatch("a{0,}b", "b", true);
    try expectMatch("a{0,}b", "aaab", true);
    try expectMatch("a{0,2}b", "b", true);
    try expectMatch("a{0,2}b", "ab", true);
    try expectMatch("a{0,2}b", "aab", true);
    try expectMatch("a{0,2}b", "aaab", false);
    // search
    try expectSearch("x{2}yy", "AxxyyxxA", 1, 5);

    // alternation
    try expectMatch("cat|dog", "cat", true);
    try expectMatch("cat|dog", "dog", true);
    try expectMatch("cat|dog", "bird", false);
    try expectSearch("cat|dog", "I have a dog.", 9, 12);
    // triple
    try expectMatch("a|b|c", "a", true);
    try expectMatch("a|b|c", "b", true);
    try expectMatch("a|b|c", "c", true);
    try expectMatch("a|b|c", "d", false);
    // group
    try expectMatch("(cat|dog)s?", "cats", true);
    try expectMatch("(cat|dog)s?", "dogs", true);
    try expectMatch("(cat|dog)s?", "cat", true);
    try expectMatch("(cat|dog)s?", "bird", false);
    // backtracks against later context
    try expectMatch("a|ab", "ab", true);
    try expectMatch("(a|ab)c", "abc", true);
    try expectSearch("(a|ab)c", "zabc", 1, 4);
    // empty
    try expectMatch("a|", "", true);
    try expectMatch("|a", "", true);
    try expectMatch("|a", "a", true);
    try expectSearch("a|", "za", 0, 0);

    // brackets
    try expectMatch("[abc]", "a", true);
    try expectMatch("[abc]", "b", true);
    try expectMatch("[abc]", "d", false);
    // range
    try expectMatch("[a-z]+", "hello", true);
    try expectMatch("[a-z]+", "HELLO", false);
    try expectMatch("[0-9]+", "123", true);
    try expectMatch("[0-9]+", "abc", false);
    // uppercase range [A-Z] without CI
    try expectMatch("[A-Z]+", "HELLO", true);
    try expectMatch("[A-Z]+", "hello", false);
    try expectMatch("[A-Z]", "A", true);
    try expectMatch("[A-Z]", "Z", true);
    try expectMatch("[A-Z]", "a", false);
    // multi-range
    try expectMatch("[a-zA-Z0-9]+", "Hello123", true);
    try expectMatch("[a-zA-Z0-9]+", "!@#", false);
    try expectMatch("[a-zA-Z]+", "Hello", true);
    try expectMatch("[a-zA-Z]+", "123", false);
    // negated
    try expectMatch("[^abc]", "d", true);
    try expectMatch("[^abc]", "a", false);
    try expectMatch("[^0-9]+", "abc", true);
    try expectMatch("[^0-9]+", "123", false);
    // negated range [^a-z]
    try expectMatch("[^a-z]+", "ABC123", true);
    try expectMatch("[^a-z]+", "hello", false);
    try expectMatch("[^a-z]+", "HELLO", true);
    // class
    try expectMatch("[\\d]+", "123", true);
    try expectMatch("[\\d]+", "abc", false);
    try expectMatch("[\\w]+", "hi_123", true);
    try expectMatch("[\\s\\d]+", "1 2 3", true);
    try expectMatch("[\\s\\d]+", "abc", false);

    // classes
    try expectMatch("\\w+", "hello123", true);
    try expectMatch("\\w+", "hello_", true);
    try expectMatch("\\W+", "!@#", true);
    try expectMatch("\\W+", "abc", false);
    try expectMatch("\\d+", "123", true);
    try expectMatch("\\d+", "abc", false);
    try expectMatch("\\D+", "abc", true);
    try expectMatch("\\D+", "123", false);
    try expectMatch("\\s+", "   ", true);
    try expectMatch("\\s+", "abc", false);
    try expectMatch("\\S+", "abc", true);
    try expectMatch("\\S+", "   ", false);
}

test "caret is an anchor outside character classes even mid-sequence" {
    try expectMatch("a^b", "a^b", false);
    try expectMatch("a^b", "ab", false);
    try expectMatch("\\^", "^", true);
    try expectMatch("a\\^b", "a^b", true);
}

test "multiline anchors match line boundaries in search" {
    var re1 = try Regex.init(test_alloc, "^foo", multiline_opts);
    defer re1.deinit();
    var r1 = (try re1.match("bar\nfoo\nbaz")).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 4, 3);

    var re2 = try Regex.init(test_alloc, "bar$", multiline_opts);
    defer re2.deinit();
    var r2 = (try re2.match("foo\nbar\nbaz")).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 4, 3);
}

test "multiline disabled keeps anchors at string boundaries only" {
    var re1 = try Regex.init(test_alloc, "^foo", default_opts);
    defer re1.deinit();
    try testing.expect(try re1.match("bar\nfoo\nbaz") == null);

    var re2 = try Regex.init(test_alloc, "bar$", default_opts);
    defer re2.deinit();
    try testing.expect(try re2.match("foo\nbar\nbaz") == null);
}

test "multiline full match can target an interior line" {
    var re = try Regex.init(test_alloc, "^foo$", multiline_opts);
    defer re.deinit();
    try testing.expect(try didFullmatch(&re, "foo"));
    try testing.expect(!try didFullmatch(&re, "bar\nfoo\nbaz"));
    var r = (try re.match("bar\nfoo\nbaz")).?;
    defer r.deinit();
    try expectWholeMatch(r, 4, 3);
}

test "multiline zero-width anchors on empty lines" {
    var re = try Regex.init(test_alloc, "^$", multiline_opts);
    defer re.deinit();
    var r = (try re.match("a\n\nb")).?;
    defer r.deinit();
    try expectWholeMatch(r, 2, 0);
}

test "multiline scan anchors match interior lines" {
    var re = try Regex.init(test_alloc, "^foo", multiline_opts);
    defer re.deinit();
    var it = re.scan("bar\nfoo\nfoo");

    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 4, 3);

    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 8, 3);

    try testing.expect(try it.next() == null);
}

test "escapes" {
    // \t
    try expectMatch("a\\tb", "a\tb", true);
    try expectMatch("a\\nb", "a\nb", true);

    // r f v a
    try expectMatch("a\\rb", "a\rb", true);
    try expectMatch("a\\fb", "a\x0Cb", true);
    try expectMatch("a\\vb", "a\x0Bb", true);
    try expectMatch("a\\ab", "a\x07b", true);

    // metacharacters
    try expectMatch("\\(", "(", true);
    try expectMatch("\\)", ")", true);
    try expectMatch("\\[", "[", true);
    try expectMatch("\\]", "]", true);
    try expectMatch("\\{", "{", true);
    try expectMatch("\\}", "}", true);
    try expectMatch("\\|", "|", true);
    try expectMatch("\\*", "*", true);
    try expectMatch("\\+", "+", true);
    try expectMatch("\\?", "?", true);
    try expectMatch("\\.", ".", true);
    try expectMatch("\\\\", "\\", true);
    try expectMatch("\\$", "$", true);
    try expectMatch("\\^", "^", true);
}

test "a* matches empty string" {
    try expectMatch("a*", "", true);
    try expectMatch("a*", "aaa", true);
    try expectMatch("^$", "", true);
    try expectMatch("^$", "a", false);
}

test ".* matches anything" {
    try expectMatch(".*", "", true);
    try expectMatch(".*", "hello", true);
    try expectMatch("a.*b", "aXb", true);
    try expectMatch("a.*b", "aXXXb", true);
    try expectMatch("a.*b", "b", false);
    try expectMatch("a.*b", "ab", true);
}

test "greedy backtracking" {
    try expectMatch("a.*b", "ab", true);
    try expectMatch("foo.*bar", "foobar", true);
    try expectMatch("a.*b.*c", "abc", true);
    try expectMatch("a.*b.*c", "aXbYc", true);
    try expectMatch("a.*bc", "abc", true);
    try expectMatch("a.*bc", "abbc", true);
    try expectMatch("a.*bbc", "abbbc", true);
    try expectMatch("a.+b", "aXb", true);
    try expectMatch("a.+b", "ab", false);
    try expectSearch("a.*b", "xaby", 1, 3);
    try expectMatch("(a.*b)c", "abc", true);
    try expectMatch("(a.*b)c", "aXbc", true);
    try expectMatch("(a|ab)*c", "aac", true);
    try expectMatch("(a|ab)*c", "abc", true);
}

test "group" {
    var re = try Regex.init(test_alloc, "(hello)", default_opts);
    defer re.deinit();
    const text = "hello";
    var md = (try re.fullmatch(text)).?;
    defer md.deinit();
    try testing.expectEqual(@as(usize, 2), md.subexpCount());
    const m0 = md.subexp(0).?;
    const m1 = md.subexp(1).?;
    try testing.expect(m0.matched);
    try testing.expect(m1.matched);
    try testing.expectEqual(@as(usize, 0), m0.begin);
    try testing.expectEqual(@as(usize, 5), m0.len);
    try testing.expectEqual(@as(usize, 0), m1.begin);
    try testing.expectEqual(@as(usize, 5), m1.len);
}

test "non-capturing group" {
    var re = try Regex.init(test_alloc, "(?:hello)", default_opts);
    defer re.deinit();
    var md = (try re.fullmatch("hello")).?;
    defer md.deinit();
    try testing.expectEqual(@as(usize, 1), md.subexpCount());
}

test "multiple captures" {
    var re = try Regex.init(test_alloc, "(\\d+)-(\\d+)", default_opts);
    defer re.deinit();
    const text = "123-456";
    var md = (try re.fullmatch(text)).?;
    defer md.deinit();
    const m1 = md.subexp(1).?;
    const m2 = md.subexp(2).?;
    try testing.expectEqualStrings("123", text[m1.begin .. m1.begin + m1.len]);
    try testing.expectEqualStrings("456", text[m2.begin .. m2.begin + m2.len]);
}

test "repeated capturing group keeps the final capture" {
    var re = try Regex.init(test_alloc, "(\\w)+", default_opts);
    defer re.deinit();
    const text = "word";
    var md = (try re.fullmatch(text)).?;
    defer md.deinit();
    const cap = md.subexp(1).?;
    try testing.expect(cap.matched);
    try testing.expectEqualStrings("d", text[cap.begin .. cap.begin + cap.len]);
}

test "nested groups capture" {
    var re = try Regex.init(test_alloc, "((\\d+)-(\\d+))", default_opts);
    defer re.deinit();
    const text = "123-456";
    var md = (try re.fullmatch(text)).?;
    defer md.deinit();
    try testing.expectEqual(@as(usize, 4), md.subexpCount());
    const m1 = md.subexp(1).?;
    const m2 = md.subexp(2).?;
    const m3 = md.subexp(3).?;
    try testing.expectEqualStrings("123-456", text[m1.begin .. m1.begin + m1.len]);
    try testing.expectEqualStrings("123", text[m2.begin .. m2.begin + m2.len]);
    try testing.expectEqualStrings("456", text[m3.begin .. m3.begin + m3.len]);
}

test "alternation backtracking clears captures from failed branch" {
    var re = try Regex.init(test_alloc, "((a)|(ab))c", default_opts);
    defer re.deinit();
    const text = "abc";
    var md = (try re.fullmatch(text)).?;
    defer md.deinit();

    const whole = md.subexp(0).?;
    const outer = md.subexp(1).?;
    const left = md.subexp(2).?;
    const right = md.subexp(3).?;

    try testing.expectEqualStrings("abc", text[whole.begin .. whole.begin + whole.len]);
    try testing.expectEqualStrings("ab", text[outer.begin .. outer.begin + outer.len]);
    try testing.expect(!left.matched);
    try testing.expectEqual(@as(usize, 0), left.len);
    try testing.expect(right.matched);
    try testing.expectEqualStrings("ab", text[right.begin .. right.begin + right.len]);
}

test "greedy backtracking restores captures from accepted repetition count" {
    var re = try Regex.init(test_alloc, "((a)|(ab))+c", default_opts);
    defer re.deinit();
    const text = "abc";
    var md = (try re.fullmatch(text)).?;
    defer md.deinit();

    const outer = md.subexp(1).?;
    const left = md.subexp(2).?;
    const right = md.subexp(3).?;

    try testing.expectEqualStrings("ab", text[outer.begin .. outer.begin + outer.len]);
    try testing.expect(!left.matched);
    try testing.expectEqual(@as(usize, 0), left.len);
    try testing.expect(right.matched);
    try testing.expectEqualStrings("ab", text[right.begin .. right.begin + right.len]);
}

test "group with quantifier" {
    try expectMatch("(ab)+", "ab", true);
    try expectMatch("(ab)+", "ababab", true);
    try expectMatch("(ab)+", "a", false);
    try expectMatch("(ab)*", "", true);
    try expectMatch("(ab)*", "ab", true);
    try expectMatch("(ab)?c", "c", true);
    try expectMatch("(ab)?c", "abc", true);
    try expectMatch("(ab)?c", "ababc", false);
}

test "\\b and \\B" {
    // basic
    try expectSearch("\\bfoo\\b", "the foo bar", 4, 7);
    try expectNoSearch("\\bfoo\\b", "foobar");
    try expectNoSearch("\\bfoo\\b", "barfoo");

    // \\b at start and end of string
    try expectSearch("\\bfoo", "foo bar", 0, 3);
    try expectSearch("foo\\b", "bar foo", 4, 7);
    try expectSearch("\\bfoo", "!foo", 1, 4);
    try expectNoSearch("\\bfoo", "xfoo");

    // \\b between word and punctuation (C bug fix)"
    try expectSearch("\\bfoo\\b", "!foo!", 1, 4);
    try expectSearch("\\bfoo\\b", ".foo.", 1, 4);
    try expectNoSearch("\\bfoo\\b", "xfooy");

    // \\B non-word-boundary"
    try expectSearch("\\Boo\\B", "foobar", 1, 3);
    try expectNoSearch("\\Bfoo\\B", "foo");
    try expectNoSearch("\\Bfoo\\B", "!foo!");

    // \\b and \\B inside character class are literal b/B"
    try expectMatch("[\\b]", "b", true);
    try expectMatch("[\\b]", "a", false);
    try expectMatch("[\\B]", "B", true);
    try expectMatch("[\\B]", "b", false);
}

//
// scan
//

test "scan multiple non-overlapping matches" {
    var re = try Regex.init(test_alloc, "\\d+", default_opts);
    defer re.deinit();
    var it = re.scan("a1b22c333");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 1, 1);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 3, 2);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 6, 3);
    try testing.expect(try it.next() == null);
    try testing.expect(try it.next() == null);
}

test "scan word tokens" {
    var re = try Regex.init(test_alloc, "\\w+", default_opts);
    defer re.deinit();
    var it = re.scan("hello world");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeText("hello world", r1, "hello");
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeText("hello world", r2, "world");
    try testing.expect(try it.next() == null);
}

test "scan no matches" {
    var re = try Regex.init(test_alloc, "\\d+", default_opts);
    defer re.deinit();
    var it = re.scan("abcdef");
    try testing.expect(try it.next() == null);
}

test "scan single character" {
    var re = try Regex.init(test_alloc, "a", default_opts);
    defer re.deinit();
    var it = re.scan("banana");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 1, 1);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 3, 1);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 5, 1);
    try testing.expect(try it.next() == null);
}

test "scan zero-width matches advance and terminate" {
    var re = try Regex.init(test_alloc, "a*", default_opts);
    defer re.deinit();
    var it = re.scan("bab");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 0);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 1, 1);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 2, 0);
    var r4 = (try it.next()).?;
    defer r4.deinit();
    try expectWholeMatch(r4, 3, 0);
    try testing.expect(try it.next() == null);
}

test "scan anchor ^ matches only at start" {
    var re = try Regex.init(test_alloc, "^foo", default_opts);
    defer re.deinit();
    var it = re.scan("foo foo");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 3);
    try testing.expect(try it.next() == null);
}

test "scan with backtracking pattern" {
    var re = try Regex.init(test_alloc, "a.*b", default_opts);
    defer re.deinit();
    var it = re.scan("xabxab");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 1, 5);
    try testing.expect(try it.next() == null);
}

//
// capturing
//

test "search exposes capture participation" {
    var re = try Regex.init(test_alloc, "(a)?b", default_opts);
    defer re.deinit();
    var md = (try re.match("zb")).?;
    defer md.deinit();
    const whole = md.subexp(0).?;
    const cap = md.subexp(1).?;
    try testing.expect(whole.matched);
    try testing.expect(!cap.matched);
    try testing.expectEqual(@as(usize, 1), whole.begin);
    try testing.expectEqual(@as(usize, 1), whole.len);
}

test "search clears captures between failed start positions" {
    var re = try Regex.init(test_alloc, "(a)?b", default_opts);
    defer re.deinit();
    var md = (try re.match("acb")).?;
    defer md.deinit();
    const whole = md.subexp(0).?;
    const cap = md.subexp(1).?;
    try testing.expectEqual(@as(usize, 2), whole.begin);
    try testing.expectEqual(@as(usize, 1), whole.len);
    try testing.expect(!cap.matched);
    try testing.expectEqual(@as(usize, 0), cap.begin);
    try testing.expectEqual(@as(usize, 0), cap.len);
}

test "scan preserves capture participation per result" {
    var re = try Regex.init(test_alloc, "(a)?", default_opts);
    defer re.deinit();
    var it = re.scan("a");

    var first = (try it.next()).?;
    defer first.deinit();
    try testing.expect(first.subexp(1).?.matched);

    var second = (try it.next()).?;
    defer second.deinit();
    const cap = second.subexp(1).?;
    try testing.expect(!cap.matched);
    try testing.expectEqual(@as(usize, 1), second.subexp(0).?.begin);
    try testing.expectEqual(@as(usize, 0), second.subexp(0).?.len);
}

test "scan clears captures between failed start positions" {
    var re = try Regex.init(test_alloc, "(a)?b", default_opts);
    defer re.deinit();
    var it = re.scan("acb");

    var first = (try it.next()).?;
    defer first.deinit();
    const whole = first.subexp(0).?;
    const cap = first.subexp(1).?;
    try testing.expectEqual(@as(usize, 2), whole.begin);
    try testing.expectEqual(@as(usize, 1), whole.len);
    try testing.expect(!cap.matched);
    try testing.expectEqual(@as(usize, 0), cap.begin);
    try testing.expectEqual(@as(usize, 0), cap.len);
}

test "subexp out of bounds returns null" {
    var re = try Regex.init(test_alloc, "hello", default_opts);
    defer re.deinit();
    var md = (try re.fullmatch("hello")).?;
    defer md.deinit();
    try testing.expect(md.subexp(99) == null);
}

test "errors" {
    // empty class
    try testing.expectError(error.EmptyClass, Regex.init(test_alloc, "[]", default_opts));
    // unexpected char
    try testing.expectError(error.UnexpectedChar, Regex.init(test_alloc, "abc)", default_opts));
    // unclosed paren
    try testing.expectError(error.ExpectedParenthesis, Regex.init(test_alloc, "(foo", default_opts));
    // invalid range [z-a]
    try testing.expectError(error.InvalidRangeNum, Regex.init(test_alloc, "[z-a]", default_opts));
    // range with cclass [\\d-z]
    try testing.expectError(error.InvalidRangeChar, Regex.init(test_alloc, "[\\d-z]", default_opts));
    // bad brace {3x}
    try testing.expectError(error.ExpectedCommaOrBrace, Regex.init(test_alloc, "a{3x}", default_opts));
    // brace without number
    try testing.expectError(error.ExpectedNumber, Regex.init(test_alloc, "a{}", default_opts));
    // unfinished range [a-]
    try testing.expectError(error.UnfinishedRange, Regex.init(test_alloc, "[a-]", default_opts));
    // lazy quantifiers rejected
    try testing.expectError(error.UnexpectedChar, Regex.init(test_alloc, "a*?", default_opts));
    try testing.expectError(error.UnexpectedChar, Regex.init(test_alloc, "a+?", default_opts));
    try testing.expectError(error.UnexpectedChar, Regex.init(test_alloc, "a??", default_opts));
    // malformed non-capturing group (?foo)
    try testing.expectError(error.ExpectedColon, Regex.init(test_alloc, "(?foo)", default_opts));
    // unclosed character class [abc
    try testing.expectError(error.ExpectedBracket, Regex.init(test_alloc, "[abc", default_opts));
    // missing closing brace {3,
    try testing.expectError(error.ExpectedCommaOrBrace, Regex.init(test_alloc, "a{3,", default_opts));
    // descending brace range {3,2}
    try testing.expectError(error.InvalidRangeNum, Regex.init(test_alloc, "a{3,2}", default_opts));
    // numeric overflow in brace bounds
    try testing.expectError(error.NumericOverflow, Regex.init(test_alloc, "a{65536}", default_opts));
    try testing.expectError(error.NumericOverflow, Regex.init(test_alloc, "a{99999}", default_opts));
    // trailing backslash
    try testing.expectError(error.UnexpectedChar, Regex.init(test_alloc, "\\", default_opts));
    try testing.expectError(error.UnexpectedChar, Regex.init(test_alloc, "[\\", default_opts));
    // bare non-printable byte
    try testing.expectError(error.ExpectedLetter, Regex.init(test_alloc, "\x01", default_opts));
}

//
// case-insensitive
//

test "case-insensitive" {
    var re1 = try Regex.init(test_alloc, "hello", ci_opts);
    defer re1.deinit();
    try testing.expect(try didFullmatch(&re1, "hello"));
    try testing.expect(try didFullmatch(&re1, "HELLO"));
    try testing.expect(try didFullmatch(&re1, "HeLLo"));
    try testing.expect(!try didFullmatch(&re1, "world"));

    // character class
    var re2 = try Regex.init(test_alloc, "[a-z]+", ci_opts);
    defer re2.deinit();
    try testing.expect(try didFullmatch(&re2, "hello"));
    try testing.expect(try didFullmatch(&re2, "HELLO"));
    try testing.expect(try didFullmatch(&re2, "HeLLo"));

    // explicit upper range
    var re3 = try Regex.init(test_alloc, "[A-Z]+", ci_opts);
    defer re3.deinit();
    try testing.expect(try didFullmatch(&re3, "hello"));
    try testing.expect(try didFullmatch(&re3, "HELLO"));

    // mixed ASCII range preserves punctuation gap
    var re4 = try Regex.init(test_alloc, "[A-z]", ci_opts);
    defer re4.deinit();
    try testing.expect(try didFullmatch(&re4, "_"));
    try testing.expect(try didFullmatch(&re4, "["));
    try testing.expect(try didFullmatch(&re4, "`"));

    // alternation
    var re5 = try Regex.init(test_alloc, "cat|dog", ci_opts);
    defer re5.deinit();
    try testing.expect(try didFullmatch(&re5, "CAT"));
    try testing.expect(try didFullmatch(&re5, "Dog"));
    try testing.expect(!try didFullmatch(&re5, "bird"));

    // search
    var re6 = try Regex.init(test_alloc, "foo", ci_opts);
    defer re6.deinit();
    var r = (try re6.match("find FOO here")).?;
    defer r.deinit();
    try expectWholeMatch(r, 5, 3);

    // class literal inside brackets
    var re7 = try Regex.init(test_alloc, "[aeiou]+", ci_opts);
    defer re7.deinit();
    try testing.expect(try didFullmatch(&re7, "aeiou"));
    try testing.expect(try didFullmatch(&re7, "AEIOU"));
    try testing.expect(try didFullmatch(&re7, "AeIoU"));
}

//
// misc
//

test "empty pattern" {
    var re = try Regex.init(test_alloc, "", default_opts);
    defer re.deinit();

    try testing.expect(try didFullmatch(&re, ""));
    try testing.expect(!try didFullmatch(&re, "a"));

    var m = (try re.match("abc")).?;
    defer m.deinit();
    try expectWholeMatch(m, 0, 0);

    var it = re.scan("ab");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 0);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 1, 0);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 2, 0);
    try testing.expect(try it.next() == null);
}

test "search zero-width match on empty string" {
    var re = try Regex.init(test_alloc, "^$", default_opts);
    defer re.deinit();
    var r = (try re.match("")).?;
    defer r.deinit();
    try expectWholeMatch(r, 0, 0);
    try testing.expect(try re.match("a") == null);
}

test "search zero-width anchor at boundaries" {
    var re1 = try Regex.init(test_alloc, "^", default_opts);
    defer re1.deinit();
    var r1 = (try re1.match("hello")).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 0);

    var re2 = try Regex.init(test_alloc, "$", default_opts);
    defer re2.deinit();
    var r2 = (try re2.match("hello")).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 5, 0);
}

test "fullmatch subexpCount for plain pattern is 1" {
    var re = try Regex.init(test_alloc, "hello", default_opts);
    defer re.deinit();
    var md = (try re.fullmatch("hello")).?;
    defer md.deinit();
    try testing.expectEqual(@as(usize, 1), md.subexpCount());
}

test "subexp(0) after search gives matched region" {
    var re = try Regex.init(test_alloc, "\\d+", default_opts);
    defer re.deinit();
    const text = "abc123def";
    var md = (try re.match(text)).?;
    defer md.deinit();
    const m = md.subexp(0).?;
    try testing.expect(m.matched);
    try testing.expectEqual(@as(usize, 3), m.begin);
    try testing.expectEqual(@as(usize, 3), m.len);
}

test "empty capture is distinguishable from unmatched capture" {
    var re1 = try Regex.init(test_alloc, "()a", default_opts);
    defer re1.deinit();
    var empty_md = (try re1.fullmatch("a")).?;
    defer empty_md.deinit();
    const empty_cap = empty_md.subexp(1).?;
    try testing.expect(empty_cap.matched);
    try testing.expectEqual(@as(usize, 0), empty_cap.begin);
    try testing.expectEqual(@as(usize, 0), empty_cap.len);

    var re2 = try Regex.init(test_alloc, "(a)?b", default_opts);
    defer re2.deinit();
    var optional_md = (try re2.fullmatch("b")).?;
    defer optional_md.deinit();
    const optional_cap = optional_md.subexp(1).?;
    try testing.expect(!optional_cap.matched);
    try testing.expectEqual(@as(usize, 0), optional_cap.begin);
    try testing.expectEqual(@as(usize, 0), optional_cap.len);
}

test "fullmatch does not leave match state in Regex" {
    var re = try Regex.init(test_alloc, "(\\d+)", default_opts);
    defer re.deinit();
    var m1_data = (try re.fullmatch("123")).?;
    defer m1_data.deinit();
    const m1 = m1_data.subexp(1).?;
    try testing.expectEqualStrings("123", "123"[m1.begin .. m1.begin + m1.len]);
    var m2_data = (try re.fullmatch("456")).?;
    defer m2_data.deinit();
    const m2 = m2_data.subexp(1).?;
    try testing.expectEqual(@as(usize, 0), m2.begin);
    try testing.expectEqual(@as(usize, 3), m2.len);
    try testing.expect(try re.fullmatch("abc") == null);
}

//
// helpers
//

// Compile pattern with default options and assert fullmatch() returns expected.
fn expectMatch(pattern: []const u8, text: []const u8, expected: bool) !void {
    var re = try Regex.init(test_alloc, pattern, default_opts);
    defer re.deinit();
    const got = try didFullmatch(&re, text);
    if (got != expected) {
        std.debug.print("fullmatch(\"{s}\", \"{s}\") = {}, want {}\n", .{ pattern, text, got, expected });
        return error.TestExpectedEqual;
    }
}

// Compile pattern with default options and assert match() finds [exp_begin, exp_end).
fn expectSearch(pattern: []const u8, text: []const u8, exp_begin: usize, exp_end: usize) !void {
    var re = try Regex.init(test_alloc, pattern, default_opts);
    defer re.deinit();
    var r = try re.match(text) orelse {
        std.debug.print("match(\"{s}\", \"{s}\") = null, want [{d},{d})\n", .{ pattern, text, exp_begin, exp_end });
        return error.TestExpectedEqual;
    };
    defer r.deinit();
    try expectWholeMatch(r, exp_begin, exp_end - exp_begin);
}

// Compile pattern with default options and assert match() returns null.
fn expectNoSearch(pattern: []const u8, text: []const u8) !void {
    var re = try Regex.init(test_alloc, pattern, default_opts);
    defer re.deinit();
    if (try re.match(text)) |found| {
        var md = found;
        defer md.deinit();
        std.debug.print("match(\"{s}\", \"{s}\") expected null\n", .{ pattern, text });
        return error.TestExpectedEqual;
    }
}

// Assert subexpression 0 matches the expected region.
fn expectWholeMatch(md: RegexMatchData, begin: usize, len: usize) !void {
    const m = md.subexp(0).?;
    try testing.expect(m.matched);
    try testing.expectEqual(begin, m.begin);
    try testing.expectEqual(len, m.len);
}

// Assert subexpression 0 matches the expected text.
fn expectWholeText(text: []const u8, md: RegexMatchData, expected: []const u8) !void {
    const m = md.subexp(0).?;
    try testing.expectEqualStrings(expected, text[m.begin .. m.begin + m.len]);
}

// Return whether fullmatch() succeeds for the given text.
fn didFullmatch(re: *const Regex, text: []const u8) !bool {
    var md = try re.fullmatch(text) orelse return false;
    md.deinit();
    return true;
}

const std = @import("std");
const test_alloc = testing.allocator;
const testing = std.testing;
