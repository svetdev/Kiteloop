#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

actual="$(bash ./greet.sh Kiteloop --shout)"
expected="HELLO, KITELOOP!"

if [ "$actual" != "$expected" ]; then
  echo "expected '$expected', got '$actual'"
  exit 1
fi
echo "ok"
