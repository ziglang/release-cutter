const std = @import("std");
const Allocator = std.mem.Allocator;

var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const arena = arena_instance.allocator();

pub fn main() !void {
    const env_map = try std.process.getEnvMap(arena);
    const args = try std.process.argsAlloc(arena);

    const www_prefix = args[1]; // example: "/var/www/html";
    const index_json_template_filename = args[1]; // example: "index.json";

    const website_dir = try std.fs.cwd().openDir(".", .{});
    const zig_dir = try std.fs.cwd().openDir("../zig", .{});
    const work_dir = try std.fs.cwd().openDir("../..", .{});
    const bootstrap_dir = try work_dir.openDir("zig-bootstrap", .{});
    const www_dir = try std.fs.cwd().makeOpenPath(www_prefix, .{});
    const builds_dir = try www_dir.makeOpenPath("builds", .{.iterate = true});
    const std_docs_dir = try www_dir.makeOpenPath("documentation/master/std", .{});

    const GITHUB_OUTPUT = env_map.get("GITHUB_OUTPUT").?;
    const github_output = try std.fs.cwd().createFile(GITHUB_OUTPUT, .{});
    defer github_output.close();

    try env_map.put("PATH", "/home/ci/local/bin/:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin");
    try env_map.put("XZ_OPT", "-9");
    try env_map.put("CMAKE_GENERATOR", "Ninja");

    // Override the cache directories because they won't actually help other CI runs
    // which will be testing alternate versions of zig, and ultimately would just
    // fill up space on the hard drive for no reason.
    try env_map.put("ZIG_GLOBAL_CACHE_DIR", try bootstrap_dir.realpathAlloc(arena, "out/zig-global-cache"));
    try env_map.put("ZIG_LOCAL_CACHE_DIR", try bootstrap_dir.realpathAlloc(arena, "out/zig-local-cache"));


    const zig_ver = if (env_map.get("ZIG_RELEASE_TAG")) |ZIG_RELEASE_TAG| v: {
        // Manually triggered workflow.
        try github_output.writeAll("skipped=yes\n"); // Prevent website deploy
        try run(zig_dir, &.{"git", "checkout", ZIG_RELEASE_TAG});
        std.log.info("Building version from tag: {s}", .{ZIG_RELEASE_TAG});
        break :v ZIG_RELEASE_TAG;
    } else v: {
        const GH_TOKEN = env_map.get("GH_TOKEN").?;
        const json_text = try fetch("https://api.github.com/repos/ziglang/zig/actions/runs?branch=master&status=success&per_page=1&event=push", .{
            .{"Accept", "application/vnd.github+json"},
            .{"Authorization", print("Bearer {s}", .{GH_TOKEN})},
        });
        const last_success = pluckDataFromJson(json_text); // ".workflow_runs[0].head_sha"
        try run(zig_dir, &.{"git", "checkout", last_success});
        const zig_ver = try zigVer(arena, zig_dir);
        std.log.info("Last commit with green CI: {s}", .{last_success});
        std.log.info("Zig version: {s}", .{zig_ver});

        const last_tarball = try pluckDataFromJson2(www_dir, "download/index.json", ".master.version");
        std.log.info("Last deployed version: {s}", .{last_tarball});

        if (std.mem.eql(u8, zig_ver, last_tarball)) {
            try github_output.writeAll("skipped=yes\n");
            std.log.info("Versions are equal, nothing to do here.", .{});
            return;
        }
        break :v zig_ver;
    };
    std.log.info("zig version: {s}", .{zig_ver});

    try work_dir.removeTree("tarballs");
    const tarballs_dir = try work_dir.makeOpenPath("tarballs");
    defer tarballs_dir.close();
    const tarballs_zig_dir = try work_dir.makeOpenPath(print("zig-{s}", .{zig_ver}));
    defer tarballs_zig_dir.close();
    try copyTree(zig_dir, tarballs_zig_dir, &.{
        ".github",
        ".gitignore",
        ".gitattributes",
        ".git",
        ".mailmap",
        "ci",
        "build",
        "build-release",
        "build-debug",
        "zig-cache",
    });

    var template_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    try template_map.put("MASTER_VERSION", zig_ver);
    try template_map.put("MASTER_DATE", timestamp());

    const src_tarball_name = print("zig-{s}.tar.xz", .{zig_ver});
    try run(tarballs_dir, &.{
        "tar",
        "cfJ",
        src_tarball_name,
        print("zig-{s}/", .{zig_ver}),
        "--sort=name",
    });
    minisign(tarballs_dir, src_tarball_name, builds_dir);
    try addTemplateEntry(&template_map, "SRC", builds_dir, src_tarball_name);


    try run(&.{bootstrap_dir, "git", "clean", "-fd"});
    try run(&.{bootstrap_dir, "git", "reset", "--hard", "HEAD"});
    try run(&.{bootstrap_dir, "git", "fetch"});

    const branch = env_map.get("ZIG_BOOTSTRAP_BRANCH") orelse "master";
    try run(&.{bootstrap_dir, "git", "checkout", print("origin/{s}", .{branch})});

    {
        try bootstrap_dir.removeTree("zig");
        const bootstrap_zig_dir = try bootstrap_dir.makeOpenPath("zig");
        defer bootstrap_zig_dir.close();
        try copyTree(tarballs_zig_dir, bootstrap_zig_dir, &.{});
    }
    try updateLine(bootstrap_dir, "build", "ZIG_VERSION=", print("ZIG_VERSION=\"{s}\"\n", .{
        zig_ver,
    }));
    try updateLine(bootstrap_dir, "build.bat", "set ZIG_VERSION=", print("set ZIG_VERSION=\"{s}\"\r\n", .{
        zig_ver,
    }));
    try updateLine(bootstrap_dir, "README.md", " * zig ", print(" * zig {s}\n", .{
        zig_ver,
    }));
    try bootstrap_dir.removeTree("out");

    {
        const tarballs_bootstrap_dir = try tarballs_dir.makeOpenPath(print("zig-bootstrap-{s}", .{zig_ver}));
        defer tarballs_bootstrap_dir.close();
        try copyTree(bootstrap_dir, tarballs_bootstrap_dir, &.{
            ".git",
            ".gitattributes",
            ".github",
            ".gitignore",
        });
    }

    const bootstrap_src_tarball_name = print("zig-bootstrap-{s}.tar.xz", .{zig_ver});
    try run(tarballs_dir, &.{
        "tar",
        "cfJ",
        bootstrap_src_tarball_name,
        print("zig-bootstrap-{s}/", .{zig_ver}),
        "--sort=name",
    });
    minisign(tarballs_dir, bootstrap_src_tarball_name, builds_dir);
    try addTemplateEntry(&template_map, "BOOTSTRAP", builds_dir, bootstrap_src_tarball_name);

    const targets = .{
        .{"x86_64-linux-musl", "baseline"},
        .{"x86_64-macos-none", "baseline"},
        .{"aarch64-linux-musl", "baseline"},
        .{"aarch64-macos-none", "apple_a14"},
        .{"riscv64-linux-musl", "baseline"},
        .{"powerpc64le-linux-musl", "baseline"},
        //"powerpc-linux-musl", "baseline"},
        .{"x86-linux-musl", "baseline"},
        .{"x86_64-windows-gnu", "baseline"},
        .{"aarch64-windows-gnu", "baseline"},
        .{"x86-windows-gnu", "baseline"},
        .{"arm-linux-musleabihf", "baseline"},
        .{"loongarch64-linux-musl", "baseline"},
    };

    const zig_exe = try bootstrap_dir.realpathAlloc(arena, "out/host/bin/zig");

    for (targets) |target| {
        // NOTE: Debian's cmake (3.18.4) is too old for zig-bootstrap.
        try run(bootstrap_dir, &.{"./build", target.triple, target.mcpu});
    }

    // Delete builds older than 30 days so the server does not run out of disk space.
    deleteOld(builds_dir);

    for (targets) |target| {
        // Copy not rename so that next run of this script has partially cached results.
        copy(bootstrap_dir, target, tarballs_dir, zig_ver);

        const tarball_filename = if (target.isWindows()) t: {
            const tarball_filename = print("zig-{s}-{s}.zip", .{target.tarball_name, zig_ver});
            try run(tarballs_dir, &.{
                "7z",
                "a",
                tarball_filename,
                print("zig-{s}-{s}/", .{target.tarball_name, zig_ver}),
            });
            break :t tarball_filename;
        } else t: {
            const tarball_filename = print("zig-{s}-{s}.tar.xz", .{target.tarball_name, zig_ver});
            try run(tarballs_dir, &.{
                "tar",
                "cfJ",
                tarball_filename,
                print("zig-{s}-{s}/", .{target.tarball_name, zig_ver}),
                "--sort=name",
            });
            break :t tarball_filename;
        };
        minisign(tarballs_dir, tarball_filename, builds_dir);
        try addTemplateEntry(&template_map, target.tarball_name, builds_dir, tarball_filename);
    }

    const index_json_basename = print("zig-{s}-index.json", .{zig_ver});
    try render(&template_map, index_json_template_filename, tarballs_dir, index_json_basename, .plain);
    minisign(tarballs_dir, index_json_basename, builds_dir);

    try updateWebsiteRepo(builds_dir, index_json_basename, website_dir, "assets/download/index.json");

    // Update autodocs and langref directly to prevent the www.ziglang.org git
    // repo from growing too big.
    try targets[0].dir.copyFile("doc/langref.html", www_dir, "documentation/master/index.html");

    // Standard library autodocs are intentionally excluded from tarballs of
    // Zig but we want to host them on the website.
    try run(bootstrap_dir, &.{zig_exe, "build-obj", "-fno-emit-bin", "-femit-docs=std", "zig/lib/std/std.zig" });

    try gzipCopy(bootstrap_dir, "std/index.html", std_docs_dir);
    try gzipCopy(bootstrap_dir, "std/main.js", std_docs_dir);
    try gzipCopy(bootstrap_dir, "std/main.wasm", std_docs_dir);
    try gzipCopy(bootstrap_dir, "std/sources.tar", std_docs_dir);
}

