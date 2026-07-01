const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const erlang_root = b.option([]const u8, "erlang-root",
        "Erlang root directory") orelse "/home/stax/.local/share/mise/installs/erlang/28.5";

    const nif_mod = b.createModule(.{
        .root_source_file = b.path("nif.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zkdb_nif",
        .root_module = nif_mod,
        .linkage = .dynamic,
    });
    nif_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ erlang_root, "usr/include" }) });
    nif_mod.link_libc = true;
    b.installArtifact(lib);
}
