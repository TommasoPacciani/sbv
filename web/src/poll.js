// poll.js – wasi_snapshot_preview1 poll_oneoff for SAB pipe fds.
// Supports CLOCK (relative timeout) and FD_READ (pipe readiness) subscriptions.

const EVENTTYPE_CLOCK = 0;
const EVENTTYPE_FD_READ = 1;
const EVENTTYPE_FD_WRITE = 2;

// Subscription layout (48 bytes):
//   offset 0:  userdata (u64)
//   offset 8:  u.tag (u8, eventtype)
//   offset 16: u.content (aligned to 8)
//     clock: id(u32)@16, timeout(u64)@24, precision(u64)@32, flags(u16)@40
//     fd_readwrite: fd(u32)@16
const SUB_SIZE = 48;
const SUB_USERDATA = 0;
const SUB_TAG = 8;
const SUB_CLOCK_TIMEOUT = 24;
const SUB_CLOCK_FLAGS = 40;
const SUB_FD = 16;

// Event layout (32 bytes):
//   offset 0:  userdata (u64)
//   offset 8:  error (u16)
//   offset 10: type (u8)
//   offset 16: fd_readwrite.nbytes (u64)
//   offset 24: fd_readwrite.flags (u16)
const EVT_SIZE = 32;
const EVT_USERDATA = 0;
const EVT_ERROR = 8;
const EVT_TYPE = 10;
const EVT_NBYTES = 16;
const EVT_FLAGS = 24;

const SUBCLOCKFLAGS_ABSTIME = 1;

/**
 * Install a working poll_oneoff on a WASI instance.
 * @param {object} wasi - WASI instance (must have .wasiImport and .inst after start)
 * @param {Map<number, {bytesAvailable: () => number}>} pipesByFd - map from fd number to object with bytesAvailable()
 */
export function installPoll(wasi, pipesByFd) {
  wasi.wasiImport.poll_oneoff = (inPtr, outPtr, nsubscriptions, neventsPtr) => {
    const mem = wasi.inst.exports.memory.buffer;
    const view = new DataView(mem);

    let clockTimeoutNs = null; // smallest clock timeout in nanoseconds
    let clockIdx = -1;
    const fdReadSubs = []; // {idx, fd, userdata}

    // Parse subscriptions
    for (let i = 0; i < nsubscriptions; i++) {
      const base = inPtr + i * SUB_SIZE;
      const userdata = view.getBigUint64(base + SUB_USERDATA, true);
      const tag = view.getUint8(base + SUB_TAG);

      if (tag === EVENTTYPE_CLOCK) {
        const timeout = view.getBigUint64(base + SUB_CLOCK_TIMEOUT, true);
        const flags = view.getUint16(base + SUB_CLOCK_FLAGS, true);
        let ns = timeout;
        if (flags & SUBCLOCKFLAGS_ABSTIME) {
          // Convert absolute to relative (monotonic)
          const nowNs = BigInt(Math.round(performance.now() * 1e6));
          ns = timeout > nowNs ? timeout - nowNs : 0n;
        }
        if (clockTimeoutNs === null || ns < clockTimeoutNs) {
          clockTimeoutNs = ns;
          clockIdx = i;
        }
      } else if (tag === EVENTTYPE_FD_READ) {
        const fd = view.getUint32(base + SUB_FD, true);
        fdReadSubs.push({ idx: i, fd, userdata });
      }
      // FD_WRITE: always ready for pipes (unbounded write buffer effectively)
      else if (tag === EVENTTYPE_FD_WRITE) {
        fdReadSubs.push({ idx: i, fd: view.getUint32(base + SUB_FD, true), userdata, isWrite: true });
      }
    }

    // Check fd readiness immediately
    let nevents = 0;
    for (const sub of fdReadSubs) {
      const pipe = pipesByFd.get(sub.fd);
      if (sub.isWrite || (pipe && pipe.bytesAvailable() > 0)) {
        const eBase = outPtr + nevents * EVT_SIZE;
        view.setBigUint64(eBase + EVT_USERDATA, sub.userdata, true);
        view.setUint16(eBase + EVT_ERROR, 0, true);
        view.setUint8(eBase + EVT_TYPE, sub.isWrite ? EVENTTYPE_FD_WRITE : EVENTTYPE_FD_READ);
        const avail = sub.isWrite ? 65536n : BigInt(pipe.bytesAvailable());
        view.setBigUint64(eBase + EVT_NBYTES, avail, true);
        view.setUint16(eBase + EVT_FLAGS, 0, true);
        nevents++;
      }
    }

    // If any fd was ready, return immediately
    if (nevents > 0) {
      view.setUint32(neventsPtr, nevents, true);
      return 0;
    }

    // No fd ready — block for the clock timeout (or 0 if no clock)
    if (clockTimeoutNs !== null) {
      const ms = Number(clockTimeoutNs) / 1e6;
      if (ms > 0) {
        // Busy-wait with Atomics.wait on a dummy SAB for the timeout duration,
        // but check pipe readiness periodically (every 1ms) to support hReady.
        const deadline = performance.now() + ms;
        const waitBuf = new Int32Array(new SharedArrayBuffer(4));
        while (performance.now() < deadline) {
          // Check if any fd became ready
          for (const sub of fdReadSubs) {
            if (sub.isWrite) continue;
            const pipe = pipesByFd.get(sub.fd);
            if (pipe && pipe.bytesAvailable() > 0) {
              const eBase = outPtr + nevents * EVT_SIZE;
              view.setBigUint64(eBase + EVT_USERDATA, sub.userdata, true);
              view.setUint16(eBase + EVT_ERROR, 0, true);
              view.setUint8(eBase + EVT_TYPE, EVENTTYPE_FD_READ);
              view.setBigUint64(eBase + EVT_NBYTES, BigInt(pipe.bytesAvailable()), true);
              view.setUint16(eBase + EVT_FLAGS, 0, true);
              nevents++;
            }
          }
          if (nevents > 0) {
            view.setUint32(neventsPtr, nevents, true);
            return 0;
          }
          const remaining = deadline - performance.now();
          if (remaining <= 0) break;
          Atomics.wait(waitBuf, 0, 0, Math.min(remaining, 1));
        }
      }

      // Timeout expired — emit clock event
      const clockBase = inPtr + clockIdx * SUB_SIZE;
      const clockUserdata = view.getBigUint64(clockBase + SUB_USERDATA, true);
      const eBase = outPtr + nevents * EVT_SIZE;
      view.setBigUint64(eBase + EVT_USERDATA, clockUserdata, true);
      view.setUint16(eBase + EVT_ERROR, 0, true);
      view.setUint8(eBase + EVT_TYPE, EVENTTYPE_CLOCK);
      view.setBigUint64(eBase + EVT_NBYTES, 0n, true);
      view.setUint16(eBase + EVT_FLAGS, 0, true);
      nevents++;
    }

    view.setUint32(neventsPtr, nevents, true);
    return 0;
  };
}
