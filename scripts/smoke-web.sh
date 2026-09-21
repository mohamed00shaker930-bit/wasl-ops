#!/usr/bin/env bash
# Builds wasl-web, serves the build with `vite preview` (proxying /api to the running API), and checks the shell + proxy.
set -u
cd "$(dirname "$0")/../../wasl-web"
pnpm build 2>&1 | tail -3 || exit 1
if grep -rqi "lovable\|supabase" dist/; then echo "!! lovable/supabase strings found in dist:"; grep -rli "lovable\|supabase" dist/ | head -3; else echo "dist clean of lovable/supabase strings"; fi
pnpm exec vite preview --host 127.0.0.1 --port 4173 --strictPort > /tmp/web-preview.log 2>&1 &
PREVIEW_PID=$!
for i in $(seq 1 30); do curl -sf http://127.0.0.1:4173/ >/dev/null 2>&1 && break; sleep 1; done
echo "index: $(curl -s http://127.0.0.1:4173/ | grep -o '<html[^>]*>')"
echo "spa fallback /home: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4173/home)"
echo "api via proxy: $(curl -s http://127.0.0.1:4173/api/health)"
echo "sw.js: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4173/sw.js)  manifest: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4173/manifest.webmanifest)"
kill $PREVIEW_PID >/dev/null 2>&1; exit 0
