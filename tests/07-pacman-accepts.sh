#!/bin/bash
# Validation only: confirm pacman itself can parse an opti-produced package.
# opti never invokes pacman at runtime; this is an external format check.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-pacman
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=optiverify
pkgver=2.5.0
pkgrel=3
pkgdesc="format validation package"
url="https://example.com/optiverify"
arch=('x86_64')
license=('MIT')
depends=('glibc')
optdepends=('bash: scripting')
provides=('libverify.so=2-64')
conflicts=('optiverify-git')
backup=('etc/optiverify.conf')

build() {
  cat > v.c <<'CEOF'
#include <stdio.h>
int main(void){ printf("verify ok\n"); return 0; }
CEOF
  gcc -o optiverify v.c
}

package() {
  install -Dm755 optiverify "$pkgdir/usr/bin/optiverify"
  install -Dm644 /dev/null "$pkgdir/etc/optiverify.conf"
  ln -s /usr/bin/optiverify "$pkgdir/usr/bin/ov"
}
PKGEOF

$OPTI build "$WORK" >/dev/null
PKG=$(ls "$WORK"/*.pkg.tar.*)
echo "artifact: $(basename "$PKG")"

echo
echo "=== pacman -Qip (pacman parsing our package) ==="
pacman -Qip "$PKG"

echo
echo "=== pacman -Qlp (file list) ==="
pacman -Qlp "$PKG"

echo
echo "=== .MTREE parses as mtree ==="
tar xOf "$PKG" .MTREE | gzip -d | head -5

echo
echo "RESULT: pacman accepted the package"
