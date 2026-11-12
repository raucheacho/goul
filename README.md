# Goul

The voice technology shared by Goul, Livro and Phono: built once here, and
consumed by all three as versioned packages.

This repository currently holds the **audio core**: the wire framing, the Opus
codec and the jitter buffer, written once (in Zig) and compiled for the
browser, Android and iOS. The realtime transport is
[Konet](https://github.com/raucheacho/konet).

```
core/                 the core: sources, tests, builds for all three targets
packages/audio-web/   @raucheacho/goul-audio-web: the .wasm, the AudioWorklets, the JS API
dist/                 (built) libgoul-audio.so, GoulAudioCore.xcframework
```

## Install

| Platform | Get it from |
|---|---|
| Browser | `npm install @raucheacho/goul-audio-web` |
| Android | `goul-audio-android-vX.Y.Z.zip` on the [releases page](https://github.com/raucheacho/goul/releases) (`arm64-v8a`) |
| iOS | `goul-audio-ios-vX.Y.Z.zip` on the [releases page](https://github.com/raucheacho/goul/releases) (device + simulator XCFramework) |

Every release lists the SHA-256 of its binaries in `SHA256SUMS`.

## Test

    make -C core test     # 48 core tests, then 10 on the browser module

This includes a compatibility check: `core/js/compat.test.mjs` asserts that
the core built here emits the same bytes and plays the same sound as the
binary shipped by all three apps before this repository existed.

## Build

    make -C core wasm      # -> packages/audio-web/assets/goul-audio.wasm
    make -C core android   # -> dist/android/arm64-v8a/libgoul-audio.so   (Android NDK 28.2, not 30)
    make -C core ios       # -> dist/ios/GoulAudioCore.xcframework        (macOS, Xcode)

Requires Zig 0.17.1. Nothing built is committed.

## Release

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`: the web package
is published to npm, and the Android and iOS binaries are attached to the
GitHub release with their checksums. Release notes come from
`.github/RELEASE_NOTES.md`. Required secret: `NPM_TOKEN`.

## Rule

A fix to the core is made here, never inside an app.

## License

MIT
