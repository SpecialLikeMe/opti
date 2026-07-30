#!/bin/bash
# Stage 2: dependency resolution against the live AUR.
#
# Only the *planning* half runs — every case answers "n" or fails before
# building, so no third-party PKGBUILD is ever executed.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
rm -rf /var/lib/opti

echo "=== 1. a real AUR package produces a build plan ==="
echo n | "$OPTI" install yay >/tmp/r.log 2>&1 || true
cat /tmp/r.log
grep -q 'yay' /tmp/r.log || { echo "FAIL: no plan"; exit 1; }
grep -q 'already satisfied' /tmp/r.log || { echo "FAIL: satisfied deps not reported"; exit 1; }
echo "ok"

echo
echo "=== 2. the prompt defaults to no ==="
grep -q 'aborted' /tmp/r.log && echo "ok: answering n aborted" || { echo "FAIL"; exit 1; }

echo
echo "=== 3. host-satisfied deps never enter the plan ==="
# yay depends on git, pacman and go, all present. Reaching the AUR for them
# would pull in variants such as git-git.
if grep -qE '^  (git|pacman|go) ' /tmp/r.log; then
  echo "FAIL: a host-satisfied dependency was scheduled for building"; exit 1
fi
echo "ok: skipped"

echo
echo "=== 4. an official-repo package is reported as such, not 'not found' ==="
echo n | "$OPTI" install go >/tmp/o.log 2>&1 || true
cat /tmp/o.log
grep -q 'official repositories' /tmp/o.log || { echo "FAIL: not identified"; exit 1; }
grep -qE 'go \((core|extra)' /tmp/o.log || { echo "FAIL: repo not named"; exit 1; }
echo "ok"

echo
echo "=== 5. a genuinely unknown package is reported as unresolvable ==="
if echo n | "$OPTI" install definitely-not-a-real-package-xyz >/tmp/m.log 2>&1; then
  echo "FAIL: accepted"; exit 1
fi
grep -qE 'cannot resolve|not found' /tmp/m.log && echo "ok: rejected" || { cat /tmp/m.log; exit 1; }

echo
echo "=== 6. reverse-dependency protection on uninstall ==="
LIBW=/var/tmp/opti-dep-lib
APPW=/var/tmp/opti-dep-app
rm -rf "$LIBW" "$APPW"; mkdir -p "$LIBW" "$APPW"

cat > "$LIBW/PKGBUILD" <<'PKGEOF'
pkgname=baselib
pkgver=1.0
pkgrel=1
arch=('any')
package() { install -Dm644 /dev/null "$pkgdir/usr/share/baselib/marker"; }
PKGEOF

cat > "$APPW/PKGBUILD" <<'PKGEOF'
pkgname=consumer
pkgver=1.0
pkgrel=1
arch=('any')
depends=('baselib')
package() { install -Dm644 /dev/null "$pkgdir/usr/share/consumer/marker"; }
PKGEOF

"$OPTI" install "$LIBW" >/dev/null
"$OPTI" install "$APPW" >/dev/null
"$OPTI" list

echo
echo "--- removing baselib must be refused ---"
if "$OPTI" uninstall baselib >/tmp/u.log 2>&1; then
  echo "FAIL: removed a package that is still required"; exit 1
fi
cat /tmp/u.log
grep -q 'consumer' /tmp/u.log || { echo "FAIL: dependent not named"; exit 1; }
echo "ok: refused and named the dependent"

echo
echo "--- --force overrides ---"
"$OPTI" uninstall baselib --force
"$OPTI" uninstall consumer
"$OPTI" list
