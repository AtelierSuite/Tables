// A minimal WASI preview 1 host for the Tables engine, with no dependencies.
//
// The engine never touches a real file system or network: documents arrive as bytes
// through the engine API. So this host provides just what Swift's runtime and
// Foundation need: clocks, randomness, environment, stdout/stderr (to the console),
// and polite failures for everything file-related.

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_INVAL = 28;
const ERRNO_NOENT = 44;
const ERRNO_NOSYS = 52;
const ERRNO_NOTCAPABLE = 76;

const FILETYPE_CHARACTER_DEVICE = 2;

export class WASIExit extends Error {
  constructor(code) {
    super(`WASI exit ${code}`);
    this.code = code;
  }
}

export class WASIHost {
  /**
   * @param {object} options
   * @param {string[]} [options.args]
   * @param {Record<string, string>} [options.env]
   * @param {(text: string) => void} [options.stdout]
   * @param {(text: string) => void} [options.stderr]
   */
  constructor({ args = ["tables"], env = {}, stdout = (t) => console.log(t), stderr = (t) => console.warn(t) } = {}) {
    this.args = args;
    this.env = Object.entries(env).map(([k, v]) => `${k}=${v}`);
    this.sinks = { 1: stdout, 2: stderr };
    this.pending = { 1: "", 2: "" };
    this.memory = null;
    this.encoder = new TextEncoder();
    this.decoder = new TextDecoder();
  }

  /** Call once the instance exists, before running anything. */
  bind(instance) {
    this.memory = instance.exports.memory;
  }

  get view() {
    return new DataView(this.memory.buffer);
  }

  get bytes() {
    return new Uint8Array(this.memory.buffer);
  }

  writeStrings(strings, pointersPtr, bufferPtr) {
    const view = this.view;
    const bytes = this.bytes;
    let offset = bufferPtr;
    strings.forEach((string, index) => {
      view.setUint32(pointersPtr + index * 4, offset, true);
      const encoded = this.encoder.encode(string);
      bytes.set(encoded, offset);
      bytes[offset + encoded.length] = 0;
      offset += encoded.length + 1;
    });
    return ERRNO_SUCCESS;
  }

  sizeStrings(strings, countPtr, sizePtr) {
    const view = this.view;
    view.setUint32(countPtr, strings.length, true);
    view.setUint32(sizePtr, strings.reduce((sum, s) => sum + this.encoder.encode(s).length + 1, 0), true);
    return ERRNO_SUCCESS;
  }

  emit(fd, text) {
    const lines = (this.pending[fd] + text).split("\n");
    this.pending[fd] = lines.pop();
    for (const line of lines) this.sinks[fd](line);
  }

  flush() {
    for (const fd of [1, 2]) {
      if (this.pending[fd]) this.sinks[fd](this.pending[fd]);
      this.pending[fd] = "";
    }
  }

