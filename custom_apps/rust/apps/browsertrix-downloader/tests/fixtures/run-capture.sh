#!/bin/bash
# Mount this directory at /archive-test-fixtures:ro and a writable /crawls.
# Invoke with --network none; no service or external origin is required.
set -euo pipefail
python3 /archive-test-fixtures/capture_site.py &
fixture_server=$!
trap 'kill "$fixture_server" 2>/dev/null || true; wait "$fixture_server" 2>/dev/null || true' EXIT
crawl --url http://127.0.0.1:18800/ --scopeType host --depth -1 \
  --pageLimit 10 --timeLimit 90 --sizeLimit 5242880 --generateWACZ \
  --text to-pages,to-warc,final-to-warc --screenshot view --headless \
  --saveState always --saveStateInterval 10 --collection preservation-complete \
  --workers 1 --behaviors autoscroll --behaviorTimeout 5 --pageLoadTimeout 15 --reportSkipped
