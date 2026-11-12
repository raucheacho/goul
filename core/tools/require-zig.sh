# Vérifie la version de Zig avant de construire quoi que ce soit.
#
# Sourced, not run. Callers set ROOT first.
#
# Worth its own check rather than letting the build fail on its own: a machine
# with two Zigs installed — `zig@0.15` next to `zig` — puts the older one first
# on PATH, and what comes out is a wall of compile errors from inside build.zig
# rather than "wrong version". That is a long way to travel for a `brew unlink`.
#
# The comparison is exact, not "at least". The committed artefacts
# (apps/web/public/goul-audio.wasm and the two mobile ones) are byte-for-byte
# reproducible from this source *at one version*, and CI checks that. A build
# from a different Zig may be perfectly correct and still fail that check.

require_zig() {
  ZIG="${ZIG:-zig}"

  local want found
  want="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$ROOT/build.zig.zon")"
  found="$("$ZIG" version 2>/dev/null || true)"

  if [ -z "$found" ]; then
    echo "zig introuvable (via « $ZIG »)." >&2
    echo "  Installez Zig $want, ou indiquez-le : ZIG=/chemin/vers/zig $0" >&2
    return 1
  fi

  if [ "$found" != "$want" ]; then
    echo "Zig $want attendu, trouvé $found (via « $(command -v "$ZIG")»)." >&2
    echo >&2

    # A second Zig on the machine is the usual cause, so name it rather than
    # leaving the reader to find it.
    local other
    other="$(command -v -a zig 2>/dev/null | sort -u | grep -v "^$(command -v "$ZIG")$" || true)"
    if [ -n "$other" ]; then
      echo "  Autres zig sur cette machine :" >&2
      echo "$other" | sed 's/^/    /' >&2
      echo >&2
    fi

    echo "  Passez le bon : ZIG=/chemin/vers/zig $0" >&2
    echo "  ou retirez l'autre du PATH (souvent un export dans ~/.zshrc)." >&2
    return 1
  fi
}
