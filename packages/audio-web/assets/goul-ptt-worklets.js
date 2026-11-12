/**
 * Les deux bouts de la chaîne audio, sur le fil du temps réel.
 *
 * An AudioWorklet runs on the audio rendering thread, which is the only clock
 * that matters here: `process()` is called every 128 samples whatever the main
 * thread is doing. Both the encoder and the play-out buffer live on this side
 * for that reason — a jitter buffer pulled from `setInterval` would drift
 * exactly when the page is busy, which is when it matters most.
 *
 * The WebAssembly module arrives as **bytes**, and is compiled here.
 *
 * Not as a compiled `WebAssembly.Module`, which would save the compile: a
 * Module is serializable only within one agent cluster, and a worklet is its
 * own. Posting one across is dropped silently — no exception on the sending
 * side, no `messageerror`, just a message that never arrives. Sending the
 * bytes costs a few milliseconds of compile per worklet and cannot fail that
 * way.
 *
 * `fetch` does not exist in an AudioWorkletGlobalScope, which is why the bytes
 * come from the page rather than being loaded here.
 *
 * A note on arithmetic that shapes everything below: a render quantum is 128
 * samples and an Opus frame is 960. They do not divide, so both processors
 * bridge the mismatch with a small reservoir rather than pretending the two
 * clocks line up.
 */

const FRAME_SAMPLES = 960;

/** Int16 full scale. Kept explicit — the asymmetry of two's complement is why
 *  clamping uses 32767 on the way up and 32768 on the way down. */
const INT16_MAX = 32767;
const INT16_MIN = -32768;

function floatToInt16(sample) {
  const scaled = sample * 32768;
  return scaled > INT16_MAX ? INT16_MAX : scaled < INT16_MIN ? INT16_MIN : scaled | 0;
}

/**
 * Capture : microphone → trames prêtes à envoyer.
 *
 * Encoding happens here rather than on the main thread so that what crosses
 * the thread boundary is a ~57-byte frame instead of 1920 bytes of raw PCM,
 * fifty times a second.
 */
class GoulCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();

    this.wasm = null;
    this.sending = false;

    // One frame's worth of microphone, filled 128 samples at a time.
    this.pending = new Int16Array(FRAME_SAMPLES);
    this.pendingCount = 0;

    this.port.onmessage = ({ data }) => this.handle(data);
  }

  handle(message) {
    if (message.type === "init") {
      this.instantiate(message.bytes);
      return;
    }

    if (!this.wasm) return;

    if (message.type === "start") {
      // A fresh stream must not inherit half a frame from the previous press.
      this.pendingCount = 0;
      const code = this.wasm.goul_send_open(message.streamId >>> 0, message.bitrate);
      this.sending = code === 0;
      if (!this.sending) this.port.postMessage({ type: "error", code });
      return;
    }

    if (message.type === "stop") {
      this.sending = false;
      this.wasm.goul_send_close();
    }
  }

  /** Compilation is asynchronous; `ready` is what says the module is usable. */
  instantiate(bytes) {
    WebAssembly.instantiate(bytes, {}).then(
      ({ instance }) => {
        instance.exports._initialize();
        this.wasm = instance.exports;
        this.port.postMessage({ type: "ready" });
      },
      (error) => this.port.postMessage({ type: "error", message: String(error) })
    );
  }

  process(inputs) {
    const channel = inputs[0]?.[0];

    // No input yet, or nothing to do: keep the node alive either way. Returning
    // false would end this processor for good, and the button can be pressed
    // again.
    if (!this.sending || !channel) return true;

    for (let i = 0; i < channel.length; i++) {
      this.pending[this.pendingCount++] = floatToInt16(channel[i]);

      if (this.pendingCount === FRAME_SAMPLES) {
        this.pendingCount = 0;
        this.emitFrame();
      }
    }

    return true;
  }

  emitFrame() {
    const w = this.wasm;
    const pcmPtr = w.goul_pcm_buffer();
    const framePtr = w.goul_frame_buffer();

    new Int16Array(w.memory.buffer, pcmPtr, FRAME_SAMPLES).set(this.pending);

    const written = w.goul_send_push(
      pcmPtr,
      FRAME_SAMPLES,
      framePtr,
      w.goul_frame_buffer_cap()
    );
    if (written <= 0) {
      this.port.postMessage({ type: "error", code: written });
      return;
    }

    // Copied, because the module reuses this buffer for the next frame and
    // postMessage is asynchronous.
    const frame = new Uint8Array(written);
    frame.set(new Uint8Array(w.memory.buffer, framePtr, written));

    this.port.postMessage({ type: "frame", frame }, [frame.buffer]);
  }
}

