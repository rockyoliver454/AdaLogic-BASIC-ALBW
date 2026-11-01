# History — AdaLogic BASIC (ALBW)

## Lineage

```
RockyBASIC ──> AdaLog DSL ──> AdaLogic BASIC ──> AdaLogic BASIC Web (ALBW)

Backends, in order:   FASM ──> C ──> FASM-16 (DOS/8088) ──> TypeScript
```

**RockyBASIC** was the seed (~2014–2015) — a personal BASIC dialect
built to be programmed with, not just studied. The original
RockyBASIC was **lost in a house fire in 2014** and presumed gone —
until it was recovered this year, when a backup surfaced on an
online storage account I had forgotten I even had.

**AdaLog DSL** was RockyBASIC redesigned as a domain-specific logic
language for an Ada-based game engine — meant to script enemies,
events, and other concepts: AI that could react and feel more
alive. It went largely **unused in the engine itself**, because
development pivoted almost immediately into what became AdaLogic
BASIC — but its rule/predicate machinery still lives in the
compiler today (the Datalog/Prolog layer).

**AdaLogic BASIC** outgrew the DSL entirely — instead of a scripting
language for one engine, it became a robust high- and low-level
compiled language capable of anything C or Ada can do: Ada 2012
implementation, SPARK-flavored internals, bounded tables,
fatal-diagnostics discipline, twenty-two native backends.

**AdaLogic BASIC Web (ALBW)** was the fourth backend — after **FASM**
(x86-64 flat assembler), **C**, and the **FASM-16** (real-mode DOS /
8088) emitter. The TypeScript/JavaScript backend became the most
feature-complete surface in the tree: 1,167-fixture suite, a real
stdlib, contract features (REQUIRE/ENSURE/RANGE), LAMBDA,
EMOTION/MARKOV/neural/temporal constructs, a Datalog/Prolog layer,
production Braille engines (UEB G1/G2 + Nemeth, bidirectional), an
in-compiler MCP server, and `--rt-trim` output trimming. It is now
the primary day-to-day ALB compiler — the one the language is
programmed on.

## Development

**RockyBASIC and AdaLog DSL predate AI-assisted coding** — they were
written entirely by hand, before assistants were a real part of the
craft. **AdaLogic BASIC has had AI coding assistance from the
get-go**, and each generation of tooling has left its mark:

- **GitHub Copilot** — assistance provided for the earliest work,
  where the first AdaLogic BASIC emitters took shape.
- **Gemini** — assistance provided for continued emitter and
  language expansion.
- **Cursor, Claude, and ChatGPT** — assistance provided in different
  situations as the compiler, suite, and runtime grew: backend work,
  stdlib, fixtures, debugging.
- **Devin** — assistance provided for the current phase: the
  dedicated ALBW repository, the POSIX ports, the UEB
  back-translation work, silent-miscompile fixes, and the
  five-platform verification effort.

The compiler itself is written in Ada 2012 and builds with GNAT —
no AI toolchain in the artifact, only in the process.

## On this repository

The project was developed for years **without version control**.
Git existed for all of it — it just wasn't on the radar: the project
ran from RockyBASIC's start (~2014–2015) through roughly 2022–2023
without it, so this lineage is recorded in my personal recollection
rather than commit history. The GitHub repository — and a git-based workflow
altogether — is recent, established alongside the dedicated ALBW
split that this repo represents.

## Verified platforms

Full suite — **1,079 PASS / 0 FAIL** on each of:

| Platform | Toolchain |
|---|---|
| Windows 11 | GNAT 15 |
| Linux (Debian 13) | GNAT 14.2 |
| FreeBSD 15.1 | GNAT 12.4 |
| NetBSD 11.0 | GNAT 14.3 |
| OpenBSD 8.0 | GNAT 16.1 |

The generated Braille engine (`braille.js`, 604,116 bytes) is
byte-identical across all five.
