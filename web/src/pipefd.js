// pipefd.js – browser_wasi_shim Fd over a SAB Pipe.
import { Fd, wasi } from '@bjorn3/browser_wasi_shim';
const { Fdstat, Filestat, FILETYPE_CHARACTER_DEVICE } = wasi;

export class PipeFd extends Fd {
  constructor(readPipe, writePipe, opts = {}) {
    super();
    this.readPipe = readPipe;
    this.writePipe = writePipe;
    this.deadlineMs = opts.deadlineMs;
  }

  fd_read(size) {
    if (!this.readPipe) return { ret: 0, data: new Uint8Array(0) };
    const data = this.readPipe.readBytes(size, this.deadlineMs);
    return { ret: 0, data };
  }

  fd_write(data) {
    if (!this.writePipe) return { ret: 0, nwritten: 0 };
    this.writePipe.writeBytes(data);
    return { ret: 0, nwritten: data.byteLength };
  }

  fd_fdstat_get() {
    return { ret: 0, fdstat: new Fdstat(FILETYPE_CHARACTER_DEVICE, 0) };
  }

  fd_filestat_get() {
    // Needed by GHC-wasm fdToHandle (it calls fdType -> fstat). Report a
    // character device so the Handle is treated as an unseekable stream.
    return { ret: 0, filestat: new Filestat(0n, FILETYPE_CHARACTER_DEVICE, 0n) };
  }

  fd_prestat_get() {
    // A pipe is not a preopened directory. wasi-libc scans fds 3.. for preopens
    // on the first path operation and _Exit(EX_OSERR=71)s on any non-BADF error,
    // so we must answer BADF (not the base class's NOTSUP).
    return { ret: wasi.ERRNO_BADF, prestat: null };
  }

  fd_close() {
    if (this.readPipe) this.readPipe.close();
    if (this.writePipe) this.writePipe.close();
    return 0;
  }
}
