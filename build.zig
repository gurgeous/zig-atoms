const std = @import("std");

pub fn build(b: *std.Build) void {
    // options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // gather atoms for tests
    const test_step = b.step("test", "Run tests");
    const atoms = discoverAtoms(b) catch @panic("couldn't discoverAtoms");
    for (atoms.items) |atom| {
        // build atom
        const name = std.fs.path.stem(atom);
        const mod = b.addModule(name, .{
            .root_source_file = b.path(atom),
            .target = target,
            .optimize = optimize,
        });

        // test atom
        const atom_tests = b.addTest(.{ .name = atom, .root_module = mod });
        const atom_test_run = b.addRunArtifact(atom_tests);
        test_step.dependOn(&atom_test_run.step);
    }
}

//
// atom discovery
//

fn discoverAtoms(b: *std.Build) !std.ArrayList([]const u8) {
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    var atoms: std.ArrayList([]const u8) = .empty;
    errdefer atoms.deinit(b.allocator);

    // gather sorted list of atoms
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!isAtomFile(entry.name)) continue;
        try atoms.append(b.allocator, try b.allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, atoms.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);

    // warn on missing tests
    for (atoms.items) |atom| {
        if (!(try hasTests(b.allocator, atom))) {
            std.debug.print("❌ {s} has zero tests?\n", .{atom});
        }
    }

    return atoms;
}

// Return true if this filename is one of our atoms
fn isAtomFile(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".zig")) return false;
    if (std.mem.eql(u8, name, "build.zig")) return false;
    return true;
}

// Return true if the file has at least one `test`.
fn hasTests(alloc: std.mem.Allocator, atom: []const u8) !bool {
    const contents = try std.fs.cwd().readFileAlloc(alloc, atom, std.math.maxInt(usize));
    defer alloc.free(contents);
    return std.mem.indexOf(u8, contents, "\ntest \"") != null;
}
