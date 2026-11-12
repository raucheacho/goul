//! Le cœur audio de Goul, une seule fois pour trois plateformes.
//!
//! The same source becomes a static library for Android and iOS and a WebAssembly
//! module for the dispatch console, which is the whole reason this is Zig: the
//! phone and the browser cannot drift apart if they run the same code.
//!
//!     zig build test            — la partie qui compte, sur ta machine
//!     zig build android
//!     zig build ios
//!     zig build wasm
//!
//! `zig build test` needs no device, no emulator and no libopus: the frame
//! format and the play-out buffer are pure computation, and that is where the
//! bugs that matter live.

const std = @import("std");
const opus_sources = @import("opus_sources.zig");

/// libopus, compiled from source by Zig rather than by each platform's own
/// build system. One command produces the same codec for an Android phone, an
/// iPhone and a browser — no CMake, no Gradle NDK plumbing, no Xcode project.
///
/// The SDKs are still needed: Zig ships libc headers for WebAssembly but
/// cannot ship Bionic or Apple's, which are not redistributable. So Android
/// and iOS point at a sysroot. Zig replaces the build systems, not the SDKs.
const opus_defines = [_][]const u8{
    "-DOPUS_BUILD",
    "-DHAVE_CONFIG_H",

    // Fixed point rather than float. Not for speed — a 20 ms frame is nothing
    // on any of these devices — but for *identical output everywhere*. The
    // phone and the dispatch console must decode a stream the same way, and
    // float rounding does not promise that across ARM and WebAssembly.
    "-DFIXED_POINT=1",

    // We only ever hand the codec int16 PCM, so the float entry points are
    // dead weight in a binary that ships inside a mobile app.
    "-DDISABLE_FLOAT_API",

    // Opus 1.5 ships a neural network for packet loss concealment. It is very
    // good and it costs megabytes; a delivery radio does not need it, and the
    // play-out buffer handles gaps with the plain Opus concealer. It is off
    // unless ENABLE_DEEP_PLC or ENABLE_DRED is defined, which we never do and
    // whose sources under dnn/ we do not compile — this define only drops the
    // float debugging that goes with it.
    "-DDISABLE_DEBUG_FLOAT",

    // C99 variable-length arrays for the codec's scratch space. The
    // alternative is a global pseudo-stack, which is not thread-safe — and
    // the encoder runs on the audio capture thread while the decoder runs on
    // the playback one.
    "-DVAR_ARRAYS",

    "-DOPUS_HAVE_RTCD=0",
};

