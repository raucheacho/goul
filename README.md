# Goul

La technologie voix partagée par Goul, Livro et Phono, développée une fois ici
et consommée par les trois comme des paquets versionnés.

Ce dépôt contient aujourd'hui le **cœur audio** : le format de trame, le codec
Opus et le tampon de lecture, écrits une fois (Zig) et compilés pour le
navigateur, Android et iOS. Le transport temps réel est
[konet](https://github.com/raucheacho/konet).

```
core/                 le cœur : sources, tests, compilation des trois cibles
packages/audio-web/   @raucheacho/goul-audio-web : le .wasm, les AudioWorklets, l'API JS
dist/                 (construit) libgoul-audio.so, GoulAudioCore.xcframework
```

## Vérifier

    make -C core test     # 48 tests du cœur, puis 10 sur le module navigateur

Dont la compatibilité avec ce qui tourne déjà : `core/js/compat.test.mjs`
tient que le cœur d'ici émet les mêmes octets et joue le même son que le
binaire embarqué par les trois apps avant ce dépôt.

## Construire

    make -C core wasm      # -> packages/audio-web/assets/goul-audio.wasm
    make -C core android   # -> dist/android/arm64-v8a/libgoul-audio.so   (NDK)
    make -C core ios       # -> dist/ios/GoulAudioCore.xcframework        (macOS, Xcode)

Zig 0.17.1. Rien de construit n'est commité.

## Publier

Une étiquette `vX.Y.Z` (voir `CHANGELOG.md`) lance `.github/workflows/release.yml` :
le paquet web part sur npm, les binaires Android et iOS sont attachés à la
version GitHub avec leurs empreintes (`SHA256SUMS`). Secret requis : `NPM_TOKEN`.

## Règle

Une correction du cœur se fait ici, jamais dans une app.
