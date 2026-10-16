#!/bin/sh
# Line coverage of lib/ over every test, including those that need a
# special environment:
#   1. the whole suite (SSH tests need sshd and ssh-keygen; network tests
#      are left out);
#   2. as an unprivileged user (unreadable files): only when run as root
#      with runuser available;
#   3. without chmod on PATH (as on systems that have none).
# Writes coverage/lcov.info and prints a per-file summary.
#
#   tool/coverage.sh [--min=<percent>]
set -eu

cd "$(dirname "$0")/.."
root=$(pwd)
dart=$(command -v dart)
sdk=$(dirname "$(dirname "$(readlink -f "$dart")")")
out=$root/coverage
rm -rf "$out"
mkdir -p "$out"
work=$(mktemp -d)
chmod 755 "$work"
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT

echo '== 1/3 full suite'
dart run coverage:test_with_coverage -o "$out/main" -- --run-skipped -x network
runs="$out/main/lcov.info"

if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null; then
  echo '== 2/3 as nobody'
  # nobody needs its own readable copies of the SDK, packages and sources.
  if ! runuser -u nobody -- test -x "$sdk/bin/dart"; then
    cp -r "$sdk" "$work/sdk"
    sdk=$work/sdk
  fi
  cp -r "${PUB_CACHE:-$HOME/.pub-cache}" "$work/pub-cache"
  mkdir "$work/src"
  cp -r lib test pubspec.yaml analysis_options.yaml dart_test.yaml "$work/src"
  chmod -R a+rX "$work"
  chown -R nobody "$work/src" "$work/pub-cache"
  runuser -u nobody -- env HOME="$work/src" PUB_CACHE="$work/pub-cache" \
    PATH="$sdk/bin:$PATH" sh -c "cd '$work/src' && dart pub get --offline \
      >/dev/null && dart run coverage:test_with_coverage -o '$work/src/cov' \
      -- test/environment_test.dart"
  cp "$work/src/cov/lcov.info" "$out/nobody.info"
  runs="$runs $out/nobody.info"
else
  echo '== 2/3 skipped (needs root and runuser to switch to nobody)'
fi

echo '== 3/3 without chmod'
mkdir "$work/bin"
ln -s "$(command -v git)" "$work/bin/git"
PATH="$work/bin" "$dart" run coverage:test_with_coverage -o "$out/nochmod" \
  -- test/environment_test.dart
runs="$runs $out/nochmod/lcov.info"

echo '== merged'
# shellcheck disable=SC2086
dart run tool/merge_lcov.dart "$@" "$out/lcov.info" $runs
