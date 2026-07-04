"""Unauthenticated liveness endpoint, mirroring the Go node agent's own
/healthz — same shape, same reasoning: a load balancer or orchestrator
needs a check with no auth dependency."""

from fastapi import APIRouter

router = APIRouter()


@router.get("/healthz")
async def healthz() -> str:
    return "ok"
