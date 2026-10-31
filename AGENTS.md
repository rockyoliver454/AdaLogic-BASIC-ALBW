# Agent Guidance — AdaLogic BASIC ALBW

Operational rules for AI agents and contributors working in this repo.
**Read this file first.** Keep entries short; durable rules live here.

ALBW is the feature-complete TypeScript/Web backend for **AdaLogic BASIC
(ALB)**, written in **Ada 2012** (GNAT 14+). The compiler is
SPARK-flavored: bounded tables, explicit error ledgers, no unbounded
recursion, fatal-diagnostics-not-silent-drops. Target discipline for all
new compiler code is **SPARK 2014 style** — provable invariants,
pre/post contracts where cheap, nothing that can silently corrupt
output.

## Golden rules (outrank feature work)

1. **Never silently miscompile.** A construct that can't lower correctly
   must fatal (`raise Program_Error with "..."` or a ledger entry),
   never emit partial/wrong output with exit 0.
2. **Fatal recovery diagnostics mean fix the source, not the flag.**
   Panic-mode resync keeps parsing so ALL errors surface; the ledger is
   the contract. Post-parse, drivers must scan `Parse_Diag.Errors` for
   `Severity => Fatal` — a recovered parse can still hold fatals.
3. **Reserved keywords cannot be identifiers.** Compile-time error with
   line/col. Strings/comments exempt. Never bypass.
4. **No heap/closure capture.** Static allocation; lambdas are hoisted
   top-level functions (globals + own params only, enforced).
5. **Recursion is banned language-wide** — self-calls and routine
   cycles hard-blocked at compile time.
6. **Bounded everything.** Fixed arrays + counts; unbounded growth is
   a bug.
7. **Error cosmetics:** emit bare feature names in raise text; the
   driver prepends `ALBW fatal:` itself.
8. **Feature coverage is verified, not assumed.** Every new feature
   ships numbered `.alb` fixtures with `.expected`/`.errw` goldens.
9. **New enduring behavior is documented here.**

## Portability (albw runs on POSIX)

ALBW passes its full suite on **Windows, Linux, and FreeBSD** (GNAT 15 /
14.2 / 12.4 verified; macOS is the same POSIX path).

- **FreeBSD notes** (verified on 15.1-RELEASE): the Ada toolchain is
  `lang/gnat12` — binaries live in **`/usr/local/gnat12/bin`**, not on
  PATH (`export PATH=/usr/local/gnat12/bin:$PATH` before gprbuild).
  `npm i -g typescript` now lands **typescript-go 7.x** (native binary,
  `tsc --version` 7.0.2) — output is byte-identical to classic tsc and
  it accepts the same flags. `pkg install gnat12 gprbuild node22
  npm-node22 git` is the whole toolchain. `albw --tsc` needs a
  `tsconfig.json` beside the output (only `--build`/`--library` write
  one); without it, pass tsc flags directly.

- Host constants live in **`src/CORE/alb_platform.*`**
  (`Dir_Sep`/`Path_Sep`/`On_Windows`/`Is_List_Sep`/`Temp_Dir`). Never
  literal `& "\" &` joins or `;`-only env-list splits in driver code;
  use `Ada.Directories.Compose` + `Alb_Platform`.
- `ALB_LIB` separator: `;` always + `:` on POSIX; Windows never `:`.
- **Never whole-array `(others => (others => <>))` clears on big
  bounded tables** — Ada builds the aggregate as a full-size stack
  temporary (~6 MB for `Symbols`; blew the 8 MB POSIX stack). Reset
  the live prefix per element — see `Reset_State`.
- Goldens must be **EOL-neutral** (`Put_Line` = `\r\n` win, `\n`
  POSIX): never assert emitted-file byte lengths; count lines.
- `runnerw.py` is cross-platform; it passes `env` to the node stage
  so `ENV$` fixtures see `HOSTNAME`/`ALB_LIB`.

## ALBW backend contract

- `.alb` → TypeScript → `tsc --noCheck --target ES2020 --module
  commonjs` → Node. `ALB_LIB` covers `stdlib/` + `malbr-testing/lib`.
- Emitted runtime is **rt-trimmed** by default (declaration-unit
  usage scan + fixpoint closure); `--rt-trim=off`, `--rt-keep=<name>`.
  Failure mode is over-inclusion only.
- **`OS FFI`:** `IMPORTDLL`/`IMPORTSO` route through the
  `ALB_COMPAT_IMPORT` JS shim — never OS-native calls in emitted code.
- **`SHELL`** defers to the OS shell (`child_process.execSync`);
  fixtures driving cmd.exe builtins get `.skipp`.
- **MCP** (`MCP SERVER`/`TOOL`/`RESOURCE`, `MCP_PUMP`, `MCP_LISTEN`):
  stdout is the JSON-RPC channel once `albMcpStart` runs; PRINT
  reroutes to stderr via `albMcpActive`. `albw --mcp` exposes
  `alb.validate`/`alb.tokenize`/`alb.compile`/`alb.fixture_claim`/
  `albw.build_driver`. `tools/call` args are validated against the
  generated schema (`-32602` on missing/wrong — a NaN arg can hang a
  numeric routine).
- `MCP_Scratch` lives under `Alb_Platform.Temp_Dir` (`TEMP`→`TMP`→cwd
  win; `TMPDIR`→`/tmp` POSIX).

## Braille engines (`stdlib/ueb.albi`, `stdlib/nemeth.albi`)

- UEB G1/G2: liblouis-verified, greedy longest-match (no typeforms/
  foreign/tables — documented gap).
- Nemeth: latex-ish + asciimath superset; spatial matrix/cases/binom;
  LaTeX + MathML export; bidirectional `FromCells`/`FromBrf`/`FromUni`
  → canonical source, round-trip contract
  `Transcribe(From*(x)) ≡ Transcribe(x)`. Malformed input → error
  ledger, never guessed.
- Decode glue guard (`NbGuardCmd`): a `\name` symbol pack followed by
  a letter cell decodes space-delimited — TeX rule, otherwise the
  source re-parses as one unknown command. `FromUni` treats ASCII
  space as the blank cell and skips tab/CR (pasted unicode-braille
  formatting); other foreign chars error with the char shown.
- `BRAILLE`/`NEMETH ... END` raw blocks; `BRF`/`UNI`/`NBRF`/`NUNI`/
  `UNBRF`/`UNUNI` builtins; captures expose `name_brf/_uni/_cells/
  _errs/_latex/_mathml/_rsrc`.
