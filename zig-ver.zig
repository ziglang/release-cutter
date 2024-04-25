const std = @import("std");
const mem = std.mem;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const build_zig_contents = try std.fs.cwd().readFileAlloc(arena, "build.zig", 100 * 1024);
    const zig_version = v: {
        var line_it = mem.tokenize(u8, build_zig_contents, "\r\n");
        while (line_it.next()) |line| {
            if (mem.startsWith(u8, line, "const zig_version: std.SemanticVersion = ")) {
                var it = mem.tokenize(u8, line, " =.{,");
                var ver: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };
                while (it.next()) |token| {
                    if (mem.eql(u8, token, "major")) {
                        ver.major = try std.fmt.parseInt(u32, it.next().?, 0);
                    } else if (mem.eql(u8, token, "minor")) {
                        ver.minor = try std.fmt.parseInt(u32, it.next().?, 0);
                    } else if (mem.eql(u8, token, "patch")) {
                        ver.patch = try std.fmt.parseInt(u32, it.next().?, 0);
                    }
                }
                break :v ver;
            }
        }
        std.debug.print("unable to find zig version in build.zig\n", .{});
        std.process.exit(1);
    };

    const result = try std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "git", "describe", "--match", "*.*.*", "--tags" },
    });

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("{s}", .{result.stderr});
                std.process.exit(code);
            }
        },
        .Signal, .Stopped, .Unknown => {
            std.debug.print("{s}", .{result.stderr});
            std.process.exit(1);
        },
    }

    const git_describe = mem.trim(u8, result.stdout, " \n\r");

    const version_string = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{
        zig_version.major, zig_version.minor, zig_version.patch,
    });

    switch (mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            if (!mem.eql(u8, git_describe, version_string)) {
                std.debug.print("Zig version '{s}' does not match Git tag '{s}'\n", .{
                    version_string, git_describe,
                });
                std.process.exit(1);
            }
            try std.io.getStdOut().writer().print("{s}\n", .{version_string});
            std.process.exit(0);
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = mem.split(u8, git_describe, "-");
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
            if (zig_version.order(ancestor_ver) != .gt) {
                std.debug.print("Zig version '{}' must be greater than tagged ancestor '{}'\n", .{ zig_version, ancestor_ver });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                std.process.exit(1);
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            try std.io.getStdOut().writer().print("{s}-dev.{s}+{s}\n", .{
                version_string, commit_height, commit_id[1..],
            });
            std.process.exit(0);
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            std.process.exit(1);
        },
    }
}