/**
 * Lecture : trames reçues → haut-parleur.
 *
 * The play-out buffer lives inside the WebAssembly module; this processor only
 * turns its 960-sample answers into 128-sample render quanta.
 */
class GoulPlaybackProcessor extends AudioWorkletProcessor {
  constructor() {
    super();

    this.wasm = null;
    this.open = false;

    // Decoded audio waiting to be handed out 128 samples at a time.
    this.reservoir = new Int16Array(FRAME_SAMPLES);
    this.reservoirLength = 0;
    this.reservoirRead = 0;

    this.port.onmessage = ({ data }) => this.handle(data);
  }

  handle(message) {
    if (message.type === "init") {
      this.instantiate(message.bytes);
      return;
    }

    if (!this.wasm) return;

    switch (message.type) {
      case "open": {
        const code = this.wasm.goul_recv_open(message.targetMs, message.maxMs);
        this.open = code === 0;
        if (!this.open) this.port.postMessage({ type: "error", code });
        break;
      }

      case "frame": {
        if (!this.open) break;
        const w = this.wasm;
        const ptr = w.goul_frame_buffer();
        const frame = message.frame;
        new Uint8Array(w.memory.buffer, ptr, w.goul_frame_buffer_cap()).set(frame);
        w.goul_recv_push(ptr, frame.length);
        break;
      }

      case "end":
        this.wasm.goul_recv_end_stream();
        break;

      case "stats": {
        const ptr = this.wasm.goul_stats_buffer();
        if (this.wasm.goul_recv_stats(ptr, 6) === 6) {
          const values = new Uint32Array(this.wasm.memory.buffer, ptr, 6);
          this.port.postMessage({ type: "stats", values: Array.from(values) });
        }
        break;
      }

      case "close":
        this.open = false;
        this.wasm.goul_recv_close();
        break;
    }
  }

  instantiate(bytes) {
    WebAssembly.instantiate(bytes, {}).then(
      ({ instance }) => {
        instance.exports._initialize();
        this.wasm = instance.exports;
        this.port.postMessage({ type: "ready" });
      },
      (error) => this.port.postMessage({ type: "error", message: String(error) })
    );
  }

  process(_inputs, outputs) {
    const out = outputs[0]?.[0];
    if (!out) return true;

    for (let i = 0; i < out.length; i++) {
      if (this.reservoirRead >= this.reservoirLength && !this.refill()) {
        // Silence for the rest of this quantum: the buffer is filling, or the
        // transmission is over.
        out.fill(0, i);
        return true;
      }

      out[i] = this.reservoir[this.reservoirRead++] / 32768;
    }

    return true;
  }

  /** Asks the play-out buffer for the next 20 ms. False means silence. */
  refill() {
    if (!this.open) return false;

    const w = this.wasm;
    const ptr = w.goul_pcm_buffer();
    const samples = w.goul_recv_pull(ptr, FRAME_SAMPLES);
    if (samples <= 0) return false;

    this.reservoir.set(new Int16Array(w.memory.buffer, ptr, samples));
    this.reservoirLength = samples;
    this.reservoirRead = 0;
    return true;
  }
}

registerProcessor("goul-capture", GoulCaptureProcessor);
registerProcessor("goul-playback", GoulPlaybackProcessor);
