#!/bin/bash
# Stage 5 + 7: install an artifact into the store, track it, remove it cleanly.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
ROOT=/var/lib/opti
rm -rf "$ROOT"

WORK=/var/tmp/opti-store
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=greeter
pkgver=2.1.0
pkgrel=1
pkgdesc="greets the world"
arch=('x86_64')
depends=('glibc')
build() {
  printf '#include <stdio.h>\nint main(void){puts("greetings");return 0;}\n' > g.c
  gcc -o greeter g.c
}
package() {
  install -Dm755 greeter "$pkgdir/usr/bin/greeter"
  install -Dm644 /dev/null "$pkgdir/usr/share/greeter/data.txt"
  ln -s /usr/bin/greeter "$pkgdir/usr/bin/greet"
}
PKGEOF

echo "=== install ==="
$OPTI install "$WORK"

echo
echo "=== store layout ==="
find "$ROOT" -maxdepth 2 -mindepth 1 | sort

echo
echo "=== list ==="
$OPTI list

echo
echo "=== files ==="
$OPTI files greeter

echo
echo "=== binary runs from the symlink farm ==="
"$ROOT/bin/greeter"

echo
echo "=== manifest ==="
cat "$ROOT/db/greeter/MANIFEST"

echo
echo "=== metadata members must not be installed ==="
if find "$ROOT/store" -name '.PKGINFO' -o -name '.MTREE' | grep -q .; then
  echo "FAIL: metadata leaked into the store"; exit 1
else
  echo "ok: .PKGINFO/.MTREE excluded from the installed tree"
fi

echo
echo "=== reinstall must be refused ==="
if $OPTI install "$WORK" >/dev/null 2>&1; then
  echo "FAIL: duplicate install accepted"; exit 1
else
  echo "ok: already-installed rejected"
fi

echo
echo "=== uninstall ==="
$OPTI uninstall greeter

echo
echo "=== nothing left behind ==="
find "$ROOT" -mindepth 1 \( -path "$ROOT/cache*" -prune -o -print \) | sort
[ -e "$ROOT/bin/greeter" ] && { echo "FAIL: symlink survived"; exit 1; } || echo "ok: symlink removed"
[ -d "$ROOT/store/greeter-2.1.0-1" ] && { echo "FAIL: prefix survived"; exit 1; } || echo "ok: prefix removed"
[ -d "$ROOT/db/greeter" ] && { echo "FAIL: record survived"; exit 1; } || echo "ok: record removed"

echo
echo "=== list is empty again ==="
$OPTI list

echo
echo "=== removing something not installed ==="
if $OPTI uninstall nosuchpkg >/dev/null 2>&1; then
  echo "FAIL: accepted"; exit 1
else
  echo "ok: rejected"
fi