/// Compile libopus dans le module et lui donne son API sous `@import("opus_c")`.
///
/// Renvoie l'étape de traduction du C : une cible qui tient ses en-têtes libc
/// d'un SDK (Android) doit les lui indiquer aussi.
fn linkOpus(b: *std.Build, module: *std.Build.Module) *std.Build.Step.TranslateC {
    const dep = b.dependency("opus", .{});

    // `@cImport` n'existe plus : l'en-tête d'Opus se traduit ici, une fois par cible.
    const opus_c = b.addTranslateC(.{
        .root_source_file = b.path("src/opus_c.h"),
        .target = module.resolved_target.?,
        .optimize = module.optimize orelse .Debug,
        .link_libc = module.link_libc orelse true,
    });
    opus_c.addIncludePath(dep.path("include"));
    module.addImport("opus_c", opus_c.createModule());

    module.addIncludePath(dep.path("include"));
    module.addIncludePath(dep.path("celt"));
    module.addIncludePath(dep.path("silk"));
    module.addIncludePath(dep.path("silk/fixed"));
    module.addIncludePath(dep.path("src"));
    // config.h is normally produced by autotools; ours is checked in, since
    // the answers are the same for every target we build.
    module.addIncludePath(b.path("opus-config"));

    for (opus_sources.files) |file| {
        module.addCSourceFile(.{
            .file = dep.path(file),
            .flags = &opus_defines,
        });
    }
    return opus_c;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Tests ───────────────────────────────────────────────────────────────
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    core.link_libc = true;
    _ = linkOpus(b, core);

    const unit_tests = b.addTest(.{ .name = "goul-audio-test", .root_module = core });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Exécute les tests du cœur audio");
    test_step.dependOn(&run_tests.step);

    // L'ABI, testée aussi.
    //
    // Elle ne l'était pas : le module de test ci-dessus part de `core.zig`, qui
    // ignore `abi.zig`. C'est ce qui a laissé passer une fuite de mémoire dans
    // `goul_recv_close` — le décodeur libéré avant le tampon, donc jamais rendu
    // à un allocateur qui est une pile. Une vingtaine d'ouvertures suffisaient
    // à épuiser le tas, et la voix ne s'ouvrait plus sur le téléphone.
    const abi_module = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_module.link_libc = true;
    _ = linkOpus(b, abi_module);

    const abi_tests = b.addTest(.{ .name = "goul-audio-abi-test", .root_module = abi_module });
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);

    // ── Cibles ──────────────────────────────────────────────────────────────
    //
    // Each one is a static library exposing the C ABI in src/abi.zig. Kotlin,
    // Swift and JavaScript all call the same eight functions.

    // Zig cross-compiles C without a toolchain of its own *only where it ships
    // the libc headers*. It does for WebAssembly. It cannot for Android or
    // iOS, whose headers belong to Google and Apple and are not
    // redistributable — so those two need a sysroot pointed at the SDK that is
    // already on the machine. Zig still replaces the build system on both;
    // it does not replace the SDK.
    // Android gets a shared library rather than an archive: Kotlin loads it
    // with System.loadLibrary, and the JNI bridge in src/android.zig is what
    // it calls. No CMake, no NDK plugin in Gradle — the .so is dropped into
    // jniLibs as a build artefact.
    addTarget(b, "android", .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    }, .{
        .sysroot = b.option([]const u8, "android-sysroot", "Sysroot du NDK Android"),
        .triple = "aarch64-linux-android",
        .hint =
        \\-Dandroid-sysroot=$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot
        ,
        .root = "src/android.zig",
        .shared = true,
    });

    addTarget(b, "ios", .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .none,
    }, .{
        .sysroot = b.option([]const u8, "ios-sysroot", "SDK iPhoneOS") orelse
            defaultSdk(b, "iphoneos"),
        .hint = "-Dios-sysroot=$(xcrun --sdk iphoneos --show-sdk-path)",
    });

    // The simulator is the same architecture as the device on Apple Silicon
    // but a different platform, so the two slices cannot be merged with lipo.
    // They are combined into an XCFramework instead — see tools/make-xcframework.sh.
    addTarget(b, "ios-sim", .{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .simulator,
    }, .{
        .sysroot = b.option([]const u8, "ios-sim-sysroot", "SDK iPhoneSimulator") orelse
            defaultSdk(b, "iphonesimulator"),
        .hint = "-Dios-sim-sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)",
    });

    // wasi rather than freestanding: freestanding has no libc at all, and
    // libopus needs string.h and math.h like any C library. Nothing here
    // actually calls a WASI syscall — the imports the module ends up
    // declaring are stubs the browser side never has to implement.
    addTarget(b, "wasm", .{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    }, .{ .wasm = true });
}

/// An SDK sitting in Xcode, so the common case needs no flag. Absent on a
/// Linux CI box, where the matching `-D` option says so explicitly.
fn defaultSdk(b: *std.Build, sdk: []const u8) ?[]const u8 {
    var code: u8 = 0;
    const stdout = b.runAllowFail(
        &.{ "xcrun", "--sdk", sdk, "--show-sdk-path" },
        &code,
        .ignore,
    ) catch return null;

    const path = std.mem.trim(u8, stdout, " \n\r");
    return if (code != 0 or path.len == 0) null else path;
}

/// Android 7.0. Nothing here needs anything newer, and it is the floor the
/// mobile app already targets.
const android_api = 24;

/// The whole public surface, and the single place it is written down. Adding
/// an `export fn` to abi.zig without adding it here means JavaScript will not
/// see it — which is the right failure, because it is also the reminder that
/// three platform bindings now have a function to wire up.
const abi_exports = [_][]const u8{
    "goul_send_open",
    "goul_send_push",
    "goul_send_close",
    "goul_recv_open",
    "goul_recv_push",
    "goul_recv_pull",
    "goul_recv_end_stream",
    "goul_recv_close",
    "goul_recv_stats",
    "goul_frame_samples",
    "goul_sample_rate",
    "goul_pcm_buffer",
    "goul_frame_buffer",
    "goul_frame_buffer_cap",
    "goul_stats_buffer",
};

const TargetOptions = struct {
    /// Where the platform's own headers live. Null means Zig ships them.
    sysroot: ?[]const u8 = null,
    /// The sysroot's own name for the architecture, when it keeps a subtree
    /// per target the way the Android NDK does.
    triple: ?[]const u8 = null,
    /// Shown when the sysroot is needed and missing.
    hint: []const u8 = "",
    /// Emit a loadable `.wasm` module rather than a static archive.
    wasm: bool = false,
    /// Root source file, when the target needs a bridge above the C ABI.
    root: []const u8 = "src/abi.zig",
    /// Emit a shared library rather than a static archive.
    shared: bool = false,
};

