#!/bin/bash
# End-to-end: source -> build -> package artifact, then validate the artifact.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
URL="https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz"
WORK=/var/tmp/opti-m4
rm -rf "$WORK"; mkdir -p "$WORK"

curl -sL "$URL" -o /var/tmp/ref-hello.tar.gz
SUM=$(sha256sum /var/tmp/ref-hello.tar.gz | cut -d' ' -f1)

cat > "$WORK/PKGBUILD" <<PKGEOF
pkgname=hello
pkgver=2.12.1
pkgrel=1
pkgdesc="Prints a friendly greeting"
url="https://www.gnu.org/software/hello/"
arch=('x86_64')
license=('GPL-3.0-or-later')
depends=('glibc')
source=("$URL")
sha256sums=('$SUM')
build() { ./configure --prefix=/usr --silent; make -s; }
package() { make DESTDIR="\$pkgdir" install -s; }
PKGEOF

printf 'pkgbase = hello\n\tpkgdesc = Prints a friendly greeting\n\tpkgver = 2.12.1\n\tpkgrel = 1\n\turl = https://www.gnu.org/software/hello/\n\tarch = x86_64\n\tlicense = GPL-3.0-or-later\n\tdepends = glibc\n\tsource = %s\n\tsha256sums = %s\n\npkgname = hello\n' \
  "$URL" "$SUM" > "$WORK/.SRCINFO"

echo "=== build ==="
$OPTI build "$WORK" 2>&1 | grep -vE '^(config|Making|installing|/bin/sh|make|  GEN|warning)' | tail -12

PKG=$(ls "$WORK"/*.pkg.tar.*)
echo
echo "=== artifact ==="
ls -lh "$PKG" | awk '{print $5, $9}'
file "$PKG"

echo
echo "=== member order (metadata must come first) ==="
tar tf "$PKG" | head -5

echo
echo "=== .PKGINFO ==="
tar xOf "$PKG" .PKGINFO

echo "=== .MTREE is gzipped ==="
tar xOf "$PKG" .MTREE | head -c2 | xxd | head -1
echo "--- decoded head ---"
tar xOf "$PKG" .MTREE | gzip -d | head -4

echo
echo "=== executable bit preserved ==="
tar tvf "$PKG" | grep 'usr/bin/hello'

echo
echo "=== extract and run from the package ==="
rm -rf /var/tmp/opti-verify; mkdir -p /var/tmp/opti-verify
tar xf "$PKG" -C /var/tmp/opti-verify
/var/tmp/opti-verify/usr/bin/hello
