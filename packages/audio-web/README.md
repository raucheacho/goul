# @raucheacho/goul-audio-web

Le cœur audio de Goul dans le navigateur : le même code que sur les téléphones
(Opus, format de trame, tampon de lecture), compilé en WebAssembly.

```sh
npm install @raucheacho/goul-audio-web
```

## Ce que le paquet livre

| | |
|---|---|
| `assets/goul-audio.wasm` | le cœur ; n'importe rien de l'hôte |
| `assets/goul-ptt-worklets.js` | les AudioWorklets `goul-capture` et `goul-playback`, qui le font tourner sur le fil audio |
| `GoulAudio` (import) | le même cœur, appelable depuis JavaScript (tests, outils, Node) |

Les deux fichiers d'`assets/` sont à **servir avec la page** : un AudioWorklet
se charge par une adresse, pas par un import.

```js
// La page : charge les worklets, puis donne à chacun les octets du module.
// Il répond { type: "ready" }, ou { type: "error", message }.
await context.audioWorklet.addModule("/goul-ptt-worklets.js");
const bytes = await (await fetch("/goul-audio.wasm")).arrayBuffer();

const capture = new AudioWorkletNode(context, "goul-capture", { numberOfInputs: 1, numberOfOutputs: 0, channelCount: 1 });
capture.port.postMessage({ type: "init", bytes: bytes.slice(0) });
capture.port.postMessage({ type: "start", streamId, bitrate: 24_000 }); // → { type: "frame", frame }
```

Le protocole complet des deux worklets est décrit en tête de
`assets/goul-ptt-worklets.js`.

```js
// Hors du fil audio.
import { GoulAudio } from "@raucheacho/goul-audio-web";

const audio = await GoulAudio.instantiate(bytes);
audio.openSender(streamId);
const frame = audio.encode(pcm); // Int16Array de 960 échantillons → une trame
```

## Développer

    make -C ../../core wasm   # construit assets/goul-audio.wasm
    npm run build && npm test
