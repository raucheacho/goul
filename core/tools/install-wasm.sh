#!/usr/bin/env bash
# Construit le module WebAssembly et l'installe dans la console de dispatch.
#
# The copy used to be a line in a README that everyone was expected to
# remember. It is not the kind of step that fails loudly when skipped: the
# console keeps working, on a build of the audio core that is no longer the one
# the phones run. This script exists so the build and the copy cannot come
# apart.
#
#     ./tools/install-wasm.sh
#     ZIG=/chemin/vers/zig ./tools/install-wasm.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/../packages/audio-web/assets/goul-audio.wasm"

# shellcheck source=./require-zig.sh
. "$ROOT/tools/require-zig.sh"
require_zig

cd "$ROOT"
"$ZIG" build wasm
mkdir -p "$(dirname "$DEST")"
cp zig-out/wasm/goul-audio.wasm "$DEST"

echo "-> $(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"
