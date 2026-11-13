const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // Erlang root: -Derlang-root=<path>, else ask the `erl` on PATH.
    const erlang_root = b.option([]const u8, "erlang-root", "Erlang root directory (default: from `erl` on PATH)") orelse
        b.run(&.{ "erl", "-noshell", "-eval", "io:format(\"~s\", [code:root_dir()])", "-s", "init", "stop" });

    const nif_mod = b.createModule(.{
        .root_source_file = b.path("nif.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nif_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ erlang_root, "usr/include" }) });

    const lib = b.addLibrary(.{
        .name = "zkdb_nif",
        .root_module = nif_mod,
        .linkage = .dynamic,
    });
    // enif_* symbols are resolved by the BEAM at load time (needed on macOS).
    lib.linker_allow_shlib_undefined = true;
    b.installArtifact(lib);
}
