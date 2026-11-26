#!/bin/sh
# Build a self-contained macOS x86_64 release tarball for ALBW.
#
# Usage:
#   ./release/package-macos.sh [VERSION] [NODE_HOME]
#
# VERSION    defaults to 0.1.0
# NODE_HOME  defaults to $HOME/.local/node (a Node 22 install with
#            typescript installed globally, so deps/node/bin/tsc exists)
#
# Requires GNAT + gprbuild on PATH (e.g. via `alr toolchain --select
# gnat_native=15.3.1 gprbuild=26.0.1` followed by `alr printenv`, or by
# adding the Alire toolchain bin directories to PATH).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

VERSION=${1:-0.1.0}
NODE_HOME=${2:-$HOME/.local/node}
NAME="albw-release-${VERSION}-macos-x64"
OUT="$ROOT/$NAME.tar.gz"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albw-macos.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

if [ ! -x "$NODE_HOME/bin/node" ] || [ ! -x "$NODE_HOME/bin/tsc" ]; then
    echo "error: need node + tsc under NODE_HOME ($NODE_HOME)" >&2
    echo "       install Node 22 and run: npm install -g typescript" >&2
    exit 1
fi

echo "==> Building albw"
gprbuild -P albw.gpr albw

PKG="$STAGE/$NAME"
mkdir -p "$PKG/bin" "$PKG/malbr-testing" "$PKG/deps"

echo "==> Staging compiler, stdlib and braille engine"
cp bin/albw "$PKG/bin/albw"
cp -R stdlib "$PKG/stdlib"
cp -R braille "$PKG/braille"
cp -R malbr-testing/lib "$PKG/malbr-testing/lib"
cp release/albw "$PKG/albw"
chmod +x "$PKG/albw"

echo "==> Bundling node + tsc"
cp -R "$NODE_HOME" "$PKG/deps/node"

# --tsc invokes `tsc --project <cwd>/tsconfig.json`.  Ship a config that
# works with the bundled typescript-go 7.x (which rejects the
# module:"none"/outFile form that --build generates).
cat > "$PKG/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "strict": false,
    "noImplicitAny": false,
    "noCheck": true,
    "ignoreDeprecations": "6.0",
    "lib": ["es2020", "dom"]
  },
  "include": ["*.ts"]
}
EOF

cat > "$PKG/README.txt" <<EOF
ALBW ${VERSION} - macOS x86_64
=============================

Run:  ./albw --tsc hello.alb
Then: ./deps/node/bin/node hello.js

The launcher sets ALB_LIB and puts the bundled node/tsc on PATH.
The bundled tsconfig.json works with typescript-go 7.x; --build
writes its own config into the output directory.
Requires macOS with the Xcode Command Line Tools installed (the
compiler links against the system linker).

Build: GNAT 15.3.1 + gprbuild 26.0.1 (Alire toolchains).
EOF

echo "==> Creating $OUT"
tar czf "$OUT" -C "$STAGE" "$NAME"

DMG="$ROOT/$NAME.dmg"
echo "==> Creating $DMG"
hdiutil create -volname "ALBW $VERSION macOS" -srcfolder "$PKG" \
  -ov -format UDZO "$DMG"

echo "==> Done"
ls -lh "$OUT" "$DMG"
shasum -a 256 "$OUT" "$DMG"
