# Changelog — ALBW

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
