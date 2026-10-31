# ALBW Roadmap

The feature-complete ALB backend — first-class on **Windows, Linux,
FreeBSD, and NetBSD** today; macOS rides the same POSIX path
(toolchain exercise, no code work expected).

## Now

- **Repo independence**: ALBW sources, suite, stdlib, braille engines
  live here; the monorepo keeps the other 21 backends.
- **Releases**: `albw-release-VERSION-{win,linux,freebsd,netbsd}-x64` bundles —
  compiler + stdlib + Node/tsc toolchain + braille suite.

## Near

- **POSIX twin fixtures** for the 6 `.skipp` cmd.exe shell tests.
- **rt-trim phase 2**: unit-level trim of woven `.albi` module bodies
  (a `NBRF`-only program still carries unused `Nb*`/`Lx*` machinery).
- ~~**B1a**: UEB/BRF → literary text back-translation~~ **done** —
  `Ueb.From*` + `br_decode` shipped (fixture 1223).
- **C2**: UEB G1 compile-time fold.
- **macOS** packaging run.

## Later

- ES-module emit mode (current output is CommonJS).
- Browser-first runtime profile (DOM helpers are already emitted;
  `--build` produces the index.html shell).
- Broader `ALB_COMPAT_IMPORT` coverage as FFI usage grows.
