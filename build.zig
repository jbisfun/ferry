//! Ferry build graph.
//!
//! Every library under lib/ is its own Zig module and names its imports
//! explicitly here, so the dependency graph is enforced by the compiler:
//! `device` cannot reach `signing`, `protocol` has no dependencies at all, and
//! only `core` knows about every feature module. Front ends (daemon, CLI, GUI)
//! sit on top and never talk to libimobiledevice or zsign directly.
//!
//!   diag ─┬─ plist ─┬─ ipa         (libzip)
//!         │         ├─ device      (libimobiledevice)
//!         │         └─ provision
//!         └─ signing               (zsign, vendored C++)
//!   protocol                       (wire types, no deps)
//!   migrate = plist + provision + signing + device + ipa (importers)
//!   core   = ipa + device + provision + signing + migrate + protocol
//!   client = protocol
//!
//!   ferryd = core + protocol          (owns devices and jobs)
//!   ferry       = core + client + protocol (CLI; talks to the daemon or runs --local)
//!   ferry-gui  = client + protocol + dvui (GUI)
const std = @import("std");

const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
};

const Import = struct { []const u8, *std.Build.Module };

fn lib(ctx: Ctx, comptime name: []const u8, imports: []const Import) *std.Build.Module {
    const b = ctx.b;
    const mod = b.addModule(name, .{
        .root_source_file = b.path("lib/" ++ name ++ "/" ++ name ++ ".zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    for (imports) |imp| mod.addImport(imp[0], imp[1]);
    const t = b.addTest(.{ .name = "test-" ++ name, .root_module = mod });
    ctx.test_step.dependOn(&b.addRunArtifact(t).step);
    return mod;
}

/// C headers are translated by the build (Zig 0.16+ has no @cImport):
/// `header` becomes the module's `c` import, with pkg-config `libs` linked.
fn withC(ctx: Ctx, mod: *std.Build.Module, header: []const u8, libs: []const []const u8) void {
    const tc = ctx.b.addTranslateC(.{ .root_source_file = ctx.b.path(header), .target = ctx.target, .optimize = ctx.optimize });
    for (libs) |l| {
        tc.linkSystemLibrary(l, .{});
        mod.linkSystemLibrary(l, .{});
    }
    mod.addImport("c", tc.createModule());
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const with_gui = b.option(bool, "gui", "Build the dvui GUI (default: true)") orelse true;

    const ctx: Ctx = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .test_step = b.step("test", "Run every module's unit tests"),
    };

    // ---- libraries -------------------------------------------------------
    const diag = lib(ctx, "diag", &.{});
    const protocol = lib(ctx, "protocol", &.{});

    // Translations: po/<lang>.po -> msgfmt --check -> embedded .mo.
    const i18n = lib(ctx, "i18n", &.{});
    inline for (.{"zh_TW"}) |lang| {
        const msgfmt = b.addSystemCommand(&.{ "msgfmt", "--check", "-o" });
        const mo = msgfmt.addOutputFileArg(lang ++ ".mo");
        msgfmt.addFileArg(b.path("po/" ++ lang ++ ".po"));
        i18n.addAnonymousImport("mo_" ++ lang, .{ .root_source_file = mo });
    }
    // `zig build pot`: refresh po/ferry.pot from the sources, then
    // `msgmerge -U po/zh_TW.po po/ferry.pot` and translate the new entries.
    const xgettext = b.addSystemCommand(&.{
        "xgettext",          "--language=C",        "--from-code=UTF-8", "--no-wrap",
        "--keyword=tr",      "--keyword=N_",        "--keyword=trf:2",   "--keyword=trfBuf:2",
        "--keyword=failT",   "--keyword=trl",     "--no-location",   "--keyword=say",       "--package-name=ferry", "-o",
    });
    xgettext.addFileArg(b.path("po/ferry.pot"));
    inline for (.{ "apps/gui/main.zig", "apps/cli/main.zig", "apps/daemon/main.zig", "lib/core/core.zig", "lib/core/pipeline.zig", "lib/migrate/migrate.zig" }) |f| xgettext.addFileArg(b.path(f));
    b.step("pot", "Extract translatable strings into po/ferry.pot").dependOn(&xgettext.step);

    const plist = lib(ctx, "plist", &.{.{ "diag", diag }});
    withC(ctx, plist, "lib/plist/c.h", &.{"libplist-2.0"});

    const ipa = lib(ctx, "ipa", &.{ .{ "diag", diag }, .{ "plist", plist } });
    withC(ctx, ipa, "lib/ipa/c.h", &.{"libzip"});

    const device = lib(ctx, "device", &.{ .{ "diag", diag }, .{ "plist", plist } });
    withC(ctx, device, "lib/device/c.h", &.{ "libimobiledevice-1.0", "libusbmuxd-2.0" });

    const provision = lib(ctx, "provision", &.{ .{ "diag", diag }, .{ "plist", plist } });

    const signing = lib(ctx, "signing", &.{.{ "diag", diag }});
    signing.linkLibrary(buildZsign(b, target, optimize));
    signing.linkSystemLibrary("openssl", .{});
    signing.addCSourceFile(.{ .file = b.path("lib/signing/p12.c"), .flags = &.{"-Wno-deprecated-declarations"} });
    signing.linkSystemLibrary("zlib", .{});

    const migrate = lib(ctx, "migrate", &.{
        .{ "diag", diag },
        .{ "plist", plist },
        .{ "provision", provision },
        .{ "signing", signing },
        .{ "device", device },
        .{ "ipa", ipa },
    });

    const core = lib(ctx, "core", &.{
        .{ "migrate", migrate },
        .{ "diag", diag },
        .{ "i18n", i18n },
        .{ "protocol", protocol },
        .{ "ipa", ipa },
        .{ "device", device },
        .{ "provision", provision },
        .{ "signing", signing },
    });

    const client = lib(ctx, "client", &.{.{ "protocol", protocol }});

    // ---- front ends ------------------------------------------------------
    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });

    const daemon_exe = app(b, "ferryd", "apps/daemon/main.zig", target, optimize, &.{
        .{ "core", core },
        .{ "i18n", i18n },
        .{ "protocol", protocol },
    });
    const cli_exe = app(b, "ferry", "apps/cli/main.zig", target, optimize, &.{
        .{ "core", core },
        .{ "client", client },
        .{ "protocol", protocol },
        .{ "i18n", i18n },
        .{ "migrate", migrate },
        .{ "clap", clap.module("clap") },
    });

    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    run_cli.addPassthruArgs();
    b.step("run", "Run the CLI (args after --)").dependOn(&run_cli.step);

    const run_daemon = b.addRunArtifact(daemon_exe);
    run_daemon.step.dependOn(b.getInstallStep());
    b.step("daemon", "Run ferryd in the foreground").dependOn(&run_daemon.step);

    if (with_gui) {
        const dvui = b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3, .freetype = true });
        const gui_exe = app(b, "ferry-gui", "apps/gui/main.zig", target, optimize, &.{
            .{ "client", client },
            .{ "protocol", protocol },
            .{ "i18n", i18n },
            .{ "dvui", dvui.module("dvui_sdl3") },
        });
        gui_exe.root_module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("assets/ferry-128.png") });
        const run_gui = b.addRunArtifact(gui_exe);
        run_gui.step.dependOn(b.getInstallStep());
        b.step("gui", "Run the GUI").dependOn(&run_gui.step);
    }
}

