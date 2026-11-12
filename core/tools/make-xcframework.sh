#!/usr/bin/env bash
# Construit GoulAudioCore.xcframework et l'installe dans le module Expo.
#
# Device and simulator are the same architecture on Apple Silicon but different
# platforms, so lipo cannot merge them. An XCFramework is the only container
# that holds both, and it is what CocoaPods consumes.
#
# Both slices must carry the *same* binary name — CocoaPods refuses the
# framework otherwise, which is why build.zig names every target "goul-audio"
# and lets the output directory say which is which.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/../dist/ios/GoulAudioCore.xcframework"
ZIG="${ZIG:-zig}"

cd "$ROOT"
"$ZIG" build ios
"$ZIG" build ios-sim

# Zig's archiver does not pad members to 8 bytes, and Apple's linker refuses a
# Mach-O archive that is not aligned:
#
#     ld: 64-bit mach-o member 'libgoul-audio_zcu.o' not 8-byte aligned
#
# Unpacking and repacking with Xcode's own libtool fixes the alignment without
# touching a single object. The member names are unique, so a flat extract is
# safe.
repack() {
  local input="$1" output="$2"
  local scratch
  scratch="$(mktemp -d)"

  # Zig stores a mode of 0 for its archive members, so `ar -x` writes files
  # nobody can read — libtool then reports errno=13 on every one of them.
  (cd "$scratch" && ar -x "$input" && chmod u+r ./*.o)

  xcrun libtool -static -o "$output" "$scratch"/*.o
  rm -rf "$scratch"
}

DEVICE="$(mktemp -d)/libgoul-audio.a"
SIM="$(mktemp -d)/libgoul-audio.a"
repack "$ROOT/zig-out/ios/libgoul-audio.a" "$DEVICE"
repack "$ROOT/zig-out/ios-sim/libgoul-audio.a" "$SIM"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$DEVICE" -headers "$ROOT/include" \
  -library "$SIM"    -headers "$ROOT/include" \
  -output "$OUT"

echo "-> $OUT"
