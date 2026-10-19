"""Change-proposal approval queue — the human-in-the-loop gate for autonomous
(AI-decided) changes (Agentic-OS governance).

When the AI decides to APPLY a change and the fleet isn't in YOLO mode, it files
a ChangeProposal carrying the dry-run PREVIEW instead of applying. A human then
approves (→ apply, recorded to the audit trail) or rejects. This mirrors the L2
orchestration-link approval for policy, but for direct config/runbook applies.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, Agent, ChangeProposal
from bossman.services.audit import record_audit


async def create_config_proposal(
    session: AsyncSession, agent: Agent, resources: list[dict[str, Any]],
    preview: dict[str, Any], requested_by: str | None, title: str = "",
) -> ChangeProposal:
    """File a pending config-apply proposal with its dry-run preview."""
    p = ChangeProposal(
        tenant_id=DEFAULT_TENANT_ID, kind="config", agent_id=agent.id, host=agent.name,
        title=title or f"Config change on {agent.name}",
        payload={"resources": resources}, preview=preview or {},
        requested_by=requested_by, status="pending",
    )
    session.add(p)
    await session.commit()
    await session.refresh(p)
    await record_audit(
        session, actor=requested_by or "unknown",
        actor_kind="external" if (requested_by or "").startswith("ai:") else None,
        action="proposal.create", category="config", target=f"{agent.name}",
        detail={"proposal_id": str(p.id), "kind": "config", "title": p.title},
    )
    return p


async def create_kubernetes_proposal(
    session: AsyncSession, agent: Agent, cluster, *, manifest: dict[str, Any], preview: dict[str, Any],
    requested_by: str | None, title: str = "", manifests: list[dict[str, Any]] | None = None,
    delete: bool = False,
) -> ChangeProposal:
    """File a pending Kubernetes apply (one object's manifest) with its server-dry-run preview — or, with
    `delete`, a pending DELETION of that object with its delete preview (what goes with it, what stays). The
    proposal remembers the object's identity AND the cluster, so approving it rebuilds the very same
    Resource and acts through the same access host."""
    md = manifest.get("metadata") or {}
    p = ChangeProposal(
        tenant_id=DEFAULT_TENANT_ID, kind="kubernetes", agent_id=agent.id, host=agent.name,
        title=title or f"{manifest.get('kind')} {md.get('name')} on {cluster.name}",
        payload={"cluster_id": str(cluster.id), "cluster_name": cluster.name, "namespace": md.get("namespace"),
                 "api_version": manifest.get("apiVersion"), "kind": manifest.get("kind"), "name": md.get("name"),
                 "manifest": manifest, **({"manifests": manifests} if manifests else {}),
                 **({"delete": True} if delete else {})},
        preview=preview or {}, requested_by=requested_by, status="pending",
    )
    session.add(p)
    await session.commit()
    await session.refresh(p)
    await record_audit(
        session, actor=requested_by or "unknown",
        actor_kind="external" if (requested_by or "").startswith("ai:") else None,
        action="proposal.create", category="kubernetes", target=f"{cluster.name}",
        detail={"proposal_id": str(p.id), "kind": "kubernetes", "title": p.title},
    )
    return p


REMEDY_NOT_EXECUTED = ("Bossman does not execute a diagnosis remedy. The approval records that a second person "
                       "checked it; the attached Ansible / DSC / PowerShell artifacts are run by a person or a "
                       "pipeline, and a new diagnosis verifies the result (the rule must be gone).")


async def create_remedy_proposal(
    session: AsyncSession, row, finding_index: int, requested_by: str | None,
) -> ChangeProposal:
    """File the remedy of one finding of a stored diagnosis as a proposal (plan B10). The preview carries what a
    reviewer needs: the claim and its certainty, the evidence it rests on, before/after/rollback/verify, and the
    exports for this finding alone. Refused, with the reason, for a finding without a remedy and for a document
    that does not hold — a repair is not offered on a diagnosis that broke the contract."""
    from bossman.services import diagnosis_export as dx

    doc = row.document or {}
    findings = doc.get("findings") or []
    if row.contract_status != "ok":
        raise ValueError("the diagnosis does not hold (" + "; ".join(row.contract_violations[:2])
                         + ") — no remedy is proposed from it")
    if not 0 <= finding_index < len(findings):
        raise ValueError(f"the diagnosis has {len(findings)} finding(s); there is no finding {finding_index}")
    f = findings[finding_index]
    if not f.get("remedy"):
        raise ValueError(f"finding {finding_index} ({f['rule_id']}) offers no remedy")
    only = {**doc, "findings": [f]}
    exports = {fmt: dx.export(only, fmt) for fmt in ("ansible", "dsc", "powershell")}
    evidence = {e["id"]: e for e in doc.get("evidence") or []}
    p = ChangeProposal(
        tenant_id=DEFAULT_TENANT_ID, kind="remedy", agent_id=row.agent_id, host=row.host,
        title=f"Repair {row.target_name} on {row.host}: {f['rule_id']}",
        payload={"diagnosis_row_id": str(row.id), "diagnosis_id": row.diagnosis_id, "finding": finding_index,
                 "rule_id": f["rule_id"], "certainty": f["certainty"], "evidence_ids": f["evidence_ids"],
                 "remedy": f["remedy"]},
        preview={"claim": f["claim"], "certainty": f["certainty"],
                 "evidence": [evidence[i] for i in f["evidence_ids"] if i in evidence],
                 "precedent": f.get("precedent"), "before": f["remedy"]["before"], "after": f["remedy"]["after"],
                 "rollback": f["remedy"]["rollback"], "verify": f["remedy"]["verify"], "exports": exports},
        requested_by=requested_by, status="pending",
    )
    session.add(p)
    await session.commit()
    await session.refresh(p)
    await record_audit(
        session, actor=requested_by or "unknown",
        actor_kind="external" if (requested_by or "").startswith("ai:") else None,
        action="proposal.create", category="diagnosis", target=row.host,
        detail={"proposal_id": str(p.id), "kind": "remedy", "title": p.title, "diagnosis_id": row.diagnosis_id},
    )
    return p


def approvable(p: ChangeProposal, who: str) -> tuple[bool, str | None]:
    """Whether `who` may approve `p` now, and if not, why — so a UI greys the button with the reason instead of
    reporting a refusal after the click."""
    if p.status != "pending":
        return False, f"the proposal is {p.status}, not pending"
    if p.kind == "remedy" and p.requested_by and p.requested_by == who:
        return False, "four-eyes: the person who proposed a repair cannot approve it — another person must"
    return True, None


async def approve(
    session: AsyncSession, settings: Settings, client_factory, proposal_id: UUID, decided_by: str,
) -> ChangeProposal:
    """Approve → apply for real. Reuses the same document-loop apply path the
    dry-run previewed, records the outcome, and audits who approved it."""
    p = await session.get(ChangeProposal, proposal_id)
    if p is None:
        raise ValueError("no such proposal")
    if p.status != "pending":
        raise ValueError(f"proposal is {p.status}, not pending")
    if p.kind == "remedy":
        ok, why = approvable(p, decided_by)
        if not ok:
            raise ValueError(why)
        # Recorded, never executed: no agent call on this path (a test asserts the client is never built).
        p.status = "approved"
        p.apply_result = {"executed": False, "reason": REMEDY_NOT_EXECUTED,
                          "artifacts": (p.preview or {}).get("exports", {})}
        p.decided_by = decided_by
        p.decided_at = datetime.now(timezone.utc)
        await session.commit()
        await record_audit(
            session, actor=decided_by, action="proposal.approve", category="diagnosis", target=p.host,
            detail={"proposal_id": str(p.id), "kind": "remedy", "result_status": "approved", "executed": False},
        )
        await session.refresh(p)
        return p
    agent = await session.get(Agent, p.agent_id) if p.agent_id else None
    if agent is None:
        raise ValueError("the proposal's host no longer exists")

    result: dict[str, Any] = {}
    status = "applied"
    try:
        if p.kind == "config":
            client = client_factory(agent, settings)
            result = await client.state_apply({"resources": p.payload.get("resources", [])}, False)
        elif p.kind == "kubernetes":
            from bossman.services import resources  # local: resources imports this module's creator

            pl = p.payload or {}
            if pl.get("manifests"):
                # an application: every object in order, through the same Resource, with the waiver
                from bossman.db.models import KubernetesCluster
                from bossman.services import kubernetes_app

                cluster = await session.get(KubernetesCluster, UUID(str(pl.get("cluster_id"))))
                if cluster is None:
                    raise ValueError("the proposal's Kubernetes cluster is no longer registered")
                result = await kubernetes_app.apply_all(session, agent, client_factory, settings, cluster, pl["manifests"],
                                                        requested_by=decided_by, note=f"{p.title} (approved by {decided_by}, proposal {p.id})",
                                                        require_approval=False)
            else:
                r = await resources.build("k8s", agent_id=agent.id, name=pl.get("name"), session=session, settings=settings,
                                          client_factory=client_factory, identity=type("_Id", (), {"name": decided_by})(),
                                          cluster=pl.get("cluster_id"), namespace=pl.get("namespace"),
                                          api_version=pl.get("api_version"), object_kind=pl.get("kind"))
                # the generation's note keeps the proposal's title, so "rollback to gen 3" survives the approval
                note = f"{p.title} (approved by {decided_by}, proposal {p.id})"
                if pl.get("delete"):
                    result = await r.delete(preview=False, note=note, require_approval=False)
                else:
                    result = await r.apply({"manifest": pl.get("manifest") or {}, "require_approval": False},
                                           dry_run=False, note=note)
            if not result.get("ok"):
                status = "failed"
        else:
            raise ValueError(f"unsupported proposal kind {p.kind!r}")
    except Exception as exc:  # noqa: BLE001 — a failed apply is a recorded outcome, not a 500
        status = "failed"
        result = {"error": str(exc)}

    p.status = status
    p.apply_result = result
    p.decided_by = decided_by
    p.decided_at = datetime.now(timezone.utc)
    await session.commit()
    await record_audit(
        session, actor=decided_by, action="proposal.approve", category="config",
        target=p.host, status="ok" if status == "applied" else "failed",
        detail={"proposal_id": str(p.id), "kind": p.kind, "result_status": status},
    )
    await session.refresh(p)
    return p


async def reject(session: AsyncSession, proposal_id: UUID, decided_by: str) -> ChangeProposal:
    p = await session.get(ChangeProposal, proposal_id)
    if p is None:
        raise ValueError("no such proposal")
    if p.status != "pending":
        raise ValueError(f"proposal is {p.status}, not pending")
    p.status = "rejected"
    p.decided_by = decided_by
    p.decided_at = datetime.now(timezone.utc)
    await session.commit()
    await record_audit(
        session, actor=decided_by, action="proposal.reject", category="config",
        target=p.host, detail={"proposal_id": str(p.id), "kind": p.kind},
    )
    await session.refresh(p)
    return p
