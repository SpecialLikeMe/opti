#!/bin/bash
# Integration suite for the in-house makepkg.
#
# These exercise the parts unit tests cannot: real downloads, bash execution,
# fakeroot, and the produced artifacts. Run from a Linux host with a toolchain:
#
#     wsl -d archlinux -- bash /mnt/c/Users/devon/opti/tests/run-all.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

pass=0
fail=0
for script in "$HERE"/0*.sh; do
  name="$(basename "$script")"
  printf '\n=========== %s ===========\n' "$name"
  if bash "$script" >/tmp/opti-it.log 2>&1; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    tail -25 /tmp/opti-it.log
    fail=$((fail + 1))
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
