#!/bin/bash
# Exercises split packages, pkgver(), options=(), symlinks, .INSTALL, backup.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-full
rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/svc.install" <<'EOF'
post_install() { echo "installed"; }
EOF

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgbase=demo
pkgname=(demo demo-docs)
pkgver=9.9.9
pkgrel=2
pkgdesc="shared description"
url="https://example.com"
arch=('x86_64')
license=('MIT')
depends=('glibc')
install=svc.install
backup=('etc/demo.conf')
options=('!zipman' 'staticlibs')

pkgver() {
  echo "1.2.3"
}

build() {
  cat > hello.c <<'CEOF'
#include <stdio.h>
int main(void){ printf("demo ok\n"); return 0; }
CEOF
  gcc $CFLAGS -o demo hello.c
  echo "static" > libdemo.a
  echo "libtool" > libdemo.la
  mkdir -p man
  echo ".TH DEMO 1" > man/demo.1
}

package_demo() {
  install -Dm755 demo "$pkgdir/usr/bin/demo"
  install -Dm644 libdemo.a "$pkgdir/usr/lib/libdemo.a"
  install -Dm644 libdemo.la "$pkgdir/usr/lib/libdemo.la"
  install -Dm644 man/demo.1 "$pkgdir/usr/share/man/man1/demo.1"
  install -Dm644 /dev/null "$pkgdir/etc/demo.conf"
  ln -s /usr/bin/demo "$pkgdir/usr/bin/demo-link"
}

package_demo-docs() {
  install -Dm644 /dev/null "$pkgdir/usr/share/doc/demo/README"
}
PKGEOF

printf 'pkgbase = demo\n\tpkgdesc = shared description\n\tpkgver = 9.9.9\n\tpkgrel = 2\n\turl = https://example.com\n\tarch = x86_64\n\tlicense = MIT\n\tdepends = glibc\n\tinstall = svc.install\n\tbackup = etc/demo.conf\n\toptions = !zipman\n\toptions = staticlibs\n\npkgname = demo\n\npkgname = demo-docs\n\tpkgdesc = just the docs\n' > "$WORK/.SRCINFO"

echo "=== build ==="
$OPTI build "$WORK"

echo
echo "=== artifacts ==="
ls -1 "$WORK"/*.pkg.tar.gz | xargs -n1 basename

DEMO="$WORK/demo-1.2.3-2-x86_64.pkg.tar.gz"
echo
echo "=== pkgver() overrode 9.9.9 -> 1.2.3 in the filename above ==="

echo
echo "=== .PKGINFO (demo) ==="
tar xzOf "$DEMO" .PKGINFO

echo "=== .BUILDINFO present ==="
tar xzOf "$DEMO" .BUILDINFO | head -6

echo
echo "=== .INSTALL scriptlet embedded ==="
tar xzOf "$DEMO" .INSTALL

echo "=== members ==="
tar tzf "$DEMO"

echo
echo "=== symlink preserved ==="
tar tvzf "$DEMO" | grep 'demo-link'

echo
echo "=== options honoured ==="
tar tzf "$DEMO" | grep -q 'libdemo.a' && echo "staticlibs=on : .a KEPT (correct)" || echo ".a removed (WRONG)"
tar tzf "$DEMO" | grep -q 'libdemo.la' && echo ".la kept (WRONG)" || echo "libtool=off: .la removed (correct)"
tar tzf "$DEMO" | grep -q 'demo.1.gz' && echo "man gzipped (WRONG, !zipman)" || echo "!zipman: man NOT gzipped (correct)"

echo
echo "=== split package produced its own artifact ==="
tar tzf "$WORK/demo-docs-1.2.3-2-x86_64.pkg.tar.gz" | grep 'README'
