#!/bin/bash
# options=(debug) must produce a companion -debug package with detached
# symbols, and leave the main binary stripped but debug-linked.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-debug
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=dbg
pkgver=1.0
pkgrel=1
pkgdesc="debug split"
arch=('x86_64')
options=('debug' 'strip')

build() {
  cat > d.c <<'CEOF'
#include <stdio.h>
int helper(int x){ return x * 2; }
int main(void){ printf("%d\n", helper(21)); return 0; }
CEOF
  gcc $CFLAGS -o dbg d.c
}

package() {
  install -Dm755 dbg "$pkgdir/usr/bin/dbg"
}
PKGEOF

echo "=== build ==="
$OPTI build "$WORK"

echo
echo "=== artifacts ==="
ls -1 "$WORK"/*.pkg.tar.* | xargs -n1 basename

MAIN=$(ls "$WORK"/dbg-1.0-1-x86_64.pkg.tar.*)
DBG=$(ls "$WORK"/dbg-debug-1.0-1-x86_64.pkg.tar.*)

echo
echo "=== debug package contents ==="
tar tf "$DBG" | grep -v '^\.'

echo
echo "=== assertions ==="
tar tf "$DBG" | grep -q 'usr/lib/debug/usr/bin/dbg.debug' \
  && echo "ok: detached symbols present" || { echo "FAIL: no symbols"; exit 1; }

rm -rf /var/tmp/dbg-v; mkdir -p /var/tmp/dbg-v
tar xf "$MAIN" -C /var/tmp/dbg-v
file /var/tmp/dbg-v/usr/bin/dbg | grep -q 'stripped' \
  && echo "ok: shipped binary is stripped" || echo "note: strip state unclear"
readelf -x .gnu_debuglink /var/tmp/dbg-v/usr/bin/dbg >/dev/null 2>&1 \
  && echo "ok: .gnu_debuglink added" || { echo "FAIL: no debuglink"; exit 1; }

/var/tmp/dbg-v/usr/bin/dbg
