# Security Model — ALBW

## Threat model

ALBW is a source-to-source compiler: `.alb` → TypeScript → tsc → Node.
The security surface is the **emitted program** and the **MCP stdio
channel**, not the compiler binary itself (which is a trusted
development tool).

## Emitted runtime

- Generated JS never `eval()`s ALB source. The only `eval('require')`
  is a deliberate Node-`require` indirection (keeps the same emitted
  code usable in browser bundles where `require` is absent — call
  sites are capability-guarded `typeof` checks).
- `SHELL` runs `child_process.execSync` — OS shell semantics, same as
  the source language promises. Fixtures that exercise it are
  sidecar-marked per platform.
- `IMPORTDLL`/`IMPORTSO` do NOT call into real OS libraries — they
  route through `ALB_COMPAT_IMPORT`, a deterministic in-process shim.
- File I/O is plain `fs` — paths are taken literally from the ALB
  program; there is no chroot/sandbox (same contract as the native
  backends).

## MCP surface

- `albw --mcp` and `MCP_LISTEN` drivers speak JSON-RPC over
  stdin/stdout only — no sockets, no filesystem writes outside the
  declared work paths.
- `tools/call` args are schema-validated before dispatch (`-32602`),
  blocking type-confusion into numeric routines.
- `alb.fixture_claim`/`albw.build_driver` use create-exclusive lock
  files for parallel-agent arbitration; no eval of untrusted input.
- Emitted MCP servers redirect PRINT to stderr so stdout stays a pure
  protocol channel.

## Reporting

Contact **contact@alb-lang.org**.
