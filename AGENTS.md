`zig-atoms` is a collection of standalone Zig libraries.

## Toolchain

- Prefer `just` recipes. Run `just test` after changes.

## Atom Rules

- One atom per file
- Filenames should be literal and self-evident, use snake_case if necessary
- Zig std is fine; no other deps
- Atoms should be general purpose and easy to drop into any project

## Style

- Keep files and APIs small and direct.
- Prefer straightforward over clever
- Each atom starts with a top-level `///` doc comment.
- Add one-line comment to each public struct and fn
- Add one-line comment to every non-trivial struct and fn
- Keep imports grouped at the bottom of the file.
- If a file has tests, include a `testing` section marker.
- Keep attribution and license when an atom is derived from prior work.
