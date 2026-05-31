// Minimal Chrome DevTools Protocol driver (no deps; node 22 global WebSocket).
// Opens the served page, polls #out in real time, prints console + exceptions.
const base = 'http://localhost:9222';
let target;
for (let i = 0; i < 20; i++) {
  try {
    const ts = await (await fetch(base + '/json')).json();
    target = ts.find((t) => t.type === 'page' && t.url.includes('localhost:8080'));
    if (target) break;
  } catch {}
  await new Promise((r) => setTimeout(r, 500));
}
if (!target) { console.log('NO PAGE TARGET'); process.exit(2); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
let id = 0; const pending = new Map();
const send = (method, params = {}) => new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  else if (m.method === 'Runtime.consoleAPICalled') console.log('[console]', m.params.args.map((a) => a.value).join(' '));
  else if (m.method === 'Runtime.exceptionThrown') console.log('[exception]', JSON.stringify(m.params.exceptionDetails.exception || m.params.exceptionDetails.text));
};
await new Promise((r) => (ws.onopen = r));
await send('Runtime.enable');

const deadline = Date.now() + 45000;
let text = '';
while (Date.now() < deadline) {
  const r = await send('Runtime.evaluate', { expression: 'document.getElementById("out")?.innerText || ""', returnByValue: true });
  text = (r.result && r.result.value) || '';
  if (/\[all queries done\]|ERROR|EXC:/.test(text)) break;
  await new Promise((r) => setTimeout(r, 1000));
}
console.log('=== PAGE #out ===\n' + text);
// Require the full-theory results (z3): Int=4, Real=2.5, Double=2.5, plus a prove.
const ok = /Q\.E\.D\./.test(text) && /4 :: Integer/.test(text)
        && /2\.5 :: Real/.test(text) && /2\.5 :: Double/.test(text)
        && /\(3,7\) then x=7 -> 7/.test(text);
console.log(ok ? 'BROWSER PASS' : 'BROWSER FAIL');
process.exit(ok ? 0 : 1);
