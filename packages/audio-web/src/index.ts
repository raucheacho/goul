/**
 * Le cœur audio de Goul, vu depuis JavaScript.
 *
 * The module behind this is the same one the phones run — same Opus settings,
 * same frame format, same play-out buffer. A dispatcher and a rider cannot
 * disagree about how a stream decodes, because there is only one
 * implementation of it.
 *
 * It imports nothing. No WASI shim, no filesystem, no clock: the browser hands
 * it memory and calls functions. That is the whole host surface.
 */

/** Exactly the exports named in build.zig's `abi_exports`. */
interface Exports {
  memory: WebAssembly.Memory;
  _initialize(): void;

  goul_send_open(streamId: number, bitrate: number): number;
  goul_send_push(pcm: number, pcmLen: number, out: number, outCap: number): number;
  goul_send_close(): void;

  goul_recv_open(targetMs: number, maxMs: number): number;
  goul_recv_push(bytes: number, len: number): number;
  goul_recv_pull(pcm: number, pcmCap: number): number;
  goul_recv_end_stream(): void;
  goul_recv_close(): void;
  goul_recv_stats(out: number, cap: number): number;

  goul_frame_samples(): number;
  goul_sample_rate(): number;
  goul_pcm_buffer(): number;
  goul_frame_buffer(): number;
  goul_frame_buffer_cap(): number;
  goul_stats_buffer(): number;
}

/** Mirrors the codes in abi.zig. */
export class AudioError extends Error {
  constructor(
    readonly code: number,
    operation: string
  ) {
    super(`${operation} : ${AudioError.describe(code)}`);
    this.name = "AudioError";
  }

  private static describe(code: number): string {
    switch (code) {
      case -1:
        return "argument invalide";
      case -2:
        return "appel hors séquence — ouvrir avant d’émettre ou de recevoir";
      case -3:
        return "erreur du codec";
      case -4:
        return "mémoire insuffisante";
      default:
        return `code ${code}`;
    }
  }
}

export interface PlayoutStats {
  received: number;
  played: number;
  /** Frames thrown away to stay live after a network stall. */
  droppedLate: number;
  droppedFull: number;
  underruns: number;
  /** Frames the decoder invented to cover a gap. */
  concealed: number;
}

export interface ReceiverOptions {
  /** Audio to gather before playback starts. */
  targetMs?: number;
  /** Past this we are behind, and frames get dropped rather than queued. */
  maxMs?: number;
}

export class GoulAudio {
  private constructor(
    private readonly wasm: Exports,
    /** Samples in one frame, read from the module rather than hard-coded. */
    readonly frameSamples: number,
    readonly sampleRate: number
  ) {}

  /**
   * @param source compiled module, raw bytes, or a `fetch` response — the
   * caller decides where the `.wasm` comes from, since a Next.js app, a test
   * runner and a worker each get it differently.
   */
  static async instantiate(
    source: BufferSource | Response | Promise<Response>
  ): Promise<GoulAudio> {
    const { instance } =
      source instanceof Response || source instanceof Promise
        ? await WebAssembly.instantiateStreaming(source, {})
        : await WebAssembly.instantiate(source, {});

    const wasm = instance.exports as unknown as Exports;

    // A reactor module runs its initialisers on demand rather than at load.
    wasm._initialize();

    return new GoulAudio(wasm, wasm.goul_frame_samples(), wasm.goul_sample_rate());
  }

  // ── Émission ──────────────────────────────────────────────────────────────

  /**
   * Opens a transmission. `streamId` identifies this press of the button and
   * must match the one announced on the control channel, or listeners will
   * treat the audio as belonging to nobody.
   */
  openSender(streamId: number, bitrate = 24_000): void {
    const code = this.wasm.goul_send_open(streamId >>> 0, bitrate);
    if (code < 0) throw new AudioError(code, "ouverture de l’émission");
  }

  /**
   * Encodes one frame of microphone into a ready-to-send frame, header
   * included. The returned view aliases the module's memory and is overwritten
   * by the next call — copy it if it outlives the send.
   */
  encode(pcm: Int16Array): Uint8Array {
    if (pcm.length !== this.frameSamples) {
      throw new AudioError(-1, `encodage (${pcm.length} au lieu de ${this.frameSamples})`);
    }

    const pcmPtr = this.wasm.goul_pcm_buffer();
    const framePtr = this.wasm.goul_frame_buffer();
    const frameCap = this.wasm.goul_frame_buffer_cap();

    this.pcmView(pcmPtr).set(pcm);

    const written = this.wasm.goul_send_push(pcmPtr, pcm.length, framePtr, frameCap);
    if (written < 0) throw new AudioError(written, "encodage");

    return new Uint8Array(this.wasm.memory.buffer, framePtr, written);
  }

  closeSender(): void {
    this.wasm.goul_send_close();
  }

  // ── Réception ─────────────────────────────────────────────────────────────

  openReceiver({ targetMs = 120, maxMs = 400 }: ReceiverOptions = {}): void {
    const code = this.wasm.goul_recv_open(targetMs, maxMs);
    if (code < 0) throw new AudioError(code, "ouverture de la réception");
  }

  /** Hands a frame straight off the socket to the play-out buffer. */
  push(frame: Uint8Array): void {
    const cap = this.wasm.goul_frame_buffer_cap();
    if (frame.length > cap) throw new AudioError(-1, "trame trop grande");

    const ptr = this.wasm.goul_frame_buffer();
    new Uint8Array(this.wasm.memory.buffer, ptr, cap).set(frame);

    const code = this.wasm.goul_recv_push(ptr, frame.length);
    if (code < 0) throw new AudioError(code, "réception d’une trame");
  }

  /**
   * Asks for the next frame to play. Returns null for silence, which means the
   * buffer is still filling or the transmission is over — not an error.
   *
   * The returned view aliases the module's memory and is valid until the next
   * call, so copy it before handing it to an audio node.
   */
  pull(): Int16Array | null {
    const ptr = this.wasm.goul_pcm_buffer();
    const samples = this.wasm.goul_recv_pull(ptr, this.frameSamples);

    if (samples < 0) throw new AudioError(samples, "lecture");
    if (samples === 0) return null;

    return this.pcmView(ptr).subarray(0, samples);
  }

  endStream(): void {
    this.wasm.goul_recv_end_stream();
  }

  closeReceiver(): void {
    this.wasm.goul_recv_close();
  }

  /**
   * Play-out counters. Worth logging from a real shift: `targetMs` can only
   * honestly be chosen from what a real network did, not guessed at a desk.
   */
  stats(): PlayoutStats {
    const ptr = this.wasm.goul_stats_buffer();
    const count = this.wasm.goul_recv_stats(ptr, 6);
    if (count < 0) throw new AudioError(count, "statistiques");

    const values = new Uint32Array(this.wasm.memory.buffer, ptr, 6);
    return {
      received: values[0]!,
      played: values[1]!,
      droppedLate: values[2]!,
      droppedFull: values[3]!,
      underruns: values[4]!,
      concealed: values[5]!,
    };
  }

  /**
   * A fresh view every time, deliberately: WebAssembly memory can be grown,
   * and a cached view onto the old buffer would silently detach.
   */
  private pcmView(ptr: number): Int16Array {
    return new Int16Array(this.wasm.memory.buffer, ptr, this.frameSamples);
  }
}
