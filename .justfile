# Required for codex shell sessions where mise PATH hooks may not be active.
export PATH := env("HOME") + "/.local/share/mise/installs/zig/0.15.2/bin:" + env("PATH")

default:
  just --list

clean:
  rm -rf zig-out .zig-cache

fmt:
  zig fmt *.zig
  just banner "✓ fmt "

test:
  zig fmt --check *.zig
  zig build test --summary all
  just banner "✓ test"

test-watch:
  watchexec --clear=clear --stop-timeout=0 just test

set quiet

_FG := '\e[38;5;231m'
_BG := '\e[48;2;064;160;043m'
banner +ARGS:
  printf '{{BOLD+_BG+_FG}}[%s] %-72s {{NORMAL}}\n' "$(date +%H:%M:%S)" "{{ARGS}}"
