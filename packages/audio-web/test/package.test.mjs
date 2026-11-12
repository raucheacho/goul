/**
 * Le paquet tel qu'une app le reçoit : `dist/` construit, `assets/` à servir.
 * `npm run build` et `make -C ../../core wasm` d'abord.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { GoulAudio } from "../dist/index.js";

const asset = (name) => fileURLToPath(new URL(`../assets/${name}`, import.meta.url));

test("un aller-retour par l'API du paquet", async () => {
  const audio = await GoulAudio.instantiate(await readFile(asset("goul-audio.wasm")));
  audio.openSender(42);
  audio.openReceiver({ targetMs: 40, maxMs: 400 });

  let played = 0;
  for (let i = 0; i < 20; i++) {
    const pcm = new Int16Array(960);
    for (let s = 0; s < pcm.length; s++) pcm[s] = Math.round(Math.sin((i * 960 + s) / 17) * 8000);
    audio.push(audio.encode(pcm).slice());
    if (audio.pull()) played++;
  }
  assert.equal(played, 19);
  assert.equal(audio.stats().received, 20);
  audio.closeSender();
  audio.closeReceiver();
});

test("les worklets sont livrés, sous les noms que les apps enregistrent", async () => {
  const source = await readFile(asset("goul-ptt-worklets.js"), "utf8");
  assert.match(source, /registerProcessor\("goul-capture"/);
  assert.match(source, /registerProcessor\("goul-playback"/);
});
