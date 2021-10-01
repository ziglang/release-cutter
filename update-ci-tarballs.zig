const std = @import("std");
const fs = std.fs;

const usage =
    \\Usage: update-ci-tarballs <path/to/zig-bootstrap>
    \\
    \\Before running this script, you must have already run the
    \\./build script from zig-bootstrap on all the targets
    \\that are listed in the source file of this executable
    \\using the "baseline" CPU feature set.
    \\
    \\For targets that zig-bootstrap cannot cross compile, such as
    \\freebsd and netbsd, you must have done it on another computer
    \\and rsync'd the directories into place as if you had done
    \\it on this computer.
    \\
;

fn dumpUsageAndExit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}

const triples = [_][]const u8{
    "x86_64-windows-gnu",
    "x86_64-macos-gnu",
    "x86_64-linux-musl",
    "x86_64-freebsd-gnu",
    "x86_64-netbsd-gnu",
    "aarch64-macos-gnu",
    "aarch64-linux-musl",
};

pub fn main() !void {
    var progress = std.Progress{};
    const root_node = try progress.start("", triples.len);
    defer root_node.end();

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = &arena_allocator.allocator;

    const args = try std.process.argsAlloc(arena);

    if (args.len < 2) dumpUsageAndExit();

    const zig_bootstrap_path = args[1];
    const host_zig_path = try fs.path.join(arena, &.{
        zig_bootstrap_path, "out", "host", "bin", "zig",
    });
    const zig_version_unchomped = try exec(arena, &.{ host_zig_path, "version" });
    const zig_version = std.mem.trimRight(u8, zig_version_unchomped, " \n\r\t");

    var out_dir = try fs.cwd().makeOpenPath("out", .{});
    defer out_dir.close();

    for (triples) |triple| {
        var triple_prog_node = root_node.start(triple, 4);
        triple_prog_node.activate();
        defer triple_prog_node.end();

        const llvm_prefix = try std.fmt.allocPrint(arena, "{s}-baseline", .{triple});
        const zig_prefix = try std.fmt.allocPrint(arena, "zig-{s}-baseline", .{triple});
        const llvm_src_path = try fs.path.join(arena, &.{
            zig_bootstrap_path, "out", llvm_prefix,
        });
        const llvm_src_path_slash = try std.fmt.allocPrint(arena, "{s}/", .{llvm_src_path});
        const zig_src_path = try fs.path.join(arena, &.{
            zig_bootstrap_path, "out", zig_prefix,
        });
        const zig_src_path_slash = try std.fmt.allocPrint(arena, "{s}/", .{zig_src_path});
        const tarball_basename = try std.fmt.allocPrint(arena, "zig+llvm+lld+clang-{s}-{s}", .{
            triple, zig_version,
        });
        const out_prefix = try fs.path.join(arena, &.{ "out", tarball_basename });
        const out_prefix_slash = try std.fmt.allocPrint(arena, "{s}/", .{out_prefix});

        var rsync_prog_node = triple_prog_node.start("llvm files", 0);
        rsync_prog_node.activate();
        _ = try exec(arena, &.{ "rsync", "-avzu", llvm_src_path_slash, out_prefix_slash });
        rsync_prog_node.end();

        rsync_prog_node = triple_prog_node.start("zig files", 0);
        rsync_prog_node.activate();
        _ = try exec(arena, &.{ "rsync", "-avzu", zig_src_path_slash, out_prefix_slash });
        rsync_prog_node.end();

        rsync_prog_node = triple_prog_node.start("delete trash", 0);
        rsync_prog_node.activate();
        for (bin_files_to_delete) |basename| {
            const path_bare = try fs.path.join(arena, &.{ out_prefix, "bin", basename });
            fs.cwd().deleteFile(path_bare) catch continue;
            const path_with_exe = try std.fmt.allocPrint(arena, "{s}.exe", .{path_bare});
            fs.cwd().deleteFile(path_with_exe) catch continue;
        }
        rsync_prog_node.end();

        rsync_prog_node = triple_prog_node.start("create tarball", 0);
        rsync_prog_node.activate();
        const tar_xz_path = try std.fmt.allocPrint(arena, "{s}.tar.xz", .{tarball_basename});
        const tarball_basename_slash = try std.fmt.allocPrint(arena, "{s}/", .{tarball_basename});
        _ = try execCwd(arena, &.{ "tar", "cJf", tar_xz_path, tarball_basename_slash }, out_dir);
        rsync_prog_node.end();
    }
}

const bin_files_to_delete = [_][]const u8{
    "ld64.lld",
    "ld64.lld.darwinnew",
    "ld64.lld.darwinold",
    "ld.lld",
    "lld",
    "lld-link",
    "wasm-ld",
};

fn exec(arena: *std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return execCwd(arena, argv, null);
}

fn execCwd(arena: *std.mem.Allocator, argv: []const []const u8, cwd: ?fs.Dir) ![]const u8 {
    const child = try std.ChildProcess.init(argv, arena);
    defer child.deinit();

    child.cwd_dir = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const stdout_reader = child.stdout.?.reader();
    const stdout = try stdout_reader.readAllAlloc(arena, 10 * 1024 * 1024);

    switch (try child.wait()) {
        .Exited => |code| if (code == 0) return stdout else {
            std.debug.warn("{s} exited with code {d}\n", .{ argv[0], code });
            std.process.exit(1);
        },
        else => {
            std.debug.warn("{s} crashed\n", .{argv[0]});
            std.process.exit(1);
        },
    }
}
