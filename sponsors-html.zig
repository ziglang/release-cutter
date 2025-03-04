const std = @import("std");

pub const log_level: std.log.Level = .warn;

const usage =
    \\Usage: sponsors-html <tool>
    \\
    \\Available tools:
    \\  homepage    generate the sponsors section for the homepage
    \\  release     generate the sponsors section for releases
    \\
;

const Tier = struct {
    id: []const u8,
    homepage: Mention,
    release: Mention,
    amt: u32,
};

const Mention = enum { none, name, hyperlink };

/// Manually sorted descending by amount.
const tiers = [_]Tier{
    .{
        .id = "ST_kwHOAarWdc3EaQ",
        .homepage = .hyperlink,
        .release = .hyperlink,
        .amt = 5000,
    },
    .{
        .id = "ST_kwHOAarWdc3DXg",
        .homepage = .hyperlink,
        .release = .hyperlink,
        .amt = 1200,
    },
    .{
        .id = "ST_kwHOAarWdc2FHQ",
        .homepage = .hyperlink,
        .release = .hyperlink,
        .amt = 400,
    },
    .{
        .id = "ST_kwHOAarWdc2FGw",
        .homepage = .name,
        .release = .hyperlink,
        .amt = 200,
    },
    .{
        .id = "ST_kwHOAarWdc2FFg",
        .homepage = .none,
        .release = .hyperlink,
        .amt = 100,
    },
    .{
        .id = "ST_kwHOAarWdc2FFw",
        .homepage = .none,
        .release = .name,
        .amt = 50,
    },
};

fn dumpUsageAndExit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}

pub fn main() !void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_allocator.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len < 2) dumpUsageAndExit();

    const Tool = enum { homepage, release };
    const tool = std.meta.stringToEnum(Tool, args[1]) orelse dumpUsageAndExit();

    var dir = try std.fs.cwd().openDir("tiers-data", .{});

    const stdout_file = std.io.getStdOut();
    const unbuffered_stdout = stdout_file.writer();
    var bw = std.io.bufferedWriter(unbuffered_stdout);
    const stdout = bw.writer();

    for (tiers) |tier| {
        const basename = try std.fmt.allocPrint(arena, "{s}.json", .{tier.id});
        std.log.debug("looking at {s}", .{basename});
        const json_text = try dir.readFileAlloc(arena, basename, 10 * 1024 * 1024);
        const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});

        const data_obj = &tree.object.get("data").?.object;
        const sponsors_obj = &data_obj.get("organization").?.object.get("sponsors").?.object;
        const nodes_array = &sponsors_obj.get("nodes").?.array;
        for (nodes_array.items) |node| {
            const skip = switch (tool) {
                .homepage => tier.homepage == .none,
                .release => tier.release == .none,
            };
            if (skip) continue;

            const name = name: {
                if (node.object.get("name")) |n| switch (n) {
                    .string => |s| break :name s,
                    else => {},
                };
                break :name node.object.get("login").?.string;
            };
            const need_website = switch (tool) {
                .homepage => tier.homepage == .hyperlink,
                .release => tier.release == .hyperlink,
            };
            var website: ?[]const u8 = null;
            if (need_website) website: {
                if (node.object.get("websiteUrl")) |n| switch (n) {
                    .string => |s| {
                        website = s;
                        break :website;
                    },
                    else => {},
                };
                if (node.object.get("twitterUsername")) |n| switch (n) {
                    .string => |s| {
                        website = try std.fmt.allocPrint(arena, "https://twitter.com/{s}", .{s});
                        break :website;
                    },
                    else => {},
                };
                const login = node.object.get("login").?.string;
                website = try std.fmt.allocPrint(arena, "https://github.com/{s}", .{login});
            }

            switch (tool) {
                .homepage => {
                    const escaped_name = try escapeHtml(arena, name);
                    if (website) |w| {
                        const escaped_w = try escapeHtml(arena, w);
                        try stdout.print(
                            \\<li><a href="{s}" rel="nofollow noopener" target="_blank" class="external-link">{s}</a></li>
                            \\
                        , .{
                            escaped_w, escaped_name,
                        });
                    } else {
                        try stdout.print("<li>{s}</li>\n", .{escaped_name});
                    }
                },
                .release => {
                    const escaped_name = try escapeHtml(arena, name);
                    if (website) |w| {
                        const escaped_w = try escapeHtml(arena, w);
                        try stdout.print("<li><a href=\"{s}\">{s}</a></li>\n", .{
                            escaped_w, escaped_name,
                        });
                    } else {
                        try stdout.print("<li>{s}</li>\n", .{escaped_name});
                    }
                },
            }
        }
    }

    try bw.flush();
}

fn escapeHtml(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    return arena.dupe(u8, text);
}
