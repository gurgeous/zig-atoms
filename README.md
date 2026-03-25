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