fn zigVer(arena: Allocator, dir: std.fs.Dir) !void {
    // Make the `zig version` number consistent.
    // This will affect the "git describe" command below.
    try run(dir, &.{"git", "config", "core.abbrev", "9"});
    run(dir, &.{"git", "fetch", "--unshallow"}) catch {};
    try run(dir, &.{"git", "fetch", "--tags"});

    const build_zig_contents = try dir.readFileAlloc(arena, "build.zig", 100 * 1024);
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
        .dir = dir,
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

    const version_string = try print("{d}.{d}.{d}", .{
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
            return version_string;
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
            return print("{s}-dev.{s}+{s}", .{
                version_string, commit_height, commit_id[1..],
            });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            std.process.exit(1);
        },
    }
}


fn run(dir: std.fs.Dir, argv: []const []const u8) !void {

}

fn fetch(url: []const u8, headers: []const std.http.Header) ![]u8 {
}

fn pluckDataFromJson(json_text: []const u8) []u8 {
}

fn pluckDataFromJson2(file_path: []const u8) []u8 {
}

fn print(comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch @panic("OOM");
}

fn copyTree(src_dir: std.fs.Dir, dest_dir: std.fs.Dir, exclude: []const []const u8) !void {
}

fn updateLine(dir: std.fs.Dir, file_path: []const u8, prefix: []const u8, replacement: []const u8) !void {
}