fn addTarget(
    b: *std.Build,
    name: []const u8,
    query: std.Target.Query,
    options: TargetOptions,
) void {
    const step = b.step(name, b.fmt("Construit le cœur audio pour {s}", .{name}));

    // A missing SDK is a setup problem, and it should read like one rather
    // than as a hundred "string.h not found" lines from inside libopus.
    if (options.hint.len > 0 and options.sysroot == null) {
        const explain = b.addFail(b.fmt(
            "Le SDK {s} est introuvable. Indiquez-le :\n    zig build {s} {s}",
            .{ name, name, options.hint },
        ));
        step.dependOn(&explain.step);
        return;
    }

    const module = b.createModule(.{
        .root_source_file = b.path(options.root),
        .target = b.resolveTargetQuery(query),
        // Always optimised, whatever `-Doptimize` says. libopus refuses to
        // build unoptimised — `#error You appear to be compiling without
        // optimization` — and it is right to: an unoptimised codec on a phone
        // would miss its 20 ms deadline. Debug the Zig around it with
        // `zig build test`, which runs on the host.
        //
        // Small rather than fast: a 20 ms frame is nothing for any of these
        // CPUs, while the bytes ship inside a mobile app and get downloaded by
        // every dispatcher's browser.
        .optimize = .ReleaseSmall,
        // Zig ships libc headers for WebAssembly and can *provide* libc for
        // its own targets, but it cannot provide Bionic. On Android the
        // headers come from the NDK sysroot below and the library itself is
        // linked as a plain file — asking Zig for libc there fails with
        // "unable to provide libc for target".
        .link_libc = !options.shared,
    });

    const opus_c = linkOpus(b, module);

    if (options.sysroot) |sysroot| {
        // Le niveau d'API Android, pour les en-têtes du NDK. Le NDK 30 refuse
        // de compiler sans lui (« Unversioned target triples are not
        // supported ») ; le 28 se rabattait en silence sur « toutes les API ».
        // Il passe en macro et pas dans la cible : une cible versionnée fait
        // demander à Zig sa propre libc Android, qu'il ne fournit pas.
        if (options.triple != null) {
            const api = b.fmt("{d}", .{android_api});
            module.addCMacro("__ANDROID_API__", api);
            opus_c.defineCMacro("__ANDROID_API__", api);
        }
        // La traduction de opus.h lit <stdint.h> : les mêmes en-têtes que le module.
        opus_c.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
        if (options.triple) |triple| {
            opus_c.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }),
            });
        }
        module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
        module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sysroot}) });

        // The NDK splits its headers in two: the portable ones under
        // usr/include, and the architecture's own — asm/, machine/ — one level
        // down. Without the second, <linux/types.h> cannot find <asm/types.h>.
        if (options.triple) |triple| {
            module.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }),
            });

            const libs = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, android_api });
            module.addLibraryPath(.{ .cwd_relative = libs });

            if (options.shared) {
                // Le pont JNI (src/android.zig) lit <jni.h>, qui vit dans le NDK.
                const jni_c = b.addTranslateC(.{
                    .root_source_file = b.path("src/jni_c.h"),
                    .target = module.resolved_target.?,
                    .optimize = .ReleaseSmall,
                    .link_libc = false,
                });
                jni_c.defineCMacro("__ANDROID_API__", b.fmt("{d}", .{android_api}));
                jni_c.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
                jni_c.addSystemIncludePath(.{
                    .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }),
                });
                module.addImport("jni_c", jni_c.createModule());

                // Named as files rather than with -lc: Zig would otherwise try
                // to supply a libc of its own for this target.
                module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libc.so", .{libs}) });
                module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libm.so", .{libs}) });
            }
        }
    }

    // WebAssembly wants an executable, not an archive: the browser loads one
    // module and calls into it. A *reactor* executable — no main, initialised
    // once and then kept alive to answer calls — is exactly what a library
    // loaded from JavaScript is.
    //
    // The export list is spelled out rather than using `rdynamic`, which
    // exports everything public. That would publish all 75 of libopus's entry
    // points — multistream, ambisonic projection, repacketizer, DRED — none of
    // which we call. Naming ours keeps the module's surface equal to its API,
    // and lets the linker drop the code behind the rest.
    // One name for every target, not one per target. The output directory
    // already says which is which, and CocoaPods refuses an XCFramework whose
    // slices carry different binary names — which is exactly what
    // "libgoul-audio-ios" next to "libgoul-audio-ios-sim" produced.
    const lib = if (options.wasm) exe: {
        module.export_symbol_names = &abi_exports;
        const e = b.addExecutable(.{
            .name = "goul-audio",
            .root_module = module,
        });
        e.wasi_exec_model = .reactor;
        break :exe e;
    } else b.addLibrary(.{
        .name = "goul-audio",
        .root_module = module,
        .linkage = if (options.shared) .dynamic else .static,
    });

    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = name } },
    });

    step.dependOn(&install.step);
}
