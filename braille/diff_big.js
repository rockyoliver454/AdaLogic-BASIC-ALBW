//  diff_big.js - wordlist differential:  node diff_big.js <file> [limit]
//  Single words per line;  reports mismatch count + every failing word.
const fs = require('fs');
const g = globalThis;

const src = fs.readFileSync(__dirname + '/braille.js', 'utf8');
const APPEND = [
  'g.__mcpOut = [];',
  'g.__mcp = (line) => { const old = albMcpSend; albMcpSend = (o) => g.__mcpOut.push(o); try { albMcpHandle(line); } finally { albMcpSend = old; } };',
  'g.__mcpLast = () => g.__mcpOut[g.__mcpOut.length - 1];'
].join('\n');
eval(src + '\n' + APPEND);

function ours(text) {
  g.__mcp(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name: 'br_ueb', arguments: { txt: text } } }));
  const r = JSON.parse(g.__mcpLast().result.content[0].text);
  return r.cells.filter(c => c >= 0);
}

const m = require('liblouis-build');
try { m.FS.mkdir('/tables'); } catch (e) {}
m.FS.mount(m.FS.filesystems.NODEFS,
           { root: __dirname + '/node_modules/liblouis-build/tables' },
           '/tables');

const cap = 512, outbuf = m._malloc(cap * 2);
const inlen = m._malloc(4), outlen = m._malloc(4);
function louis(text) {
  const inbuf = m._malloc((text.length + 1) * 2);
  m.stringToUTF16(text, inbuf, (text.length + 1) * 2);
  m.setValue(inlen, text.length, 'i32');
  m.setValue(outlen, cap, 'i32');
  m.ccall('lou_translateString', 'number',
    ['string','number','number','number','number','number','number','number'],
    ['/tables/en-ueb-g2.ctb', inbuf, inlen, outbuf, outlen, 0, 0, 4]);
  const n = m.getValue(outlen, 'i32');
  const c = [];
  for (let i = 0; i < n; i++) c.push(m.HEAPU16[(outbuf >> 1) + i] & 0xff);
  m._free(inbuf);
  return c;
}

const uni = c => String.fromCharCode(10240 + c);
const render = a => a.map(uni).join('');

const file = process.argv[2];
const limit = parseInt(process.argv[3] || '0', 10);
let words = fs.readFileSync(file, 'utf8').split(/\r?\n/)
              .map(w => w.trim()).filter(w => w.length);
if (limit) words = words.slice(0, limit);

let pass = 0;
const fails = [];
for (const w of words) {
  const ref = louis(w), got = ours(w);
  if (!ref) { console.log('louis-null', w); continue; }
  let same = ref.length === got.length;
  if (same) for (let i = 0; i < ref.length; i++)
    if (ref[i] !== got[i]) { same = false; break; }
  if (same) { pass++; continue; }
  fails.push({ w, ref, got });
}
console.log(`=== ${pass} identical / ${fails.length} differ ===`);
for (const f of fails.slice(0, 400)) {
  let pos = 0;
  while (pos < Math.min(f.ref.length, f.got.length) &&
         f.ref[pos] === f.got[pos]) pos++;
  console.log(`${f.w.padEnd(24)} ref ${render(f.ref)}  |  got ${render(f.got)}  @${pos}`);
}
if (fails.length > 400)
  console.log(`... ${fails.length - 400} more`);
