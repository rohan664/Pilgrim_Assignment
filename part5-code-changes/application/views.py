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