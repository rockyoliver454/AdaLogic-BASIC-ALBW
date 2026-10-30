#!/usr/bin/env python3
"""
ALBW (ALB -> TypeScript -> JS -> Node) suite runner.

For each NNN_name.alb in albw/tests/:
  1. bin/albw.exe  --quiet <fixture.alb>        -> work/<stem>/T<NNN>.ts
  2. tsc --noCheck --target ES2020 --module commonjs --outDir <work>/js  -> js
  3. node js/T<NNN>.js (< .stdin if present)   -> OUT.TXT
  4. compare OUT.TXT vs tests/NNN_name.expected (CRLF-normalized)

Categories:
  PASS       output matches .expected
  FAIL       build failure (BUILD_ALBW / BUILD_TSC), run error, or MISMATCH
  SKIPMALBR  ENABLE RUST / MALBR-only construct
  SKIPGFX    CREATE_WINDOW fixture (requires DOM; node is text-only)

Usage:  python runnerw.py [--from N] [--to N] [--only N] [--log name.txt]
"""
import argparse, os, re, shutil, socket, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
TESTDIR = ROOT / "tests"
WORK = ROOT / "work"
ON_WINDOWS = os.name == "nt"
ALBW = REPO / "bin" / ("albw.exe" if ON_WINDOWS else "albw")
TSC = "tsc.cmd" if ON_WINDOWS else "tsc"
ALB_LIB = os.pathsep.join(
    [str(REPO / "stdlib"), str(REPO / "malbr-testing"),
     str(REPO / "malbr-testing" / "lib")])


def norm(s: str) -> str:
    return s.replace("\r\n", "\n").rstrip("\n")


def run_cmd(args, cwd, timeout, stdin_data=None, env=None):
    try:
        res = subprocess.run(args, cwd=str(cwd), capture_output=True,
                             text=True, timeout=timeout, input=stdin_data,
                             env=env, errors="replace")
        return res.returncode, res.stdout, res.stderr
    except subprocess.TimeoutExpired:
        return None, "", "TIMEOUT"
    except FileNotFoundError:
        return None, "", f"missing tool: {args[0]}"


