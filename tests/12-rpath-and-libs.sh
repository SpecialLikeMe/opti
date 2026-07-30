#!/bin/bash
# Stage 6: a source-built binary must resolve a store library through RPATH,
# not through the host's library path.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
ROOT=/var/lib/opti
rm -rf "$ROOT"

# ---- a package providing a shared library --------------------------------
LIBW=/var/tmp/opti-lib
rm -rf "$LIBW"; mkdir -p "$LIBW"
cat > "$LIBW/PKGBUILD" <<'PKGEOF'
pkgname=libgreet
pkgver=1.0
pkgrel=1
pkgdesc="greeting library"
arch=('x86_64')
build() {
  printf '#include <stdio.h>\nvoid greet(void){puts("hello from libgreet");}\n' > l.c
  gcc $CFLAGS -shared -fPIC -Wl,-soname,libgreet.so.1 -o libgreet.so.1 l.c
}
package() {
  install -Dm755 libgreet.so.1 "$pkgdir/usr/lib/libgreet.so.1"
  ln -s libgreet.so.1 "$pkgdir/usr/lib/libgreet.so"
}
PKGEOF

echo "=== install the library package ==="
$OPTI install "$LIBW" 2>&1 | tail -2

echo
echo "=== lib farm ==="
ls -l "$ROOT/lib"

# ---- a package consuming it ----------------------------------------------
APPW=/var/tmp/opti-app
rm -rf "$APPW"; mkdir -p "$APPW"
cat > "$APPW/PKGBUILD" <<PKGEOF
pkgname=greetapp
pkgver=1.0
pkgrel=1
arch=('x86_64')
depends=('libgreet')
build() {
  printf 'void greet(void);\nint main(void){greet();return 0;}\n' > a.c
  # Links against the store copy; LDFLAGS carries the store RPATH.
  gcc \$CFLAGS \$LDFLAGS -o greetapp a.c -L"$ROOT/lib" -lgreet
}
package() {
  install -Dm755 greetapp "\$pkgdir/usr/bin/greetapp"
}
PKGEOF

echo
echo "=== install the consumer ==="
$OPTI install "$APPW" 2>&1 | tail -2

echo
echo "=== RPATH baked into the binary ==="
readelf -d "$ROOT/store/greetapp-1.0-1/usr/bin/greetapp" | grep -E 'RUNPATH|RPATH' || { echo "FAIL: no RPATH"; exit 1; }

echo
echo "=== the library resolves from the store, not the host ==="
ldd "$ROOT/bin/greetapp" | grep libgreet

echo
echo "=== it actually runs ==="
"$ROOT/bin/greetapp"

echo
echo "=== the library cannot be removed while the consumer needs it ==="
if $OPTI uninstall libgreet >/tmp/rp.log 2>&1; then
  echo "FAIL: removed a package still required"; exit 1
fi
grep -q 'greetapp' /tmp/rp.log && echo "ok: refused, naming greetapp" || { cat /tmp/rp.log; exit 1; }

echo
echo "=== removing in dependency order works ==="
$OPTI uninstall greetapp
$OPTI uninstall libgreet
ls "$ROOT/lib" 2>/dev/null | grep -q libgreet && { echo "FAIL: lib link survived"; exit 1; } || echo "ok: lib links removed"

echo
echo "=== list ==="
$OPTI list
