#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."   # web/
pkill -f "vite --port 8080" 2>/dev/null; pkill -f "remote-debugging-port=9222" 2>/dev/null
sleep 1
node_modules/.bin/vite --port 8080 >/tmp/vite.log 2>&1 &
VITE=$!
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 \
  --user-data-dir=/tmp/cr-prof http://localhost:8080/ >/tmp/chrome.log 2>&1 &
CHROME=$!
cleanup() { kill $VITE $CHROME 2>/dev/null; }
trap cleanup EXIT
# wait for vite
for i in $(seq 1 30); do curl -sf http://localhost:8080/ >/dev/null && break; sleep 0.5; done
# wait for chrome devtools
for i in $(seq 1 30); do curl -sf http://localhost:9222/json >/dev/null && break; sleep 0.5; done
node test/browser-check.mjs
echo "rc=$?"
