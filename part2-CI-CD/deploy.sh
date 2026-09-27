#!/usr/bin/env bash
set -euo pipefail

ARTIFACT="$1"
SKIP_MIGRATE=false
if [[ "${2:-}" == "--skip-migrate" ]]; then
  SKIP_MIGRATE=true
fi

BASE=/opt/app
SHARED=$BASE/shared
REL=$BASE/releases/$(date +%Y%m%d%H%M%S)
PREV=$(readlink -f "$BASE/current" 2>/dev/null || true)

manage() {
  sudo -u app bash -c "set -a; . $SHARED/.env; set +a; cd $REL && ./venv/bin/python manage.py $*"
}

rollback() {
  echo "!! Deployment failed — rolling back to: ${PREV:-none}"
  if [ -n "${PREV:-}" ] && [ -d "$PREV" ]; then
    ln -sfn "$PREV" "$BASE/current.tmp" && mv -Tf "$BASE/current.tmp" "$BASE/current"
    systemctl restart app-gunicorn || true
  fi
  rm -rf "$REL"
  exit 1
}
trap rollback ERR

echo "==> Fetching latest environment config from Secrets Manager"
"$BASE/bin/fetch-env.sh"

echo "==> Fetching artifact: $ARTIFACT"
mkdir -p "$REL"
aws s3 cp "$ARTIFACT" - | tar -xz -C "$REL"
chown -R app:app "$REL"

echo "==> Installing dependencies"
sudo -u app python3 -m venv "$REL/venv"
sudo -u app "$REL/venv/bin/pip" install --no-cache-dir --upgrade pip
sudo -u app "$REL/venv/bin/pip" install --no-cache-dir -r "$REL/requirements.txt"

echo "==> Collecting static files"
manage collectstatic --noinput

if [ "$SKIP_MIGRATE" = false ]; then
  echo "==> Running database migrations"
  manage migrate --noinput
else
  echo "==> Skipping migrations (--skip-migrate passed, another instance already ran them)"
fi

echo "==> Switching release and restarting"
ln -sfn "$REL" "$BASE/current.tmp" && mv -Tf "$BASE/current.tmp" "$BASE/current"
systemctl restart app-gunicorn

echo "==> Health check (through Nginx, HTTP — TLS is terminated at the ALB)"
for i in $(seq 1 15); do
  if curl -fsS "http://localhost/readyz" >/dev/null; then
    echo "Healthy after $i attempt(s)"
    trap - ERR
    # keep only the last 5 releases on disk
    ls -1dt "$BASE"/releases/* | tail -n +6 | xargs -r rm -rf
    echo "==> Deploy OK: $REL"
    exit 0
  fi
  sleep 2
done

false   # triggers the ERR trap above -> rollback