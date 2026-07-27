#!/bin/bash
# The four remaining gaps:
#   1. optimkp.toml is read and applied
#   2. split-package overrides inside package_() with no .SRCINFO
#   3. debug packages ship /usr/src/debug sources
#   4. archives stream (a large payload must not need proportional RAM)
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti

# ---------- 1 + 2: config file and split overrides, no .SRCINFO ------------
WORK=/var/tmp/opti-cfg
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/optimkp.toml" <<'EOF'
[build]
cflags   = "-O1 -DFROM_CONFIG"
packager = "Config Tester <cfg@example.com>"

[package]
compression = "gzip"

[options]
zipman = false
EOF

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgbase=multi
pkgname=(multi multi-extra)
pkgver=1.0
pkgrel=1
pkgdesc="base description"
arch=('x86_64')
depends=('glibc')

build() {
  echo "CFLAGS=$CFLAGS" > flags.txt
  echo ".TH M 1" > m.1
}

package_multi() {
  install -Dm644 flags.txt "$pkgdir/usr/share/multi/flags.txt"
  install -Dm644 m.1 "$pkgdir/usr/share/man/man1/multi.1"
}

package_multi-extra() {
  pkgdesc="overridden inside the function"
  depends=('bash' 'coreutils')
  optdepends=('vim: editing')
  install -Dm644 flags.txt "$pkgdir/usr/share/multi-extra/flags.txt"
}
PKGEOF

echo "=== 1+2: build with optimkp.toml, no .SRCINFO ==="
$OPTI build "$WORK"

echo
echo "--- config applied ---"
grep -q 'FROM_CONFIG' "$WORK/src/flags.txt" && echo "ok: cflags from optimkp.toml reached the build" || { echo "FAIL cflags"; exit 1; }
ls "$WORK"/multi-1.0-1-x86_64.pkg.tar.gz >/dev/null && echo "ok: compression=gzip honoured" || { echo "FAIL compression"; exit 1; }
tar tf "$WORK"/multi-1.0-1-x86_64.pkg.tar.gz | grep -q 'multi.1$' && echo "ok: zipman=false honoured (man not gzipped)" || { echo "FAIL zipman"; exit 1; }
tar xOf "$WORK"/multi-1.0-1-x86_64.pkg.tar.gz .PKGINFO | grep -q 'packager = Config Tester' && echo "ok: packager from config" || { echo "FAIL packager"; exit 1; }

echo
echo "--- split overrides extracted from package_() body ---"
tar xOf "$WORK"/multi-extra-1.0-1-x86_64.pkg.tar.gz .PKGINFO | grep -E 'pkgdesc|depend|optdepend'
tar xOf "$WORK"/multi-extra-1.0-1-x86_64.pkg.tar.gz .PKGINFO | grep -q 'pkgdesc = overridden inside the function' \
  && echo "ok: pkgdesc override captured" || { echo "FAIL pkgdesc override"; exit 1; }
tar xOf "$WORK"/multi-extra-1.0-1-x86_64.pkg.tar.gz .PKGINFO | grep -q 'depend = bash' \
  && echo "ok: depends override captured" || { echo "FAIL depends override"; exit 1; }
tar xOf "$WORK"/multi-1.0-1-x86_64.pkg.tar.gz .PKGINFO | grep -q 'pkgdesc = base description' \
  && echo "ok: sibling package kept the base values" || { echo "FAIL base inherit"; exit 1; }

# ---------- 3: debug package ships sources --------------------------------
DWORK=/var/tmp/opti-dbgsrc
rm -rf "$DWORK"; mkdir -p "$DWORK"
cat > "$DWORK/PKGBUILD" <<'PKGEOF'
pkgname=srcdbg
pkgver=1.0
pkgrel=1
arch=('x86_64')
options=('debug' 'strip')
build() {
  printf '#include <stdio.h>\nint main(void){puts("x");return 0;}\n' > prog.c
  gcc $CFLAGS -o prog prog.c
}
package() { install -Dm755 prog "$pkgdir/usr/bin/prog"; }
PKGEOF

echo
echo "=== 3: debug package sources ==="
$OPTI build "$DWORK" >/dev/null
DBG=$(ls "$DWORK"/srcdbg-debug-*.pkg.tar.*)
tar tf "$DBG" | grep -E 'usr/(lib/debug|src/debug)' | head -6
tar tf "$DBG" | grep -q 'usr/src/debug/srcdbg/prog.c' \
  && echo "ok: source file shipped in debug package" || { echo "FAIL: no sources"; exit 1; }
tar tf "$DBG" | grep -qE 'usr/src/debug/srcdbg/prog$' \
  && { echo "FAIL: compiled binary shipped as a source"; exit 1; } \
  || echo "ok: compiled output excluded from sources"

# ---------- 4: streaming ---------------------------------------------------
SWORK=/var/tmp/opti-stream
rm -rf "$SWORK"; mkdir -p "$SWORK"
# gzip keeps compression in-process, so peak RSS measures opti's own memory.
# The zstd path spawns `zstd`, whose high-level footprint would otherwise
# dominate the number and say nothing about whether opti streams.
printf '[package]\ncompression = "gzip"\n' > "$SWORK/optimkp.toml"

cat > "$SWORK/PKGBUILD" <<'PKGEOF'
pkgname=bigpkg
pkgver=1.0
pkgrel=1
arch=('any')
options=('!strip')
package() {
  mkdir -p "$pkgdir/usr/share/bigpkg"
  # 256 MB of incompressible payload, so nothing is optimised away.
  for i in 1 2 3 4; do
    dd if=/dev/urandom of="$pkgdir/usr/share/bigpkg/blob$i.bin" bs=1M count=64 status=none
  done
}
PKGEOF

echo
echo "=== 4: 256 MB incompressible payload, in-process gzip path ==="
command -v /usr/bin/time >/dev/null || { echo "SKIP: 'time' not installed"; exit 0; }
/usr/bin/time -v "$OPTI" build "$SWORK" 2>/tmp/time.log >/dev/null || { cat /tmp/time.log; exit 1; }
PEAK=$(grep 'Maximum resident set size' /tmp/time.log | grep -oE '[0-9]+')
echo "payload: 256 MB    peak RSS: $((PEAK / 1024)) MB"
[ "$PEAK" -lt 65536 ] && echo "ok: RSS is bounded, independent of payload size" \
  || { echo "FAIL: RSS ${PEAK}KB suggests the archive was buffered"; exit 1; }
ls -lh "$SWORK"/bigpkg-1.0-1-any.pkg.tar.* | awk '{print "artifact:", $5}'
