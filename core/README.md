# goul-audio

Le cœur audio de Goul : format de trame, codec Opus et tampon de lecture,
écrits une fois et compilés pour le téléphone **et** le navigateur.

C'est la raison d'être du paquet. La console de dispatch et l'app du livreur
ne peuvent pas diverger sur la façon de décoder un flux si elles exécutent le
même code.

## Commandes

    zig build test              # 22 tests du cœur — sur ta machine, sans appareil
    zig build wasm              # console web -> zig-out/wasm/goul-audio.wasm
    node --test js/wasm.test.mjs   # 6 tests du module tel qu'il sera chargé

    # Android : une bibliothèque partagée, pont JNI compris
    zig build android -Dandroid-sysroot=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot

    # iOS : appareil + simulateur réunis dans un XCFramework
    ./tools/make-xcframework.sh

`zig build test` ne demande ni téléphone, ni émulateur, ni réseau : une
coupure, une rafale, un livreur coupé en plein mot sont tous reproductibles
en quelques millisecondes.

`js/compat.test.mjs` compare le module construit ici au binaire en service
avant ce dépôt (`testdata/goul-audio-0.1.0.wasm`) : mêmes trames, même son, au
bit près, et chacun décode ce que l'autre émet.

Zig 0.17.1 exactement (`build.zig.zon`) : `tools/require-zig.sh` le vérifie.

## Ce que Zig fait, et ce qu'il ne fait pas

Il compile libopus pour les trois cibles depuis une seule commande — pas de
CMake, pas de plomberie NDK dans Gradle, pas de projet Xcode.

Il ne remplace pas les SDK. Les en-têtes libc de WebAssembly sont livrés avec
Zig ; ceux de Bionic et d'Apple ne sont pas redistribuables, donc Android et
iOS pointent vers un sysroot déjà présent sur la machine. Les SDK Apple sont
trouvés tout seuls via `xcrun`.

Sur Apple Silicon, l'appareil et le simulateur ont la **même architecture mais
des plateformes différentes** : `lipo` ne peut pas les fusionner, seul un
XCFramework les contient tous les deux. C'est ce que fait
`tools/make-xcframework.sh`.

Ce script réempaquette aussi les archives avec le `libtool` de Xcode, parce que
l'archiveur de Zig ne cale pas les membres sur 8 octets et que le linker
d'Apple refuse une archive Mach-O qui ne l'est pas :

    ld: 64-bit mach-o member 'libgoul-audio_zcu.o' not 8-byte aligned

## La règle qui tient tout

> Quand on est en retard, on **jette**. On ne joue jamais plus vite.

Rejouer un retard en accéléré donne cette voix de dessin animé, et ça ne
rattrape jamais rien : les mots prennent le même temps à être dits. Jeter perd
une fraction de seconde et reste en direct. Sur une radio, être à l'heure vaut
mieux qu'être complet.

## L'ABI

Onze fonctions, ni structs ni callbacks — ce que tous les FFI savent faire.

L'asymétrie entre les deux sens est voulue : **encoder est synchrone** (le
micro sait quand il a 20 ms), **décoder est push/pull** (le réseau livre quand
il veut, la lecture réclame toutes les 20 ms). C'est le tampon qui décide
quand le son sort.

## Fichiers

| | |
|---|---|
| `src/frame.zig` | le format sur le fil — 4 octets de flux, 2 de séquence, puis Opus |
| `src/jitter.zig` | le tampon de lecture, et la règle ci-dessus |
| `src/codec.zig` | Opus, enveloppé mince |
| `src/abi.zig` | l'ABI C |
| `src/android.zig` | le pont JNI — pas de CMake, pas de plugin NDK |
| `js/index.ts` | la liaison JavaScript typée |
| `opus_sources.zig` | généré par `tools/regen-opus-sources.sh` |

## Débit mesuré

À 24 kbit/s demandés, moyenne d'octets par trame de 20 ms sur 40 trames :

| | parole | silence |
|---|---|---|
| CBR | 60 (24 kbit/s) | 18 |
| VBR contraint | 57 (22 kbit/s) | 9 |
| VBR libre | 57 (22 kbit/s) | 9 |

Le gain du VBR n'est **pas** sur la parole — 60 contre 57, c'est du bruit. Il
est sur le silence, qui est divisé par deux, et sur un canal de push-to-talk
le silence est l'essentiel du temps d'antenne : les pauses dans une phrase,
l'instant avant de relâcher le bouton. Avec le DTX par-dessus, un silence qui
dure tombe à un octet.

La contrainte ne coûte rien de mesurable, donc elle reste : elle borne les
pics, ce qui est une assurance gratuite sur un lien déjà en difficulté.

## Le module WebAssembly

216 Ko, **zéro import**. Pas de shim WASI, pas de système de fichiers, pas
d'horloge — le navigateur lui donne de la mémoire et appelle des fonctions.

Les exports sont énumérés dans `build.zig` plutôt que laissés à `rdynamic`,
qui publierait les 75 points d'entrée de libopus qu'on n'appelle jamais. Un
test vérifie qu'il n'y a rien de plus que l'ABI.
