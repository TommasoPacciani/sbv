#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."   # web/
pkill -f "vite --port 8080" 2>/dev/null; pkill -f "remote-debugging-port=9222" 2>/dev/null
sleep 1
node_modules/.bin/vite --port 8080 >/tmp/vite.log 2>&1 &
VITE=$!
google-chrome --headless=new --no-sandbox --disable-gpu --remote-debugging-port=9222 \
  --user-data-dir=/tmp/cr-prof-g http://localhost:8080/grisette.html >/tmp/chrome.log 2>&1 &
CHROME=$!
cleanup() { kill $VITE $CHROME 2>/dev/null; }
trap cleanup EXIT
for i in $(seq 1 30); do curl -sf http://localhost:8080/grisette.html >/dev/null && break; sleep 0.5; done
for i in $(seq 1 30); do curl -sf http://localhost:9222/json >/dev/null && break; sleep 0.5; done
node test/grisette-browser-check.mjs
echo "rc=$?"
