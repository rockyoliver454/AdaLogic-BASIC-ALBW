# AdaLogic BASIC ALB — ALBW Compiler

> **https://alb-lang.org** · **https://alb-lang.com** · **https://alb-lang.dev**
> Contact: **contact@alb-lang.org**

ALBW is the feature-complete Web backend for AdaLogic BASIC (ALB): it
compiles `.alb` source to **TypeScript**, then `tsc` → CommonJS → Node —
or browser via the `--build` HTML shell. One source, every OS where
Node runs.

| | |
|---|---|
| **License** | Apache 2.0 — see [LICENSE](LICENSE), [LICENSE-ALBW](LICENSE-ALBW.txt), [NOTICE](NOTICE) |
| **Releases** | `albw-release-0.1.0-win-x64.zip` · `albw-release-0.1.0-linux-x64.tar.gz` |
| **Suite** | 1,166 numbered fixtures (`albw/tests/`) — PASS=1078 Linux / PASS=1078 Windows |

## Layout

```text
albw.gpr              GNAT/GPRbuild project (albw only)
src/                  Ada 2012 compiler sources
  albw.adb            driver: args, INCLUDE weaving, --mcp server, tsc spawn
  COMPILER/           tokenizer, parser, AST
  EMITTER/            emit_native_typescript — the TS backend + --rt-trim
  CORE/               alb_platform (host consts), diagnostics, math
  TYPES/ MATH/ SECURITY/   shared bounded-type & vault units
albw/
  runnerw.py          cross-platform suite runner (--from/--to/--only/--log)
  tests/              NNN_name.alb + .expected/.errw/.skipw/.skipp sidecars
stdlib/               .albi stdlib modules (alb_str/fmt/io/ds/sort/conv + ueb + nemeth)
malbr-testing/lib/    mathkit.albi (ALB_LIB member)
braille/              production braille engine: UEB G1/G2 + Nemeth,
                      MCP driver with 8 tools, liblouis-diff harnesses
release/              albw / albw.cmd launchers + packaging scripts
```

## Build

GNAT + GPRbuild (any modern toolchain: GNAT 14+ verified on Linux,
GNAT 15 on Windows):

```text
gprbuild -P albw.gpr albw        →  bin/albw  (bin/albw.exe on Windows)
```

## Use

```text
albw --tsc hello.alb            → hello.ts → hello.js   (tsc on PATH)
albw -o out.ts program.alb      transpile only
albw --build app.alb            web bundle + index.html shell
albw --mcp                      JSON-RPC MCP server (compile/validate/
                                tokenize/fixture-claim/build-driver tools)
```

`ALB_LIB` locates `.albi` modules — `;`-separated (Windows) or
`:`/`;`-separated (POSIX). `release/albw` + `release/albw.cmd` are
zero-setup launchers that pin it relative to the package.

Emitted-TS runtime is dead-code-trimmed by default
(`--rt-trim=off`, `--rt-keep=<name>` to override) — hello-world emits
~9 KB instead of ~87 KB.

## Fixture sidecars

| file | meaning |
|---|---|
| `.expected` / `.expectedw` | golden stdout (…w = ALBW-divergent) |
| `.errw` | negative fixture — compile must fail containing this text |
| `.skipw` | can't run under Node/TS (e.g. >2^53 integer math) |
| `.skipp` | can't run on POSIX (cmd.exe builtins: `dir /b`, `2>nul`, …) |
| `.stdin` | piped to the node run |
| `.timeout` | per-fixture timeout override |

```text
python3 albw/runnerw.py --from 1 --to 1222    # full suite
```

## Braille / Nemeth channel

`braille/braille.alb` is a production MCP server (stdin JSON-RPC):

`br_ueb` · `br_ueb_g1` · `br_nemeth` · `br_translate` · `br_latex` ·
`br_mathml` · `br_unbrf` · `br_ununi` — forward transcription
(liblouis-verified: 13,747-word stratified + 12,000-word corpora at
100%) and verified bidirectional Nemeth
(`Transcribe(FromCells(x)) ≡ Transcribe(x)`).

```text
echo {"jsonrpc":"2.0","id":1,"method":"tools/call",
     "params":{"name":"br_nemeth","arguments":{"txt":"x^2+1"}}} | node braille.js
```
