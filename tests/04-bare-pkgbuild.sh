#!/bin/bash
# A PKGBUILD with NO .SRCINFO must still build, the way makepkg does.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-bare
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=bare
pkgver=3.1.4
pkgrel=1
pkgdesc="built without a .SRCINFO"
url="https://example.org"
arch=('x86_64')
license=('MIT')
depends=('glibc' 'zlib>=1.2')
provides=('libbare.so=1-64')
options=('!strip')

build() {
  cat > b.c <<'CEOF'
#include <stdio.h>
int main(void){ printf("bare ok\n"); return 0; }
CEOF
  gcc -o bare b.c
}

package() {
  install -Dm755 bare "$pkgdir/usr/bin/bare"
}
PKGEOF

echo "=== directory contents (note: no .SRCINFO) ==="
ls -a "$WORK"

echo
echo "=== build ==="
$OPTI build "$WORK"

echo
echo "=== .PKGINFO derived from the PKGBUILD alone ==="
tar xzOf "$WORK"/bare-3.1.4-1-x86_64.pkg.tar.gz .PKGINFO

echo "=== no stray generated file left behind ==="
ls -a "$WORK" | grep -c 'opti-srcinfo' || echo "clean"

echo
echo "=== packaged binary runs ==="
rm -rf /var/tmp/bare-v; mkdir -p /var/tmp/bare-v
tar xzf "$WORK"/bare-3.1.4-1-x86_64.pkg.tar.gz -C /var/tmp/bare-v
/var/tmp/bare-v/usr/bin/bare
