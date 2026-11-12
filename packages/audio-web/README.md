# @raucheacho/goul-audio-web

Goul's audio core for the browser: the same code the phones run (Opus codec,
wire framing, jitter buffer), compiled to WebAssembly.

```sh
npm install @raucheacho/goul-audio-web
```

## What's in the package

| | |
|---|---|
| `assets/goul-audio.wasm` | the audio core; imports nothing from the host |
| `assets/goul-ptt-worklets.js` | the `goul-capture` and `goul-playback` AudioWorklets that run it on the audio thread |
| `GoulAudio` (import) | the same core, callable from JavaScript (tests, tools, Node.js) |

Both files in `assets/` must be **served with your page**: an AudioWorklet is
loaded from a URL, not imported.

```js
// In the page: load the worklets, then hand each one the module's bytes.
// It answers { type: "ready" }, or { type: "error", message }.
await context.audioWorklet.addModule("/goul-ptt-worklets.js");
const bytes = await (await fetch("/goul-audio.wasm")).arrayBuffer();

const capture = new AudioWorkletNode(context, "goul-capture", { numberOfInputs: 1, numberOfOutputs: 0, channelCount: 1 });
capture.port.postMessage({ type: "init", bytes: bytes.slice(0) });
capture.port.postMessage({ type: "start", streamId, bitrate: 24_000 }); // → { type: "frame", frame }
```

The full message protocol of both worklets is documented at the top of
`assets/goul-ptt-worklets.js`.

```js
// Off the audio thread.
import { GoulAudio } from "@raucheacho/goul-audio-web";

const audio = await GoulAudio.instantiate(bytes);
audio.openSender(streamId);
const frame = audio.encode(pcm); // Int16Array of 960 samples → one wire frame
```

## Format

48 kHz mono, 20 ms frames (960 samples). Each frame on the wire is a 4-byte
stream id and a 2-byte sequence number (little-endian), followed by one Opus
packet. When the network runs late, the jitter buffer **drops** audio rather
than playing it back faster.

## Development

    make -C ../../core wasm   # builds assets/goul-audio.wasm
    npm run build && npm test

## License

MIT
