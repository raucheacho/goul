#!/usr/bin/env bash
# Regénère opus_sources.zig depuis les .mk de libopus.
#
# Les listes de sources d'opus vivent dans des fichiers Make que le dépôt amont
# tient à jour ; les recopier à la main serait une dette à chaque montée de
# version. Ce script les lit et en fait un tableau Zig.
#
#   ./tools/regen-opus-sources.sh /chemin/vers/opus-1.5.2
set -euo pipefail

SRC="${1:?usage: regen-opus-sources.sh <dossier source opus>}"
OUT="$(dirname "$0")/../opus_sources.zig"

extract() {
  tr -d '\\' < "$1" | awk -v v="$2" '
    BEGIN { f = 0 }
    $1 == v { f = 1; next }
    # Digits belong in the class: without them SILK_SOURCES_FIXED_SSE4_1 is
    # not recognised as the start of the next variable, and its name lands in
    # the list as if it were a file.
    /^[A-Z0-9_]+ *=/ { f = 0 }
    f && NF { print $1 }'
}

{
  echo "//! Liste des sources libopus, extraite des .mk du dépôt amont."
  echo "//!"
  echo "//! Ne pas éditer à la main : ./tools/regen-opus-sources.sh <src opus>."
  echo "//!"
  echo "//! Configuration : SILK en point fixe, sans les API flottantes et sans"
  echo "//! le réseau de neurones de la 1.5 — voir build.zig pour le pourquoi."
  echo "//!"
  echo "//! Les variantes x86/arm/mips sont écartées : elles sont sélectionnées"
  echo "//! par le configure d'autotools qu'on n'exécute pas, et le C générique"
  echo "//! qu'elles remplacent est déjà dans la liste."
  echo ""
  echo "pub const files = [_][]const u8{"
  {
    extract "$SRC/opus_sources.mk" OPUS_SOURCES
    extract "$SRC/celt_sources.mk" CELT_SOURCES
    extract "$SRC/silk_sources.mk" SILK_SOURCES
    extract "$SRC/silk_sources.mk" SILK_SOURCES_FIXED
  } | grep -v -E '/(x86|arm|mips)/' | sed 's/^/    "/; s/$/",/'
  echo "};"
} > "$OUT"

echo "$(grep -c '^    "' "$OUT") sources écrites dans $OUT"
