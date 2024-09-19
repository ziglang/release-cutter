const std = @import("std");
const fs = std.fs;

const usage =
    \\Usage: update-ci-tarballs <path/to/zig-bootstrap>
    \\
    \\Before running this script, you must have already run the
    \\./build script from zig-bootstrap on all the targets
    \\that are listed in the source file of this executable
    \\using the corresponding mcpu setting.
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

const Tarball = struct {
    triple: []const u8,
    mcpu: []const u8,
    dest: Destination,
};

const Destination = enum {
    // ssh to ziggy.ziglang.org and zanic.ziglang.org
    self_x86,
    // ssh to zero.ziglang.org
    self_arm,
    // ember.ziglang.org https://ziglang.org/deps/*
    www_deps,
};

const tarballs = [_]Tarball{
    .{ .triple = "aarch64-windows-gnu", .mcpu = "baseline", .dest = .www_deps },
    .{ .triple = "x86_64-windows-gnu", .mcpu = "baseline", .dest = .www_deps },
    .{ .triple = "x86_64-macos-none", .mcpu = "baseline", .dest = .www_deps },
    .{ .triple = "x86_64-linux-musl", .mcpu = "baseline", .dest = .self_x86 },
    .{ .triple = "aarch64-macos-none", .mcpu = "apple_a14", .dest = .www_deps },
    .{ .triple = "aarch64-linux-musl", .mcpu = "baseline", .dest = .self_arm },
};

pub fn main() !void {
    const root_node = std.Progress.start(.{
        .estimated_total_items = tarballs.len,
    });
    defer root_node.end();

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_allocator.allocator();

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

    for (tarballs) |tarball| {
        const triple = tarball.triple;

        const triple_prog_node = root_node.start(triple, 4);
        defer triple_prog_node.end();

        const is_windows = std.mem.indexOf(u8, triple, "windows") != null;
        const zig_exe_basename = if (is_windows) "zig.exe" else "zig";

        const llvm_prefix = try std.fmt.allocPrint(arena, "{s}-{s}", .{ triple, tarball.mcpu });
        const zig_prefix = try std.fmt.allocPrint(arena, "zig-{s}-{s}", .{ triple, tarball.mcpu });
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

        var rsync_prog_node = triple_prog_node.start("zig files", 0);
        _ = try exec(arena, &.{ "rsync", "-avu", zig_src_path_slash, out_prefix_slash });
        {
            var tarball_dir = try out_dir.openDir(tarball_basename, .{});
            defer tarball_dir.close();
            try tarball_dir.deleteTree("doc");
            tarball_dir.deleteFile("LICENSE") catch {};
            tarball_dir.deleteFile("README.md") catch {};
            {
                try tarball_dir.makeDir("bin");
                const bin_zig_exe_path = try fs.path.join(arena, &.{ "bin", zig_exe_basename });
                try tarball_dir.rename(zig_exe_basename, bin_zig_exe_path);
            }
            {
                const old_lib_path = try fs.path.join(arena, &.{"lib"});
                const tmp_lib_path = try fs.path.join(arena, &.{"lib_tmp"});
                const new_lib_path = try fs.path.join(arena, &.{ "lib", "zig" });
                try tarball_dir.rename(old_lib_path, tmp_lib_path);
                try tarball_dir.makeDir("lib");
                try tarball_dir.rename(tmp_lib_path, new_lib_path);
            }
        }
        rsync_prog_node.end();

        rsync_prog_node = triple_prog_node.start("llvm files", 0);
        _ = try exec(arena, &.{ "rsync", "-avu", llvm_src_path_slash, out_prefix_slash });
        rsync_prog_node.end();

        rsync_prog_node = triple_prog_node.start("delete trash", 0);
        for (bin_files_to_delete) |basename| {
            const path_bare = try fs.path.join(arena, &.{ out_prefix, "bin", basename });
            fs.cwd().deleteFile(path_bare) catch {};
            const path_with_exe = try std.fmt.allocPrint(arena, "{s}.exe", .{path_bare});
            fs.cwd().deleteFile(path_with_exe) catch {};
        }
        rsync_prog_node.end();

        const tarball_path = if (is_windows) tarball: {
            {
                rsync_prog_node = triple_prog_node.start("rename static libs", 0);
                var lib_dir = try out_dir.openDir(
                    try fs.path.join(arena, &.{ tarball_basename, "lib" }),
                    .{ .iterate = true },
                );
                defer lib_dir.close();
                var it = lib_dir.iterate();
                while (try it.next()) |entry| {
                    if (!std.mem.startsWith(u8, entry.name, "lib")) continue;
                    if (!std.mem.endsWith(u8, entry.name, ".a")) continue;

                    const stripped_name = entry.name[3 .. entry.name.len - 2];
                    const new_name = try std.fmt.allocPrint(arena, "{s}.lib", .{stripped_name});
                    try lib_dir.rename(entry.name, new_name);
                }
                rsync_prog_node.end();
            }

            rsync_prog_node = triple_prog_node.start("create zipfile", 0);
            const zip_path = try std.fmt.allocPrint(arena, "{s}.zip", .{tarball_basename});
            const zipfile_basename_slash = try std.fmt.allocPrint(arena, "{s}/", .{tarball_basename});
            _ = try execCwd(arena, &.{ "7z", "a", zip_path, zipfile_basename_slash }, out_dir);
            rsync_prog_node.end();

            break :tarball zip_path;
        } else tarball: {
            rsync_prog_node = triple_prog_node.start("create tarball", 0);
            const tar_xz_path = try std.fmt.allocPrint(arena, "{s}.tar.xz", .{tarball_basename});
            const tarball_basename_slash = try std.fmt.allocPrint(arena, "{s}/", .{tarball_basename});
            _ = try execCwd(arena, &.{ "tar", "cJf", tar_xz_path, tarball_basename_slash }, out_dir);
            rsync_prog_node.end();

            break :tarball tar_xz_path;
        };

        switch (tarball.dest) {
            .self_x86 => {
                std.debug.print("scp \"{s}\" ci@ziggy.ziglang.org:deps/\n", .{tarball_path});
                std.debug.print("scp \"{s}\" ci@zanic.ziglang.org:deps/\n", .{tarball_path});
            },
            .self_arm => {
                std.debug.print("scp \"{s}\" ci@zero.ziglang.org:deps/\n", .{tarball_path});
            },
            .www_deps => {
                std.debug.print("scp \"{s}\" ci@ember.ziglang.org:/var/www/html/deps/\n", .{tarball_path});
            },
        }
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
    "analyze-build",
    "clang++",
    "clang-cl",
    "clang-cpp",
    "git-clang-format",
    "hmaptool",
    "intercept-build",
    "scan-build",
    "scan-build-py",
    "scan-build.bat",
};

fn exec(arena: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return execCwd(arena, argv, null);
}

fn execCwd(arena: std.mem.Allocator, argv: []const []const u8, cwd: ?fs.Dir) ![]const u8 {
    var child = std.process.Child.init(argv, arena);

    child.cwd_dir = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const stdout_reader = child.stdout.?.reader();
    const stdout = try stdout_reader.readAllAlloc(arena, 10 * 1024 * 1024);

    switch (try child.wait()) {
        .Exited => |code| if (code == 0) return stdout else {
            std.debug.print("{s} exited with code {d}\n", .{ argv[0], code });
            std.process.exit(1);
        },
        else => {
            std.debug.print("{s} crashed\n", .{argv[0]});
            std.process.exit(1);
        },
    }
}
