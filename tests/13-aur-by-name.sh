#!/bin/bash
# `opti install <name>` resolves an AUR package name rather than a directory.
#
# Deliberately does NOT build a third-party AUR package: that would execute
# arbitrary upstream bash. Only the fetch/reject half is exercised here, plus
# the local-directory path, which is covered by a PKGBUILD written in-tree.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
rm -rf /var/lib/opti

echo "=== a nonexistent AUR name is rejected before any bash runs ==="
# Resolution now runs first, so the name is rejected before anything is even
# fetched, let alone executed.
if "$OPTI" install this-package-does-not-exist-xyz >/tmp/aur.log 2>&1; then
  echo "FAIL: accepted"; exit 1
else
  echo "ok: rejected"
fi
grep -E 'cannot resolve|not found' /tmp/aur.log

echo
echo "=== the failed checkout leaves nothing behind ==="
if [ -d /var/lib/opti/cache/src/this-package-does-not-exist-xyz ]; then
  echo "FAIL: stale checkout left"; exit 1
else
  echo "ok: no stale checkout"
fi

echo
echo "=== a local directory is still treated as a directory ==="
WORK=/var/tmp/opti-localdir
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/PKGBUILD" <<'PKGEOF'
pkgname=localpkg
pkgver=1.0
pkgrel=1
pkgdesc="built from a local directory"
arch=('any')
package() { install -Dm644 /dev/null "$pkgdir/usr/share/localpkg/marker"; }
PKGEOF

"$OPTI" install "$WORK" 2>&1 | tail -2
"$OPTI" list

echo
echo "=== a directory argument must not be looked up in the AUR ==="
grep -q 'aur.archlinux.org' <("$OPTI" files localpkg) && { echo "FAIL"; exit 1; } || echo "ok"

"$OPTI" uninstall localpkg >/dev/null
echo "cleaned up"
