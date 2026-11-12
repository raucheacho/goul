/**
 * La compatibilité avec ce qui tourne déjà.
 *
 * testdata/goul-audio-0.1.0.wasm est le binaire embarqué par Goul, Livro et
 * Phono avant ce dépôt (sha256 cd4f9fd5…). Des téléphones et des consoles qui
 * l'exécutent parleront à des clients construits d'ici : ce test tient que les
 * deux se comprennent, et dit si le nouveau binaire fait autre chose que
 * l'ancien — au bit près.
 *
 * Il lit l'artefact dans zig-out : `zig build wasm` d'abord.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const path = (rel) => fileURLToPath(new URL(rel, import.meta.url));
const LEGACY = path("../testdata/goul-audio-0.1.0.wasm");
const CURRENT = path("../zig-out/wasm/goul-audio.wasm");

async function load(file) {
  const { instance } = await WebAssembly.instantiate(await readFile(file), {});
  instance.exports._initialize();
  return instance.exports;
}

/** Une voix de synthèse : un ton qui glisse, avec des silences, sur `frames` trames. */
function signal(w, frames) {
  const samples = w.goul_frame_samples();
  const rate = w.goul_sample_rate();
  const out = [];
  let phase = 0;
  for (let f = 0; f < frames; f++) {
    const pcm = new Int16Array(samples);
    const silent = f % 10 >= 7; // trois trames de silence sur dix, comme entre deux mots
    const freq = 220 + 20 * f;
    for (let i = 0; i < samples; i++) {
      pcm[i] = silent ? 0 : Math.round(Math.sin(phase) * 9000);
      phase += (2 * Math.PI * freq) / rate;
    }
    out.push(pcm);
  }
  return out;
}

/** Encode le signal avec `w` ; renvoie les trames, copiées hors de sa mémoire. */
function encode(w, pcmFrames, streamId) {
  const samples = w.goul_frame_samples();
  const pcmPtr = w.goul_pcm_buffer();
  const framePtr = w.goul_frame_buffer();
  const cap = w.goul_frame_buffer_cap();
  assert.equal(w.goul_send_open(streamId, 24000), 0);
  const frames = pcmFrames.map((pcm, i) => {
    new Int16Array(w.memory.buffer, pcmPtr, samples).set(pcm);
    const written = w.goul_send_push(pcmPtr, samples, framePtr, cap);
    assert.ok(written > 0, `trame ${i} : ${written}`);
    return new Uint8Array(w.memory.buffer, framePtr, written).slice();
  });
  w.goul_send_close();
  return frames;
}

/** Décode les trames avec `w` ; renvoie le son joué, trame par trame. */
function decode(w, frames) {
  const samples = w.goul_frame_samples();
  const pcmPtr = w.goul_pcm_buffer();
  const framePtr = w.goul_frame_buffer();
  assert.equal(w.goul_recv_open(40, 400), 0);
  const played = [];
  for (const [i, frame] of frames.entries()) {
    new Uint8Array(w.memory.buffer, framePtr, frame.length).set(frame);
    assert.equal(w.goul_recv_push(framePtr, frame.length), 0, `trame ${i} refusée`);
    if (w.goul_recv_pull(pcmPtr, samples) === samples) {
      played.push(new Int16Array(w.memory.buffer, pcmPtr, samples).slice());
    }
  }
  w.goul_recv_close();
  return played;
}

const energy = (pcm) => pcm.reduce((sum, v) => sum + v * v, 0) / pcm.length;

test("les mêmes constantes et la même ABI que le binaire en service", async () => {
  const [old, now] = await Promise.all([load(LEGACY), load(CURRENT)]);
  assert.equal(now.goul_frame_samples(), old.goul_frame_samples());
  assert.equal(now.goul_sample_rate(), old.goul_sample_rate());
  assert.equal(now.goul_frame_buffer_cap(), old.goul_frame_buffer_cap());
  const names = (w) => Object.keys(w).filter((n) => n.startsWith("goul_")).sort();
  assert.deepEqual(names(now), names(old));
});

test("ce que l'ancien émet, le nouveau le joue — et l'inverse", async () => {
  const [old, now] = await Promise.all([load(LEGACY), load(CURRENT)]);
  const pcm = signal(now, 60);

  for (const [from, to, label] of [
    [old, now, "ancien → nouveau"],
    [now, old, "nouveau → ancien"],
  ]) {
    const played = decode(to, encode(from, pcm, 0xc0ffee));
    assert.equal(played.length, 59, `${label} : ${played.length} trames jouées`);
    // Du son là où il y en avait : pas un flux accepté puis rendu muet.
    assert.ok(energy(played[20]) > 1e5, `${label} : la voix ne sort pas`);
  }
});

test("le nouveau binaire émet les mêmes octets que l'ancien", async () => {
  const [old, now] = await Promise.all([load(LEGACY), load(CURRENT)]);
  const pcm = signal(now, 60);
  const before = encode(old, pcm, 7);
  const after = encode(now, pcm, 7);
  // Opus en virgule fixe est déterministe : un compilateur différent ne doit
  // pas changer une trame. Si ce test tombe, le format sur le fil a bougé.
  for (const [i, frame] of after.entries()) {
    assert.deepEqual(frame, before[i], `trame ${i} différente`);
  }
});

test("le nouveau binaire joue le même son que l'ancien", async () => {
  const [old, now] = await Promise.all([load(LEGACY), load(CURRENT)]);
  const frames = encode(old, signal(old, 60), 9);
  const before = decode(old, frames);
  const after = decode(now, frames);
  assert.equal(after.length, before.length);
  for (const [i, pcm] of after.entries()) {
    assert.deepEqual(pcm, before[i], `son de la trame ${i} différent`);
  }
});
