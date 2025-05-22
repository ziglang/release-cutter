const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "build-commit",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .root_source_file = b.path("build-commit.zig"),
            .imports = &.{},
        }),
    });
    b.installArtifact(exe);
}
