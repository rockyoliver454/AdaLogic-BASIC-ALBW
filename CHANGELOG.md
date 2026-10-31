# Changelog — ALBW

## Unreleased

- **FreeBSD port**: full suite green on FreeBSD 15.1 (GNAT 12.4 via
  `lang/gnat12`) — zero code changes over the Linux POSIX path.
  FreeBSD release tarball ships the native `tsc` (typescript-go 7.x,
  byte-identical output).
- **NetBSD port**: full suite green on NetBSD 11.0 (1,079 PASS /
  0 FAIL, GNAT 14.3 via `pkg_add gcc14-gnat`) — zero code changes.
  pkgsrc has no `gprbuild` binary; the build uses `gnatmake` with
  `-aI` source paths (see README). Release tarball bundles node26 +
  typescript with a `tsc` wrapper (bin symlinks don't resolve).
- **UEB back-translation**: `Ueb.FromCells`/`FromBrf`/`FromUni` +
  `BrDecode`/`br_ueb_unbrf`/`br_ueb_ununi`/`br_decode` tools — Grade
  1/2 literary braille → text with contraction expansion, indicators,
  lettersign/wordsign punctuation semantics, paragraph preservation.
- **Emitter fix**: `AST_Const_Ref` now infers `VK_Number` — strict
  `BigInt64Array` cells compared against `#` constants no longer
  emit raw `===` (silently never-equal). Fixture 1223 covers it.
- **Nemeth decode glue guard**: `\name` symbol packs followed by a
  letter cell decode space-delimited (TeX rule); `FromUni` accepts
  ASCII space as the blank cell, skips tab/CR, names foreign chars.

## 0.1.0 — dedicated repository

- First ALBW-dedicated repo: compiler src + 1,166-fixture suite +
  stdlib + braille engines, split from the monorepo as the first
  stable, feature-complete ALB backend.
- **POSIX port**: `albw` builds and runs on Linux (Debian 13, GNAT
  14.2) — `alb_platform` host constants, `:`/`;` `ALB_LIB`, TMPDIR
  scratch, `.skipp` fixture sidecar.
  - Fixed a latent stack bomb: whole-array `(others => (others => <>))`
    resets in `Reset_State` allocated ~9 MB of stack temporaries —
    blew Linux's 8 MB default stack (Windows tolerated it). Now
    per-element clears over the live prefix.
- **`--rt-trim`** (default on): emitted-TS dead-code elimination —
  declaration-unit usage scan + fixpoint closure; hello-world
  ~87 KB → ~9 KB; `--rt-keep=<name>` pins helpers.
- **Braille channel**: UEB G1/G2 + Nemeth engines; MCP driver
  (`braille.alb`) with 8 tools (`br_ueb`, `br_ueb_g1`, `br_nemeth`,
  `br_translate`, `br_latex`, `br_mathml`, `br_unbrf`, `br_ununi`);
  `BRAILLE`/`NEMETH` raw blocks + `name.brf/.latex/.mathml/.rsrc`
  captures.
- **In-compiler MCP**: `albw --mcp` — `alb.validate`, `alb.tokenize`,
  `alb.compile`, `alb.fixture_claim`, `albw.build_driver`.
- Suite: **1078 PASS / 0 FAIL** on Windows and Linux (76 SKIPGFX DOM,
  5 SKIPW f64, 6 SKIPP cmd.exe, 1 SKIPMALBR).
