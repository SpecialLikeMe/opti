#!/bin/bash
# Remaining feature coverage: xz/zstd extraction, noextract, emptydirs,
# zipman, and host detection (CARCH/CHOST/MAKEFLAGS).
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-final
rm -rf "$WORK"; mkdir -p "$WORK/stage/payload-1.0"

echo "content-xz" > "$WORK/stage/payload-1.0/from-xz.txt"
tar -C "$WORK/stage" -cJf "$WORK/payload-1.0.tar.xz" payload-1.0
rm -rf "$WORK/stage"; mkdir -p "$WORK/stage/zpay-1.0"
echo "content-zst" > "$WORK/stage/zpay-1.0/from-zst.txt"
tar -C "$WORK/stage" --zstd -cf "$WORK/zpay-1.0.tar.zst" zpay-1.0
rm -rf "$WORK/stage"; mkdir -p "$WORK/stage/keep-1.0"
echo "untouched" > "$WORK/stage/keep-1.0/inner.txt"
tar -C "$WORK/stage" -czf "$WORK/keep-1.0.tar.gz" keep-1.0
rm -rf "$WORK/stage"

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=final
pkgver=1.0
pkgrel=1
pkgdesc="feature coverage"
arch=('x86_64')
source=('payload-1.0.tar.xz' 'zpay-1.0.tar.zst' 'keep-1.0.tar.gz')
noextract=('keep-1.0.tar.gz')
sha256sums=('SKIP' 'SKIP' 'SKIP')

build() {
  echo "CARCH=$CARCH"
  echo "CHOST=$CHOST"
  echo "MAKEFLAGS=$MAKEFLAGS"
  ls from-xz.txt from-zst.txt keep-1.0.tar.gz >/dev/null
  echo "all three sources present in srcdir"
}

package() {
  install -Dm644 from-xz.txt "$pkgdir/usr/share/final/from-xz.txt"
  mkdir -p "$pkgdir/usr/share/final/empty-dir"
  mkdir -p "$pkgdir/usr/share/final/nested/deeper"
  echo ".TH FINAL 1" > man.1
  install -Dm644 man.1 "$pkgdir/usr/share/man/man1/final.1"
}
PKGEOF

echo "=== build ==="
$OPTI build "$WORK"

PKG=$(ls "$WORK"/final-1.0-1-*.pkg.tar.*)
echo
echo "=== members ==="
tar tf "$PKG" | grep -v '^\.' | sort

echo
echo "=== checks ==="
tar tf "$PKG" | grep -q 'empty-dir' && echo "FAIL: empty dir kept" || echo "ok: empty dirs pruned"
tar tf "$PKG" | grep -q 'man1/final.1.gz' && echo "ok: zipman compressed the man page" || echo "FAIL: man not gzipped"
tar tf "$PKG" | grep -q 'from-xz.txt' && echo "ok: xz source extracted" || echo "FAIL: xz"
echo
echo "=== .PKGINFO arch reflects detected host ==="
tar xOf "$PKG" .PKGINFO | grep '^arch'
