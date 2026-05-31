// sabpipe.js – one-directional byte pipe over SharedArrayBuffer ring buffer.
// Layout: [head:Int32, tail:Int32, closed:Int32, _pad:Int32, ...ring:Uint8]
// Head = next index to READ from, Tail = next index to WRITE to.
// Empty when head === tail. Full when (tail+1)%cap === head.
// Writer blocks (Atomics.wait on head) when ring is full.
// Reader blocks (Atomics.wait on tail) when ring is empty.

const HDR_BYTES = 16; // 4 Int32 words
const I_HEAD = 0;
const I_TAIL = 1;
const I_CLOSED = 2;

export function makePipe(capacityBytes = 65536) {
  const sab = new SharedArrayBuffer(HDR_BYTES + capacityBytes);
  const ctrl = new Int32Array(sab, 0, 4);
  Atomics.store(ctrl, I_HEAD, 0);
  Atomics.store(ctrl, I_TAIL, 0);
  Atomics.store(ctrl, I_CLOSED, 0);
  return sab;
}

export class Pipe {
  constructor(sab) {
    this.sab = sab;
    this.ctrl = new Int32Array(sab, 0, 4);
    this.cap = sab.byteLength - HDR_BYTES;
    this.ring = new Uint8Array(sab, HDR_BYTES, this.cap);
  }

  close() {
    Atomics.store(this.ctrl, I_CLOSED, 1);
    Atomics.notify(this.ctrl, I_TAIL); // wake blocked reader
    Atomics.notify(this.ctrl, I_HEAD); // wake blocked writer
  }

  bytesAvailable() {
    const h = Atomics.load(this.ctrl, I_HEAD);
    const t = Atomics.load(this.ctrl, I_TAIL);
    return (t - h + this.cap) % this.cap;
  }

  // Blocks until >=1 byte available, returns up to maxLen bytes.
  // Returns zero-length Uint8Array on deadline or closed+empty.
  readBytes(maxLen, deadlineMs) {
    while (true) {
      const h = Atomics.load(this.ctrl, I_HEAD);
      const t = Atomics.load(this.ctrl, I_TAIL);
      const avail = (t - h + this.cap) % this.cap;
      if (avail > 0) {
        const n = Math.min(avail, maxLen);
        const out = new Uint8Array(n);
        for (let i = 0; i < n; i++) {
          out[i] = this.ring[(h + i) % this.cap];
        }
        Atomics.store(this.ctrl, I_HEAD, (h + n) % this.cap);
        Atomics.notify(this.ctrl, I_HEAD); // wake blocked writer
        return out;
      }
      if (Atomics.load(this.ctrl, I_CLOSED)) return new Uint8Array(0);
      const timeout = deadlineMs !== undefined ? deadlineMs : undefined;
      const res = Atomics.wait(this.ctrl, I_TAIL, t, timeout);
      if (res === 'timed-out') return new Uint8Array(0);
    }
  }

  // Writes all bytes, blocking if ring is full.
  writeBytes(u8) {
    let offset = 0;
    while (offset < u8.length) {
      const h = Atomics.load(this.ctrl, I_HEAD);
      const t = Atomics.load(this.ctrl, I_TAIL);
      // free = cap - 1 - used (one slot wasted to distinguish full from empty)
      const used = (t - h + this.cap) % this.cap;
      const free = this.cap - 1 - used;
      if (free > 0) {
        const n = Math.min(free, u8.length - offset);
        for (let i = 0; i < n; i++) {
          this.ring[(t + i) % this.cap] = u8[offset + i];
        }
        Atomics.store(this.ctrl, I_TAIL, (t + n) % this.cap);
        Atomics.notify(this.ctrl, I_TAIL); // wake blocked reader
        offset += n;
      } else {
        if (Atomics.load(this.ctrl, I_CLOSED)) return;
        Atomics.wait(this.ctrl, I_HEAD, h);
      }
    }
  }
}
