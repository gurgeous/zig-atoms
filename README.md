[![test](https://github.com/gurgeous/zig-atoms/actions/workflows/ci.yml/badge.svg)](https://github.com/gurgeous/zig-atoms/actions/workflows/ci.yml)

<img src="./logo.svg" width="60%">
  
# Zig Atoms
  
Zig Atoms is a collection of high quality, single-file libraries that can be dropped into any Zig project. The Zig stdlib is small by design and these atoms can help bridge the gap. Atoms must follow several rules:

- Must be broadly useful
- Small and single-purpose, no frameworks
- Single file, no dependencies other than std

### List of Atoms

- **[csv_read.zig](./csv_read.zig)** - Fast CSV reader. Supports delimiter sniffing
- **[natsort.zig](./natsort.zig)** - Natural/human string sorting, for mixed text and numbers
- **[regex.zig](./regex.zig)** - Regex library, ascii only. Subset of PCRE, no lookahead, only greedy
- **[sprintf.zig](./sprintf.zig)** - Sprintf-style formatting at runtime
- **[termbg.zig](./termbg.zig)** - Terminal background color detection, dark vs light
- **[unicode.zig](./unicode.zig)** - Best-effort displayWidth() and truncate(). For common cases like emojis

Copy the .zig file into your project and use it directly. Atoms are maintained but not versioned. Have fun!

### Mini Demo

```zig
// csv_read - parse a CSV file or buffer, also see sniffDelimiter
const csv = try csv_read.read(alloc, file.reader(), ',');
const first_row = csv.row(0);

// natsort - sort strings the way humans expect
std.mem.sortUnstable([]const u8, files, {}, struct {
    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return natsort.natsort(a, b) == .lt;
    }
}.lessThan);

// regex - match, scan, capture, etc
var re = try regex.Regex.init(alloc, "(cat|d\\w+g)\\b", .{});
const md = (try re.match("hotdog")) orelse unreachable;
const animal = md.subexp(1).?;

// sprintf - format with runtime width and padding using sprintf syntax
const msg = try sprintf.sprintf(alloc, "%08b %-5s", .{ 13, ">" });

// termbg - detect whether the terminal background is dark
const dark = try termbg.isDark(alloc);

// unicode - best-effort display width and truncation for common cases
const width = unicode.displayWidth("A👍B");
try unicode.truncate(&writer, "Hello 👍 world", 8);
```

### Changelog

- Mar 2026 - initial release

### License

Atoms use the MIT license unless otherwise specified. Individual atoms that are
derived from prior work use the original license and provide attribution.

### Contributing

Want to add a new atom? Great! Zig could use more libraries like this. Just make sure you follow the spirit of the project. Check out existing atoms for hints, read the rules at the top, and use AGENTS.md for guidance.

We use [`mise`](https://mise.jdx.dev/) and [`just`](https://just.systems/). To run tests:

```sh
$ mise trust && mise install
$ just test
```