fn app(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const Import,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (imports) |imp| mod.addImport(imp[0], imp[1]);
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
    return exe;
}

/// zsign (github.com/zhlynn/zsign) compiled from source, plus our C ABI shim.
/// Uses system OpenSSL and zlib and zsign's vendored minizip.
fn buildZsign(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const dep = b.dependency("zsign", .{});
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    const cxx_flags: []const []const u8 = &.{ "-std=c++11", "-Wno-unused-result", "-Wno-deprecated-declarations", "-fno-sanitize=undefined" };
    const c_flags: []const []const u8 = &.{ "-Wno-deprecated-declarations", "-fno-sanitize=undefined" };
    mod.addIncludePath(dep.path("src"));
    mod.addIncludePath(dep.path("src/common"));
    mod.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{
            "archo.cpp",       "bundle.cpp",         "certcheck.cpp",
            "macho.cpp",       "metadata.cpp",       "openssl.cpp",
            "signing.cpp",     "common/archive.cpp", "common/fs.cpp",
            "common/json.cpp", "common/log.cpp",     "common/sha.cpp",
            "common/timer.cpp", "common/util.cpp",
        },
        .flags = cxx_flags,
    });
    mod.addCSourceFiles(.{
        .root = dep.path("src/third-party/minizip"),
        .files = &.{ "ioapi.c", "zip.c", "unzip.c" },
        .flags = c_flags,
    });
    mod.addCSourceFile(.{ .file = b.path("lib/signing/zsign_shim.cpp"), .flags = cxx_flags });
    // OpenSSL and zlib are linked by the `signing` module: linking shared
    // system libraries into a static archive embeds the .so files in it.
    return b.addLibrary(.{ .name = "zsign", .linkage = .static, .root_module = mod });
}
