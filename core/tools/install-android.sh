#!/usr/bin/env bash
# Construit la bibliothèque Android et l'installe dans le module Expo.
#
# Android gets a shared library rather than an archive: Kotlin loads it with
# System.loadLibrary, and the JNI bridge in src/android.zig is what it calls.
# No CMake, no NDK plugin in Gradle — the .so is dropped into jniLibs as a
# build artefact.
#
# Only arm64-v8a is produced, which is why there is no x86_64 emulator target:
# a second architecture would double the build for a device nobody delivers on.
#
#     ./tools/install-android.sh
#     ANDROID_NDK=~/Library/Android/sdk/ndk/26.1.10909125 ./tools/install-android.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/../dist/android/arm64-v8a"

# shellcheck source=./require-zig.sh
. "$ROOT/tools/require-zig.sh"
require_zig

# Zig ships libc headers for WebAssembly but cannot ship Bionic, which belongs
# to Google and is not redistributable. So this one target needs a sysroot
# pointed at the NDK that is already on the machine. Zig replaces the build
# system here, not the SDK.
NDK="${ANDROID_NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"

if [ -z "$NDK" ]; then
  # The usual install locations, so the common case needs no variable.
  for candidate in "$HOME/Library/Android/sdk/ndk"/* "$HOME/Android/Sdk/ndk"/*; do
    [ -d "$candidate" ] && NDK="$candidate"
  done
fi

if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  echo "NDK Android introuvable." >&2
  echo "  Indiquez-le : ANDROID_NDK=~/Library/Android/sdk/ndk/<version> $0" >&2
  exit 1
fi

# The NDK keeps one prebuilt toolchain per host platform.
case "$(uname -s)" in
  Darwin) HOST="darwin-x86_64" ;;
  Linux)  HOST="linux-x86_64" ;;
  *) echo "Plateforme hôte non gérée : $(uname -s)" >&2; exit 1 ;;
esac

SYSROOT="$NDK/toolchains/llvm/prebuilt/$HOST/sysroot"
if [ ! -d "$SYSROOT" ]; then
  echo "Sysroot introuvable : $SYSROOT" >&2
  echo "  Le NDK « $NDK » n'a pas de toolchain pour $HOST." >&2
  exit 1
fi

cd "$ROOT"
"$ZIG" build android -Dandroid-sysroot="$SYSROOT"

mkdir -p "$DEST"
cp zig-out/android/libgoul-audio.so "$DEST/"

echo "-> $(cd "$DEST" && pwd)/libgoul-audio.so"
