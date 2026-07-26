#!/bin/bash
# Full pipeline: download -> checksum -> extract -> configure/make -> package
set -e
OPTI=/mnt/c/Users/devon/opti/zig-out/bin/opti
URL="https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz"

WORK=/var/tmp/opti-m2
rm -rf "$WORK"; mkdir -p "$WORK"
curl -sL "$URL" -o /var/tmp/ref-hello.tar.gz
SUM=$(sha256sum /var/tmp/ref-hello.tar.gz | cut -d' ' -f1)

write_pkg() {
  local dir="$1" sum="$2"
  mkdir -p "$dir"
  cat > "$dir/PKGBUILD" <<PKGEOF
pkgname=hello
pkgver=2.12.1
pkgrel=1
arch=('x86_64')
source=("$URL")
sha256sums=('$sum')
build() {
  ./configure --prefix=/usr --silent
  make -s
}
package() {
  make DESTDIR="\$pkgdir" install -s
}
PKGEOF
  printf 'pkgbase = hello\n\tpkgver = 2.12.1\n\tpkgrel = 1\n\tarch = x86_64\n\tsource = %s\n\tsha256sums = %s\n\npkgname = hello\n' \
    "$URL" "$sum" > "$dir/.SRCINFO"
}

write_pkg "$WORK/good" "$SUM"
echo "=== 1. correct checksum ==="
$OPTI build "$WORK/good" >/tmp/good.log 2>&1 && echo "build: OK" || { echo "build: FAILED"; tail -20 /tmp/good.log; exit 1; }
grep -E '^(retrieving|  hello|  build|  package)' /tmp/good.log

echo
echo "=== packaged tree ==="
# Staging is per output package: pkg/<pkgname>/...
STAGE="$WORK/good/pkg/hello"
find "$STAGE" -type f | sed "s|$STAGE||" | sort | head -6
echo "total files: $(find "$STAGE" -type f | wc -l)"

echo
echo "=== packaged binary runs ==="
"$STAGE/usr/bin/hello"

echo
echo "=== 2. corrupted checksum must be rejected ==="
write_pkg "$WORK/bad" "0000000000000000000000000000000000000000000000000000000000000000"
if $OPTI build "$WORK/bad" >/tmp/bad.log 2>&1; then
  echo "RESULT: BAD - corrupt checksum accepted"; exit 1
else
  echo "RESULT: correctly rejected"
  grep -E 'checksum|Checksum' /tmp/bad.log || tail -3 /tmp/bad.log
fi

echo
echo "=== 3. download is cached (no refetch) ==="
$OPTI build "$WORK/good" 2>&1 | grep -E 'downloading|extracted' || echo "(no download line: served from cache)"
