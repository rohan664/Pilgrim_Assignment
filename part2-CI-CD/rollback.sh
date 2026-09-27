#!/usr/bin/env bash
#
# rollback.sh — reverts this instance to the previous release.
#
# Can be run two ways:
#   1. Automatically by the Jenkins pipeline via SSM, if a deploy fails.
#   2. Manually by a developer connected through SSM Session Manager:
#        aws ssm start-session --target <instance-id>
#        sudo /opt/app/bin/rollback.sh
#
set -euo pipefail

BASE=/opt/app
CUR=$(readlink -f "$BASE/current" 2>/dev/null || true)

if [ -z "$CUR" ]; then
  echo "No current release symlink found — nothing to roll back from."
  exit 1
fi

PREV=$(ls -1dt "$BASE"/releases/* | grep -v "^$CUR$" | head -1 || true)

if [ -z "$PREV" ]; then
  echo "No previous release found in $BASE/releases — cannot roll back."
  exit 1
fi

echo "Rolling back: $CUR -> $PREV"
ln -sfn "$PREV" "$BASE/current.tmp" && mv -Tf "$BASE/current.tmp" "$BASE/current"
systemctl restart app-gunicorn

echo "Waiting for health check..."
for i in $(seq 1 15); do
  if curl -fsS "http://localhost/readyz" >/dev/null; then
    echo "Rollback OK — healthy after $i attempt(s), now serving: $PREV"
    exit 0
  fi
  sleep 2
done

echo "!! Rollback completed the symlink switch, but the health check did not pass."
echo "!! Manual investigation required — see Part 3 (Production Incident Investigation)."
exit 1