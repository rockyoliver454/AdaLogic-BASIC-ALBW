//  diff_louis.js - differential validation: our UEB engine vs liblouis
//  en-ueb-g2.  Compares raw 6-bit cell streams (our `cells` output vs
//  liblouis ucBrl dot patterns), then renders both sides as Unicode
//  braille + dot lists for readable diffs.
const fs = require('fs');
const g = globalThis;

// ---------- our engine (braille.js via the __mcp bridge) ----------
const src = fs.readFileSync(__dirname + '/braille.js', 'utf8');
const APPEND = [
  'g.__mcpOut = [];',
  'g.__mcp = (line) => { const old = albMcpSend; albMcpSend = (o) => g.__mcpOut.push(o); try { albMcpHandle(line); } finally { albMcpSend = old; } };',
  'g.__mcpLast = () => g.__mcpOut[g.__mcpOut.length - 1];'
].join('\n');
eval(src + '\n' + APPEND);

function ours(text, g1) {
  g.__mcp(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call',
    params: { name: g1 ? 'br_ueb_g1' : 'br_ueb', arguments: { txt: text } } }));
  const r = JSON.parse(g.__mcpLast().result.content[0].text);
  return { cells: r.cells.filter(c => c >= 0), errs: r.err };
}

// ---------- liblouis reference ----------
const m = require('liblouis-build');
try { m.FS.mkdir('/tables'); } catch (e) {}
m.FS.mount(m.FS.filesystems.NODEFS,
           { root: __dirname + '/node_modules/liblouis-build/tables' },
           '/tables');

function louis(text, g1) {
  const table = g1 ? '/tables/en-ueb-g1.ctb' : '/tables/en-ueb-g2.ctb';
  const inbuf = m._malloc((text.length + 1) * 2);
  m.stringToUTF16(text, inbuf, (text.length + 1) * 2);
  const inlen = m._malloc(4), outlen = m._malloc(4);
  const cap = text.length * 4 + 64;
  const outbuf = m._malloc(cap * 2);
  m.setValue(inlen, text.length, 'i32');
  m.setValue(outlen, cap, 'i32');
  const ok = m.ccall('lou_translateString', 'number',
    ['string', 'number', 'number', 'number', 'number', 'number',
     'number', 'number'],
    [table, inbuf, inlen, outbuf, outlen, 0, 0, 4]);
  if (!ok) return null;
  const n = m.getValue(outlen, 'i32');
  const cells = [];
  for (let i = 0; i < n; i++)
    cells.push(m.HEAPU16[(outbuf >> 1) + i] & 0xff);
  m._free(inbuf); m._free(inlen); m._free(outlen); m._free(outbuf);
  return cells;
}

// ---------- rendering ----------
const dots = c => {
  if (c === 0) return '(space)';
  const d = [];
  for (let b = 0; b < 6; b++) if (c & (1 << b)) d.push(b + 1);
  return 'dots' + d.join('');
};
const uni = c => String.fromCharCode(10240 + c);

// ---------- corpus ----------
const corpus = [];
if (fs.existsSync(__dirname + '/corpus.txt')) {
  for (const line of fs.readFileSync(__dirname + '/corpus.txt', 'utf8')
        .split(/\r?\n/)) {
    const t = line.trim();
    if (t.length && !t.startsWith('#')) corpus.push(t);
  }
} else {
  corpus.push('the children would rather go out together');
}

const argWords = process.argv.slice(2);
for (const w of argWords) corpus.push(w);

// ---------- diff ----------
let pass = 0, fail = 0;
const fails = [];
for (const text of corpus) {
  const g1 = false;
  const ref = louis(text, g1);
  const got = ours(text, g1);
  const same = ref && got.cells.length === ref.length &&
               got.cells.every((c, i) => c === ref[i]);
  if (same) { pass++; continue; }
  fail++;
  fails.push({ text, ref, got: got.cells, errs: got.errs });
}

console.log(`=== ${pass} identical / ${fail} differ ===`);
const show = Math.min(fails.length, 40);
for (let i = 0; i < show; i++) {
  const f = fails[i];
  console.log(`\n  in:  ${JSON.stringify(f.text)}`);
  console.log(`  ref: ${f.ref ? f.ref.map(uni).join('') : 'null'}`);
  console.log(`  got: ${f.got.map(uni).join('')}`);
  //  first divergence
  if (f.ref) {
    const n = Math.min(f.ref.length, f.got.length);
    for (let k = 0; k < n; k++)
      if (f.ref[k] !== f.got[k]) {
        console.log(`       ^cell ${k}: ref ${dots(f.ref[k])} vs got ${dots(f.got[k])}`);
        break;
      }
    if (f.ref.length !== f.got.length)
      console.log(`       length: ref ${f.ref.length} vs got ${f.got.length}`);
  }
  if (f.errs && f.errs.length) console.log(`       errs: ${JSON.stringify(f.errs)}`);
}
if (fails.length > show) console.log(`\n  ... ${fails.length - show} more`);
fs.writeFileSync(__dirname + '/diff_out.json',
  JSON.stringify(fails.map(f => ({
    in: f.text,
    ref_uni: f.ref ? f.ref.map(uni).join('') : null,
    got_uni: f.got.map(uni).join(''),
    ref_cells: f.ref, got_cells: f.got })), null, 1));
process.exit(0);
