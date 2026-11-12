/**
 * Vérifie le module WebAssembly tel qu'il sera chargé.
 *
 * The Zig tests already cover the buffer and the codec on the host. What this
 * cannot assume is that the *same* logic survives the trip through
 * WebAssembly and JavaScript — the linear memory, the pointer discipline, the
 * export list. So it exercises the module the way the console will: encode,
 * frame, push, pull.
 *
 *     node --test js/wasm.test.mjs
 *
 * It reads the artefact from zig-out, so `zig build wasm` comes first.
 */

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import test from "node:test";

const wasmPath = fileURLToPath(new URL("../zig-out/wasm/goul-audio.wasm", import.meta.url));

/** The exports, by name, as build.zig declares them. */
const API = [
  "goul_send_open",
  "goul_send_push",
  "goul_send_close",
  "goul_recv_open",
  "goul_recv_push",
  "goul_recv_pull",
  "goul_recv_end_stream",
  "goul_recv_close",
  "goul_recv_stats",
  "goul_frame_samples",
  "goul_sample_rate",
  "goul_pcm_buffer",
  "goul_frame_buffer",
  "goul_frame_buffer_cap",
  "goul_stats_buffer",
];

async function load() {
  const bytes = await readFile(wasmPath);
  const { instance, module } = await WebAssembly.instantiate(bytes, {});
  instance.exports._initialize();
  return { w: instance.exports, module };
}

/** 20 ms of a 440 Hz tone, the same signal the Zig tests use. */
function tone(samples, rate, phase = { value: 0 }) {
  const pcm = new Int16Array(samples);
  for (let i = 0; i < samples; i++) {
    pcm[i] = Math.round(Math.sin(phase.value) * 8000);
    phase.value += (2 * Math.PI * 440) / rate;
  }
  return pcm;
}

test("le module n'importe rien de l'hôte", async () => {
  const { module } = await load();

  // The claim this test exists to keep true: no WASI shim, no filesystem, no
  // clock. If an import ever appears, the console silently gains a
  // dependency on its host that the phones do not have.
  assert.equal(WebAssembly.Module.imports(module).length, 0);
});

test("le module n'expose que son ABI", async () => {
  const { module } = await load();
  const exported = WebAssembly.Module.exports(module).map((e) => e.name);

  for (const name of API) assert.ok(exported.includes(name), `${name} manquant`);

  // Nothing beyond the API, `memory` and the reactor initialiser. Without
  // this, libopus's 75 public entry points come back the moment someone
  // reaches for `rdynamic`.
  const extra = exported.filter((n) => !API.includes(n) && n !== "memory" && n !== "_initialize");
  assert.deepEqual(extra, []);
});

test("un aller-retour complet à travers WebAssembly", async () => {
  const { w } = await load();

  const samples = w.goul_frame_samples();
  const rate = w.goul_sample_rate();
  assert.equal(samples, 960);
  assert.equal(rate, 48000);

  const streamId = 0xc0ffee;
  assert.equal(w.goul_send_open(streamId, 24000), 0);
  assert.equal(w.goul_recv_open(40, 400), 0);

  const pcmPtr = w.goul_pcm_buffer();
  const framePtr = w.goul_frame_buffer();
  const frameCap = w.goul_frame_buffer_cap();
  const phase = { value: 0 };

  let played = 0;
  let lastFrameLen = 0;

  for (let i = 0; i < 20; i++) {
    // Encode.
    new Int16Array(w.memory.buffer, pcmPtr, samples).set(tone(samples, rate, phase));
    const written = w.goul_send_push(pcmPtr, samples, framePtr, frameCap);
    assert.ok(written > 0, `trame ${i} : ${written}`);
    lastFrameLen = written;

    // The header the wire format promises: stream id, then sequence.
    const view = new DataView(w.memory.buffer, framePtr, written);
    assert.equal(view.getUint32(0, true), streamId);
    assert.equal(view.getUint16(4, true), i);

    // Straight back in, as if it had come off the socket.
    assert.equal(w.goul_recv_push(framePtr, written), 0);

    if (w.goul_recv_pull(pcmPtr, samples) === samples) played++;
  }

  // 40 ms of target buffer is two frames: the first pull is still filling, the
  // second one plays. Nineteen of the twenty come out, one stays queued.
  assert.equal(played, 19);

  // A speech frame stays at or under the 60 bytes a constant bitrate would
  // spend. The margin on speech is thin — VBR earns its place on the silences,
  // which are most of a push-to-talk channel's airtime.
  assert.ok(lastFrameLen <= 60, `trame de ${lastFrameLen} octets`);

  const statsPtr = w.goul_stats_buffer();
  assert.equal(w.goul_recv_stats(statsPtr, 6), 6);
  const [received, playedCount, droppedLate, droppedFull, underruns] = new Uint32Array(
    w.memory.buffer,
    statsPtr,
    6
  );

  assert.equal(received, 20);
  assert.equal(playedCount, 19);
  assert.equal(droppedLate, 0, "un flux régulier ne doit rien jeter");
  assert.equal(droppedFull, 0);
  assert.equal(underruns, 0, "un flux régulier ne doit pas manquer de son");

  w.goul_send_close();
  w.goul_recv_close();
});

test("une rafale est jetée, jamais jouée plus vite", async () => {
  const { w } = await load();

  const samples = w.goul_frame_samples();
  const rate = w.goul_sample_rate();
  w.goul_send_open(1, 24000);
  w.goul_recv_open(60, 200);

  const pcmPtr = w.goul_pcm_buffer();
  const framePtr = w.goul_frame_buffer();
  const frameCap = w.goul_frame_buffer_cap();
  const phase = { value: 0 };

  // 30 frames at once: 600 ms of backlog landing after a stall, which is what
  // one TCP retransmission on a bad mobile link actually looks like.
  for (let i = 0; i < 30; i++) {
    new Int16Array(w.memory.buffer, pcmPtr, samples).set(tone(samples, rate, phase));
    const written = w.goul_send_push(pcmPtr, samples, framePtr, frameCap);
    w.goul_recv_push(framePtr, written);
  }

  const statsPtr = w.goul_stats_buffer();
  w.goul_recv_stats(statsPtr, 6);
  const droppedLate = new Uint32Array(w.memory.buffer, statsPtr, 6)[2];

  // 200 ms is ten frames, so twenty had to go. Kept instead, they would come
  // out as a sped-up catch-up — the exact bug this rule exists to prevent.
  assert.equal(droppedLate, 20);

  w.goul_send_close();
  w.goul_recv_close();
});

test("émettre sans avoir ouvert est refusé, pas planté", async () => {
  const { w } = await load();

  const pcmPtr = w.goul_pcm_buffer();
  const framePtr = w.goul_frame_buffer();

  // -2 is ERR_STATE. The module must answer, not trap: a trap would take the
  // whole console's WebAssembly instance down with it.
  assert.equal(w.goul_send_push(pcmPtr, 960, framePtr, 1030), -2);
  assert.equal(w.goul_recv_pull(pcmPtr, 960), -2);

  // And it is still usable afterwards.
  assert.equal(w.goul_send_open(1, 24000), 0);
  assert.ok(w.goul_send_push(pcmPtr, 960, framePtr, 1030) > 0);
});

test("une trame corrompue est rejetée", async () => {
  const { w } = await load();
  w.goul_recv_open(40, 400);

  const framePtr = w.goul_frame_buffer();
  // Shorter than the six-byte header.
  new Uint8Array(w.memory.buffer, framePtr, 3).set([1, 2, 3]);
  assert.equal(w.goul_recv_push(framePtr, 3), -1);
});
