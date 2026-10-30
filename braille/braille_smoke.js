//  braille_smoke.js - exercise the braille.alb MCP surface in-process.
//  Loads the generated braille.js, appends the __mcp bridge (same
//  trick as ../smoke.js), evals, drives JSON-RPC lines directly.
const fs = require('fs');
const g = globalThis;

const src = fs.readFileSync(__dirname + '/braille.js', 'utf8');
const APPEND = [
  'g.__mcpOut = [];',
  'g.__mcp = (line) => { const old = albMcpSend; albMcpSend = (o) => g.__mcpOut.push(o); try { albMcpHandle(line); } finally { albMcpSend = old; } };',
  'g.__mcpLast = () => g.__mcpOut[g.__mcpOut.length - 1];'
].join('\n');
eval(src + '\n' + APPEND);

let fails = 0;
function ok(cond, label, extra) {
  if (cond) { console.log('ok    ' + label); }
  else { fails++; console.log('FAIL  ' + label + (extra ? '  -> ' + extra : '')); }
}
function call(name, args, id) {
  g.__mcp(JSON.stringify({ jsonrpc: '2.0', id: id, method: 'tools/call',
    params: { name: name, arguments: args } }));
  return JSON.parse(g.__mcpLast().result.content[0].text);
}
function readRes(uri, id) {
  g.__mcp(JSON.stringify({ jsonrpc: '2.0', id: id, method: 'resources/read',
    params: { uri: uri } }));
  return g.__mcpLast();
}

console.log('=== braille mcp smoke ===');

//  tools/list
g.__mcp('{"jsonrpc":"2.0","id":1,"method":"tools/list"}');
const names = g.__mcpLast().result.tools.map(t => t.name).sort();
ok(names.join(',') === 'br_nemeth,br_translate,br_ueb,br_ueb_g1',
   'tools/list', names.join(','));

//  ueb g2 - the showcase sentence
let r = call('br_ueb', { txt: 'the children would rather go out together' }, 2);
ok(r.ok === true && r.errors === 0, 'br_ueb ok');
ok(r.brf === '! *N WD R G \\ TGR', 'br_ueb brf', r.brf);
ok(r.cells.length === 17, 'br_ueb cells', r.cells.length);
ok(r.uni.charCodeAt(0) === 0x282E, 'br_ueb uni starts U+282E', r.uni);

//  ueb g1 - uncontracted
r = call('br_ueb_g1', { txt: 'the' }, 3);
ok(r.brf === 'THE', 'br_ueb_g1 uncontracted', r.brf);

//  caps + numbers through the same path
r = call('br_ueb', { txt: 'room 101' }, 4);
ok(r.brf === 'ROOM #AJA', 'br_ueb numbers', r.brf);

//  nemeth linear
r = call('br_nemeth', { txt: '3+4 = 7' }, 5);
ok(r.ok === true && r.brf === '#3+4 .K #7', 'br_nemeth linear', r.brf);

//  nemeth fraction + radical
r = call('br_nemeth', { txt: '\\frac{1}{2} + \\sqrt{x}' }, 6);
ok(r.errors === 0 && r.brf === '?#1/2# + %;X]', 'br_nemeth frac+sqrt', r.brf);

//  nemeth spatial matrix through the same tool
r = call('br_nemeth', { txt: '\\begin{bmatrix}1&2\\\\3&4\\end{bmatrix}' }, 7);
ok(r.errors === 0, 'br_nemeth matrix errs', JSON.stringify(r.err));
ok(r.brf.indexOf('@,(') === 0, 'br_nemeth matrix enlarged bracket', r.brf);

//  dispatcher
r = call('br_translate', { sys: 'nemeth', txt: 'x^2' }, 8);
ok(r.sys === 'nemeth' && r.brf === ';X^2', 'br_translate nemeth', r.brf);
r = call('br_translate', { sys: 'ueb-g1', txt: 'go' }, 9);
ok(r.brf === 'GO', 'br_translate ueb-g1', r.brf);
r = call('br_translate', { sys: 'bogus', txt: 'x' }, 10);
ok(r.ok === false && r.errors === 1, 'br_translate bad sys error');

//  strict error path: unclosed group in nemeth
r = call('br_nemeth', { txt: '\\sqrt{2' }, 11);
ok(r.ok === false && r.errors > 0, 'br_nemeth error ledger', JSON.stringify(r.err));

//  resource read
const res = readRes('alb://braille/status', 12);
const info = JSON.parse(res.result.contents[0].text);
ok(info.app === 'braille' && info.engines.length === 3, 'resource status');

//  unknown tool -> protocol error, not a crash
g.__mcp('{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"br_nope","arguments":{}}}');
ok(g.__mcpLast().error !== undefined, 'unknown tool error');

console.log('=== ' + (fails === 0 ? 'ALL PASS' : fails + ' FAILURES') + ' ===');
process.exit(fails === 0 ? 0 : 1);
