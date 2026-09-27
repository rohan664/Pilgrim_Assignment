# Part 5: Small Code Change — Health-check Endpoint (Django)

## Why two endpoints, not one

- **`/healthz`** — Confirms the Django process itself is up and
  able to serve a request. No external dependencies checked. This is what the
  **ALB target group** should point at — if the database has a brief blip, we
  don't want the ALB deregistering every instance in the fleet at once just
  because of a shared dependency.
- **`/readyz`** — Also checks the database connection. This is
  what `deploy.sh` and `rollback.sh` use to confirm the app is genuinely usable
  after a release is switched in (see Part 1 and Part 2) — it's fine for the
  ALB's *ongoing* health checks to be more lenient than a *deploy's* health
  check.

## Code

`views.py`

```python
import logging

from django.db import connection
from django.http import JsonResponse
from django.views.decorators.http import require_GET

logger = logging.getLogger(__name__)


@require_GET
def healthz(request):
    """Liveness: the app process is running. No external dependencies."""
    return JsonResponse({"status": "ok"})


@require_GET
def readyz(request):
    """Readiness: the app can reach its database."""
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()
    except Exception:
        logger.exception("Readiness check failed: database unavailable")
        return JsonResponse(
            {"status": "error", "checks": {"database": "unavailable"}},
            status=503,
        )
    return JsonResponse({"status": "ok", "checks": {"database": "ok"}})
```

`urls.py`:

```python
from django.contrib import admin
from django.urls import path

from application import views

urlpatterns = [
    path('admin/', admin.site.urls),
    path("healthz", views.healthz),
    path("readyz", views.readyz),
]

```

`settings.py`:

```python
# Fail fast instead of hanging if RDS is unreachable, so /readyz responds
# quickly rather than timing out
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
        'OPTIONS':{
            "connect_timeout": 3
        }
    }
}
```

## Where each endpoint is used in this architecture

| Endpoint | Used by | Why |
|---|---|---|
| `/healthz` | ALB target group health check | Cheap, no dependencies — avoids fleet-wide deregistration on a shared DB blip |
| `/readyz` | `deploy.sh` (local check after switching the release) | Confirms the *new* release can actually reach the database before declaring the deploy successful |
| `/readyz` | `rollback.sh` (confirms the previous release is healthy again) | Same reasoning, after reverting |
| `/readyz` | Jenkins pipeline's public health-check stage | Confirms the whole path (ALB → Nginx → Gunicorn → RDS) works from outside, not just locally on the instance |