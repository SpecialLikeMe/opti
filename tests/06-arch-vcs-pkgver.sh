#!/bin/bash
# arch=any, VCS fragment checkout, pkgver() write-back, optdepends/groups,
# .CHANGELOG, and zstd output selection.
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
WORK=/var/tmp/opti-arch
rm -rf "$WORK"; mkdir -p "$WORK"

# --- a real local git repo with two tagged revisions -----------------------
REPO=/var/tmp/opti-gitsrc
rm -rf "$REPO"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
# The tagged revision and the branch head differ, so the checked-out content
# proves which one was actually used.
echo "AT-TAG-V1.0" > "$REPO/marker.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm one
git -C "$REPO" tag v1.0
echo "AT-BRANCH-HEAD" > "$REPO/marker.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm two

echo "Version 1.0 notes" > "$WORK/CHANGES"

cat > "$WORK/PKGBUILD" <<PKGEOF
pkgname=anypkg
pkgver=0.0.0
pkgrel=1
pkgdesc="arch independent"
arch=('any')
license=('MIT')
optdepends=('bash: for scripts')
groups=('demo-group')
changelog=CHANGES
source=("src::git+file://$REPO#tag=v1.0")
sha256sums=('SKIP')

pkgver() {
  echo "5.6.7"
}

package() {
  install -Dm644 "\$srcdir/src/marker.txt" "\$pkgdir/usr/share/anypkg/marker.txt"
}
PKGEOF

echo "=== build ==="
$OPTI build "$WORK"

PKG=$(ls "$WORK"/*.pkg.tar.* | head -1)
echo
echo "=== artifact name (must be -any, version from pkgver()) ==="
basename "$PKG"

echo
echo "=== VCS fragment: must contain the tagged revision, not branch head ==="
GOT=$(tar xOf "$PKG" usr/share/anypkg/marker.txt)
echo "packaged content: $GOT"
[ "$GOT" = "AT-TAG-V1.0" ] || { echo "FAIL: got branch head instead of the tag"; exit 1; }
echo "ok: #tag=v1.0 was honoured"

case "$(basename "$PKG")" in
  anypkg-5.6.7-1-any.pkg.tar.*) echo "ok: arch=any and pkgver() reflected in filename" ;;
  *) echo "FAIL: unexpected artifact name"; exit 1 ;;
esac

echo
echo "=== pkgver() written back into PKGBUILD ==="
grep '^pkgver=' "$WORK/PKGBUILD"
grep -q '^pkgver=5.6.7$' "$WORK/PKGBUILD" || { echo "FAIL: not written back"; exit 1; }

echo
echo "=== .PKGINFO ==="
tar xOf "$PKG" .PKGINFO 2>/dev/null || tar xzOf "$PKG" .PKGINFO

echo
echo "=== .CHANGELOG embedded ==="
tar xOf "$PKG" .CHANGELOG 2>/dev/null || tar xzOf "$PKG" .CHANGELOG