fn minisign(src_dir: std.fs.Dir, basename: []const u8, dest_dir: std.fs.Dir) void {
    // also move into the dest dir
}

fn copy(bootstrap_dir: void, target: void, tarballs_dir: void, zig_ver: void) void {}

fn deleteOld(builds_dir: std.fs.Dir) void {
    //find $WWW_PREFIX/builds/* -ctime +30 -exec rm -rf {} \;
}


fn addTemplateEntry(map: *void, name: []const u8, dir: std.fs.Dir, tarball_basename: []const u8) !void {
    const file = try dir.openFile(tarball_basename, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const digest = try sha256sum(file, size);
    try map.put(arena, print("{s}_TARBALL", .{name}), tarball_basename);
    try map.put(arena, print("{s}_SHASUM", .{name}), print("{}", .{std.fmt.fmtSliceHexLower(&digest)}));
    try map.put(arena, print("{s}_BYTESIZE", .{name}), print("{d}", .{size}));
}

fn timestamp() []const u8 {
    //export MASTER_DATE="$(date +%Y-%m-%d)"
}

fn render(
    in_file: []const u8,
    out_file: []const u8,
    fmt: enum {
        html,
        plain,
    },
) !void {
    const in_contents = try std.fs.cwd().readFileAlloc(arena, in_file, 1 * 1024 * 1024);

    var buffer = std.ArrayList(u8).init(arena);
    defer buffer.deinit();

    const State = enum {
        Start,
        OpenBrace,
        VarName,
        EndBrace,
    };
    const writer = buffer.writer();
    var state = State.Start;
    var var_name_start: usize = undefined;
    var line: usize = 1;
    for (in_contents, 0..) |byte, index| {
        switch (state) {
            State.Start => switch (byte) {
                '{' => {
                    state = State.OpenBrace;
                },
                else => try writer.writeByte(byte),
            },
            State.OpenBrace => switch (byte) {
                '{' => {
                    state = State.VarName;
                    var_name_start = index + 1;
                },
                else => {
                    try writer.writeByte('{');
                    try writer.writeByte(byte);
                    state = State.Start;
                },
            },
            State.VarName => switch (byte) {
                '}' => {
                    const var_name = in_contents[var_name_start..index];
                    if (vars.get(var_name)) |value| {
                        const trimmed = mem.trim(u8, value, " \r\n");
                        if (fmt == .html and mem.endsWith(u8, var_name, "BYTESIZE")) {
                            const size = try std.fmt.parseInt(u64, trimmed, 10);
                            try writer.print("{:.1}", .{std.fmt.fmtIntSizeDec(size)});
                        } else {
                            try writer.writeAll(trimmed);
                        }
                    } else {
                        std.debug.print("line {d}: missing variable: {s}\n", .{ line, var_name });
                        try writer.writeAll("(missing)");
                    }
                    state = State.EndBrace;
                },
                else => {},
            },
            State.EndBrace => switch (byte) {
                '}' => {
                    state = State.Start;
                },
                else => {
                    std.debug.print("line {d}: invalid byte: '0x{x}'", .{ line, byte });
                    std.process.exit(1);
                },
            },
        }
        if (byte == '\n') {
            line += 1;
        }
    }
    if (new_writefile_api) {
        try std.fs.cwd().writeFile(.{ .sub_path = out_file, .data = buffer.items });
    } else {
        try std.fs.cwd().writeFile(out_file, buffer.items);
    }
}

fn updateWebsiteRepo(builds_dir: std.fs.Dir, index_json_basename: []const u8, website_dir: std.fs.Dir, assets_json_path: []const u8,) !void {
    try builds_dir.copyFile(index_json_basename, website_dir, assets_json_path);

    try run(website_dir, &.{"git", "config", "user.email", "ziggy@ziglang.org"});
    try run(website_dir, &.{"git", "config", "user.name", "Ziggy"});
    try run(website_dir, &.{"git", "add", "assets/download/index.json", "Ziggy"});
    try run(website_dir, &.{"git", "commit", "-m", "CI: update master branch builds"});
    try run(website_dir, &.{"git", "push"});
}

fn gzipCopy() void {
    // gzip -c -9 "$DOCDIR/std/main.js"     > "$DOCDIR/std/main.js.gz"
    // mv "$DOCDIR/std/index.html.gz"  "$WWW_PREFIX/documentation/master/std/index.html.gz"
}

