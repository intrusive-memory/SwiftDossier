#!/bin/sh
# Prints the -only-testing identifier for a TEST_FILTER value.
# A value with a "/" (Target/Suite) or naming a test target is used as given;
# a bare suite name is prefixed with the target whose Tests/ directory declares it.
set -eu
filter="$1"
case "$filter" in
  */*) echo "$filter"; exit 0 ;;
esac
if [ -d "Tests/$filter" ]; then echo "$filter"; exit 0; fi
file=$(grep -rlE "^[[:space:]]*(struct|enum|class|final class) $filter\\b" Tests 2>/dev/null | head -1 || true)
if [ -n "$file" ]; then
  target=$(echo "$file" | cut -d/ -f2)
  echo "$target/$filter"
else
  echo "$filter"
fi