  get imports() {
    const host = this;
    const notCapable = () => ERRNO_NOTCAPABLE;
    return {
      wasi_snapshot_preview1: {
        args_get: (argv, buf) => host.writeStrings(host.args, argv, buf),
        args_sizes_get: (count, size) => host.sizeStrings(host.args, count, size),
        environ_get: (envp, buf) => host.writeStrings(host.env, envp, buf),
        environ_sizes_get: (count, size) => host.sizeStrings(host.env, count, size),

        clock_res_get(id, resultPtr) {
          host.view.setBigUint64(resultPtr, 1000n, true);
          return ERRNO_SUCCESS;
        },
        clock_time_get(id, precision, resultPtr) {
          // 0 = realtime, 1 = monotonic; both in nanoseconds.
          const ms = id === 0 ? Date.now() : performance.now();
          const ns = id === 0 ? BigInt(ms) * 1_000_000n : BigInt(Math.round(ms * 1_000_000));
          host.view.setBigUint64(resultPtr, ns, true);
          return ERRNO_SUCCESS;
        },

        random_get(ptr, length) {
          // getRandomValues fills at most 65536 bytes per call.
          for (let offset = 0; offset < length; offset += 65536) {
            crypto.getRandomValues(new Uint8Array(host.memory.buffer, ptr + offset, Math.min(65536, length - offset)));
          }
          return ERRNO_SUCCESS;
        },

        fd_write(fd, iovs, iovsLength, writtenPtr) {
          if (fd !== 1 && fd !== 2) return ERRNO_BADF;
          const view = host.view;
          let written = 0;
          let text = "";
          for (let i = 0; i < iovsLength; i++) {
            const ptr = view.getUint32(iovs + i * 8, true);
            const len = view.getUint32(iovs + i * 8 + 4, true);
            text += host.decoder.decode(new Uint8Array(host.memory.buffer, ptr, len), { stream: true });
            written += len;
          }
          host.emit(fd, text);
          view.setUint32(writtenPtr, written, true);
          return ERRNO_SUCCESS;
        },
        fd_read(fd, iovs, iovsLength, readPtr) {
          if (fd !== 0) return ERRNO_BADF;
          host.view.setUint32(readPtr, 0, true);
          return ERRNO_SUCCESS;
        },
        fd_fdstat_get(fd, statPtr) {
          if (fd > 2) return ERRNO_BADF;
          const view = host.view;
          view.setUint8(statPtr, FILETYPE_CHARACTER_DEVICE);
          view.setUint16(statPtr + 2, 0, true);
          view.setBigUint64(statPtr + 8, 0xffffffffn, true);
          view.setBigUint64(statPtr + 16, 0xffffffffn, true);
          return ERRNO_SUCCESS;
        },
        fd_fdstat_set_flags: (fd) => (fd > 2 ? ERRNO_BADF : ERRNO_SUCCESS),
        fd_filestat_get(fd, statPtr) {
          if (fd > 2) return ERRNO_BADF;
          new Uint8Array(host.memory.buffer, statPtr, 64).fill(0);
          host.view.setUint8(statPtr + 16, FILETYPE_CHARACTER_DEVICE);
          return ERRNO_SUCCESS;
        },
        fd_close: (fd) => (fd > 2 ? ERRNO_BADF : ERRNO_SUCCESS),
        fd_sync: () => ERRNO_SUCCESS,
        fd_seek: () => ERRNO_BADF,
        fd_tell: () => ERRNO_BADF,
        fd_pread: () => ERRNO_BADF,
        fd_readdir: () => ERRNO_BADF,
        fd_filestat_set_size: () => ERRNO_BADF,
        fd_filestat_set_times: () => ERRNO_BADF,
        // No preopened directories: the engine has no file system.
        fd_prestat_get: () => ERRNO_BADF,
        fd_prestat_dir_name: () => ERRNO_BADF,
        path_open: () => ERRNO_NOENT,
        path_filestat_get: () => ERRNO_NOENT,
        path_filestat_set_times: notCapable,
        path_create_directory: notCapable,
        path_remove_directory: notCapable,
        path_unlink_file: notCapable,
        path_rename: notCapable,
        path_link: notCapable,
        path_symlink: notCapable,
        path_readlink: notCapable,
        poll_oneoff: () => ERRNO_NOSYS,
        sched_yield: () => ERRNO_SUCCESS,
        proc_raise: () => ERRNO_NOSYS,
        sock_accept: () => ERRNO_NOSYS,
        sock_recv: () => ERRNO_NOSYS,
        sock_send: () => ERRNO_NOSYS,
        sock_shutdown: () => ERRNO_NOSYS,
        proc_exit(code) {
          host.flush();
          throw new WASIExit(code);
        },
      },
    };
  }

  /** Runs a command module's _start, returning its exit code. */
  start(instance) {
    this.bind(instance);
    try {
      instance.exports._start();
      return 0;
    } catch (error) {
      if (error instanceof WASIExit) return error.code;
      throw error;
    } finally {
      this.flush();
    }
  }

  /** Initialises a reactor module (one built with -mexec-model=reactor). */
  initialize(instance) {
    this.bind(instance);
    instance.exports._initialize?.();
    this.flush();
  }
}

export { ERRNO_INVAL };
