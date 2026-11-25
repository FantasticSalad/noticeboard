#!/usr/bin/env bash
# Runs every test suite. Exit 0 only when all pass.
#
#   bash tests/run-all.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
status=0
for t in noticeboard.test.sh announce.test.sh public-scan.sh; do
  printf '\n### %s\n' "$t"
  bash "$HERE/$t" || status=1
done
if [ "$status" = 0 ]; then printf '\nAll suites passed.\n'; else printf '\nA suite failed.\n'; fi
exit "$status"
