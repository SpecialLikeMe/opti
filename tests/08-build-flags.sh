#!/bin/bash
# --nocheck, --skipchecksums and --holdver.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-flags
rm -rf "$WORK"; mkdir -p "$WORK"
echo "payload" > "$WORK/data.txt"

cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=flags
pkgver=0.1
pkgrel=1
arch=('any')
source=('data.txt')
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')

pkgver() { echo "9.9.9"; }
check()  { echo "CHECK RAN"; exit 1; }
package() { install -Dm644 "$srcdir/data.txt" "$pkgdir/usr/share/flags/data.txt"; }
PKGEOF

echo "=== default: bad checksum must fail ==="
if $OPTI build "$WORK" >/tmp/f.log 2>&1; then echo "FAIL: accepted"; exit 1; else echo "ok: rejected"; fi

echo
echo "=== --skipchecksums --nocheck --holdver ==="
$OPTI build "$WORK" --skipchecksums --nocheck --holdver

echo
echo "=== assertions ==="
PKG=$(ls "$WORK"/*.pkg.tar.*)
basename "$PKG"
case "$(basename "$PKG")" in
  flags-0.1-1-any.pkg.tar.*) echo "ok: --holdver kept 0.1, pkgver() not run" ;;
  *) echo "FAIL: --holdver ignored"; exit 1 ;;
esac
grep -q 'check: skipped' <($OPTI build "$WORK" --skipchecksums --nocheck --holdver) \
  && echo "ok: --nocheck skipped the failing check()" || echo "FAIL: check not skipped"

echo
echo "=== unknown option is rejected ==="
if $OPTI build "$WORK" --bogus >/dev/null 2>&1; then echo "FAIL"; else echo "ok: rejected"; fi