def emit_tsc_args(ts_path: Path, js_dir: Path):
    return [TSC, "--noCheck", "--target", "ES2020", "--module", "commonjs",
            "--outDir", str(js_dir), str(ts_path)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="frm", type=int, default=None)
    ap.add_argument("--to", type=int, default=None)
    ap.add_argument("--only", type=int, default=None)
    ap.add_argument("--log", type=str, default=None)
    ap.add_argument("--timeout", type=int, default=90)
    args = ap.parse_args()

    fixtures = sorted(TESTDIR.glob("*.alb"), key=lambda p: int(p.stem.split("_")[0]))
    logf = None
    if args.log:
        logf = open(ROOT / args.log, "w", encoding="utf-8")

    def out(s=""):
        print(s)
        if logf:
            logf.write(s + "\n")
            logf.flush()

    env = dict(os.environ)
    env["ALB_LIB"] = ALB_LIB
    #  POSIX shells keep HOSTNAME shell-internal (not exported); the
    #  ENV$("HOSTNAME") fallback in fixtures needs a real env value.
    if not ON_WINDOWS:
        env.setdefault("HOSTNAME", socket.gethostname())

    counts = {"PASS": 0, "FAIL": 0, "SKIPMALBR": 0, "SKIPGFX": 0,
              "SKIPW": 0, "SKIPP": 0}
    t0 = time.time()

    for f in fixtures:
        num = int(f.stem.split("_")[0])
        if args.only is not None and num != args.only:
            continue
        if args.frm is not None and num < args.frm:
            continue
        if args.to is not None and num > args.to:
            continue

        stem = f.stem
        tag = f"T{num}"
        src = f.read_text(encoding="utf-8", errors="replace")
        #  .expectedw overrides .expected for documented ALBW divergences —
        #  e.g. fixtures whose golden was captured from the FASM backend's
        #  >4-argument ABI limitation (stack params read early), which ALBW
        #  correctly does not reproduce.
        exp_path = f.with_suffix(".expected")
        expw_path = f.with_suffix(".expectedw")
        if expw_path.exists():
            exp_path = expw_path
        #  .skipw marks fixtures ALBW cannot execute faithfully — e.g.
        #  loops that need exact integer arithmetic beyond 2^53 (the f64
        #  mantissa limit); file contents are the reported reason.
        skipw_path = f.with_suffix(".skipw")
        #  .errw marks a NEGATIVE fixture: albw must refuse to compile it
        #  and the diagnostic output must contain the sidecar's text
        #  (e.g. "reserved keyword"). rc==0 or missing text => FAIL.
        errw_path = f.with_suffix(".errw")
        stdin_path = f.with_suffix(".stdin")
        stdin_data = stdin_path.read_text(encoding="utf-8", errors="replace") \
            if stdin_path.exists() else None
        #  .skipp marks fixtures that cannot run on POSIX hosts —
        #  e.g. SHELL("mkdir x 2>nul & dir /b ...") drives cmd.exe
        #  builtins; on Linux "2>nul" would silently create a file
        #  named 'nul'.  Mirror of .skipw for the POSIX side.
        skipp_path = f.with_suffix(".skipp")
        #  .timeout overrides --timeout for legitimately long fixtures
        #  (e.g. BigInt modular exponentiation over large n)
        timeout_path = f.with_suffix(".timeout")
        test_timeout = args.timeout
        if timeout_path.exists():
            try:
                test_timeout = int(timeout_path.read_text().strip())
            except ValueError:
                pass

        cat = None
        detail = ""

        if re.search(r"\bENABLE\s+RUST\b", src):
            cat = "SKIPMALBR"
            detail = "ENABLE RUST"
        if cat is None and not ON_WINDOWS and skipp_path.exists():
            cat = "SKIPP"
            detail = skipp_path.read_text(encoding="utf-8",
                                          errors="replace").strip()[:60]
        if cat is None and skipw_path.exists():
            cat = "SKIPW"
            detail = skipw_path.read_text(encoding="utf-8",
                                          errors="replace").strip()[:60]

        # ---- stage 1: albw -> .ts ----
        wdir = WORK / stem
        # wipe stale artifacts — file-op fixtures depend on a clean cwd
        # (e.g. mkdir fixtures see EEXIST from a previous run's output)
        if wdir.exists():
            shutil.rmtree(wdir, ignore_errors=True)
        wdir.mkdir(parents=True, exist_ok=True)
        ts_path = wdir / f"{tag}.ts"

        if cat is None and errw_path.exists():
            rc, so, se = run_cmd([str(ALBW), "--quiet", "-o", str(ts_path),
                                  str(f)], cwd=wdir, timeout=test_timeout,
                                 env=env)
            want = errw_path.read_text(encoding="utf-8",
                                       errors="replace").strip()
            got = norm((so or "") + "\n" + (se or ""))
            if rc is not None and rc != 0 and want in got:
                cat = "PASS"
            else:
                cat, detail = "FAIL", f"EXPECTED_ALBW_FAIL rc={rc} {got[:120]}"

        if cat is None:
            rc, so, se = run_cmd([str(ALBW), "--quiet", "-o", str(ts_path),
                                  str(f)], cwd=wdir, timeout=test_timeout,
                                 env=env)
            if rc is None:
                cat, detail = "FAIL", f"BUILD_ALBW_TIMEOUT"
            elif rc != 0 or not ts_path.exists():
                cat, detail = "FAIL", f"BUILD_ALBW {norm(se or so)[:120]}"

        # ---- stage 2: tsc -> .js ----
        js_dir = wdir / "js"
        js_path = js_dir / f"{tag}.js"
        if cat is None:
            js_dir.mkdir(exist_ok=True)
            rc, so, se = run_cmd(emit_tsc_args(ts_path, js_dir), cwd=wdir,
                                 timeout=test_timeout)
            if rc is None:
                cat, detail = "FAIL", "BUILD_TSC_TIMEOUT"
            elif rc != 0 or not js_path.exists():
                cat, detail = "FAIL", f"BUILD_TSC {norm(so or se)[:120]}"

        # ---- stage 3: node run (graphics fixtures need DOM) ----
        out_path = wdir / "OUT.TXT"
        if cat is None and "CREATE_WINDOW" in src:
            cat, detail = "SKIPGFX", "CREATE_WINDOW"

        if cat is None:
            rc, so, se = run_cmd(["node", str(js_path)], cwd=wdir,
                                 timeout=test_timeout, stdin_data=stdin_data,
                                 env=env)
            actual = so
            out_path.write_text(actual, encoding="utf-8")
            if rc is None:
                cat, detail = "FAIL", "RUN_TIMEOUT"
            elif rc != 0:
                cat, detail = "FAIL", f"RUN_ERR {norm(se or so)[:120]}"
            elif exp_path.exists():
                expected = exp_path.read_text(encoding="utf-8", errors="replace")
                cat = "PASS" if norm(actual) == norm(expected) else "FAIL"
                if cat == "FAIL":
                    detail = "MISMATCH"
                    (wdir / "EXPECTED.TXT").write_text(expected, encoding="utf-8")
            else:
                cat, detail = "FAIL", "NO_EXPECTED"

        counts[cat] += 1
        line = f"{cat:<10} {stem}" + (f"   {detail}" if detail else "")
        out(line)

    out("")
    out(f"DONE in {time.time()-t0:.1f}s   "
        + "  ".join(f"{k}={v}" for k, v in counts.items()))
    if logf:
        logf.close()


if __name__ == "__main__":
    main()
