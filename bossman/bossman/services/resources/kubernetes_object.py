"""KubernetesObjectResource — ONE Kubernetes object behind the Resource contract (docs/resource-protocol.md).

Identity: cluster + namespace + apiVersion + kind + name. The URL's agent is the cluster's ACCESS HOST
(checked in the registry's build()); every verb runs `kubectl` there through the agent module. The
cluster's API server is the only writer — this class never touches etcd.

The verbs, in Kubernetes terms:

* observe()   — `kubectl get … -o json`: spec (desired, ours) and status (observed, the controller's),
                plus the exhaustive state the console shows. None when the object does not exist.
* plan()      — `apply --dry-run=server` (admission + validation on the API server, nothing persisted)
                and `kubectl diff`: what WOULD change, with the server's warnings. The preview.
* apply()     — server-side apply with field manager "bossman" + --validate=strict, then a Bossman
                generation (the manifest). Honours the approval gate: without YOLO mode and without a
                waiver it files a ChangeProposal carrying the preview and records NO generation — a
                generation that was never applied would be a false rollback target.
* rollback()  — re-apply an earlier generation's manifest as a NEW generation (forward-converge, like
                docker/helm). Kubernetes' own `rollout history` revisions are a second, separately
                labelled numbering the UI shows next to this one.
* delete()    — the extra verb (DELETE …/object): previews the dependents that go with it
                (ownerReferences) and the PVCs that stay, then deletes and records the deletion as a
                generation — the object appears as "vanished" in its history, never silently gone.
"""
from __future__ import annotations

import json
from typing import Any

from bossman.db.models import KubernetesCluster
from bossman.services import config_schema, kubernetes
from bossman.services.compiler import is_yolo_mode
from bossman.services.kubernetes import KubectlFailed
from bossman.services.resources import base

_SCHEMA: dict[str, Any] = {
    "manifest": {"type": "object", "required": True,
                 "description": "the object's full manifest (apiVersion, kind, metadata, spec/data)"},
}


def _deep_merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for k, v in over.items():
        out[k] = _deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def _clean_manifest(obj: dict[str, Any]) -> dict[str, Any]:
    """The object as one would re-apply it: no status, no server-owned metadata (managedFields,
    resourceVersion, uid, timestamps). The field managers are reported separately."""
    out = {k: v for k, v in obj.items() if k != "status"}
    md = dict(out.get("metadata") or {})
    for k in ("managedFields", "resourceVersion", "uid", "creationTimestamp", "generation", "selfLink"):
        md.pop(k, None)
    out["metadata"] = md
    return out


class KubernetesObjectResource:
    resource_type = "k8s_object"

    def __init__(self, session, agent, client_factory, settings, name: str, *, cluster: KubernetesCluster,
                 namespace: str | None = None, api_version: str = "v1", kind: str = "ConfigMap",
                 requested_by: str | None = None):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self.cluster = cluster
        self.name = name
        self.namespace = namespace or None
        self.api_version = api_version or "v1"
        self.kind = kind or "ConfigMap"
        self.requested_by = requested_by
        self.resource_key = f"k8s:{cluster.id}:{self.namespace or '-'}:{self.api_version}:{self.kind}:{name}"
        self._schema: dict[str, Any] = {}
        self._index: dict[str, list[str]] = {}

    # ---- identity helpers ---------------------------------------------------------------------

    @property
    def _resource_arg(self) -> str:
        """`kind.version.group` — unambiguous for kubectl even when two groups share a kind name."""
        if "/" in self.api_version:
            group, version = self.api_version.split("/", 1)
            return f"{self.kind}.{version}.{group}"
        return self.kind

    def _client(self):
        return self._cf(self._agent, self._settings)

    async def _namespaces_changed(self) -> None:
        """A Namespace was created or deleted THROUGH Bossman: re-read the cluster inventory now. The explorer's
        namespace picker and the Application form's pre-flight read the inventory cache (poller, 15 min), and a
        cache that lacks the namespace Bossman itself just created makes both say it does not exist."""
        if self.kind != "Namespace":
            return
        from datetime import datetime, timezone

        await kubernetes.refresh_inventory(self._session, self.cluster, self._client(), datetime.now(timezone.utc))
        await self._session.commit()

    _CONTROL_KEYS = ("require_approval", "dry_run", "note")

    @staticmethod
    def _body_of(obj: dict[str, Any]) -> tuple[str | None, dict[str, Any]]:
        """Where a kind keeps its editable values: `spec` for spec'd kinds, else the top-level data-ish keys
        (ConfigMap data, Role rules, …). Returns (root key or None for top level, the body)."""
        if isinstance(obj.get("spec"), dict):
            return "spec", obj["spec"]
        return None, {k: v for k, v in obj.items() if k in ("data", "stringData", "binaryData", "rules", "subjects", "roleRef", "type", "immutable")}

    async def _normalize(self, desired: dict[str, Any]) -> dict[str, Any]:
        """The manifest to apply, with its identity pinned to THIS resource.

        Three input shapes, one result: `{"manifest": {...}}`, a bare manifest (has `kind`), or FLAT FIELD
        VALUES as the generic inspector's form posts them (the keys `schema_async()` derived). Flat values
        are inflated through the live object's own key index (the same flatten/inflate the config tier
        uses, so a dotted key keeps its exact segments) and merged into the live manifest — which is how
        "change one field, preview, apply" works without the UI knowing the kind.

        A manifest naming another object is refused: applying "web" through the resource for "api" would
        write the wrong object and record the generation under the wrong key."""
        if isinstance(desired.get("manifest"), dict):
            manifest = desired["manifest"]
        elif desired.get("kind") or desired.get("apiVersion"):
            manifest = {k: v for k, v in desired.items() if k not in self._CONTROL_KEYS}
        else:
            flat = {k: v for k, v in desired.items() if k not in self._CONTROL_KEYS}
            live = await self._get()
            if live is None:
                raise ValueError("flat field values need an existing object to merge into — this one does not exist; send a manifest")
            manifest = _clean_manifest(live["object"])
            root, body = self._body_of(manifest)
            _flat_live, index = config_schema.flatten(body)
            merged = _deep_merge(body, config_schema.inflate(flat, index))
            if root:
                manifest[root] = merged
            else:
                manifest.update(merged)
        manifest = json.loads(json.dumps(manifest))  # a copy we may edit
        manifest.setdefault("apiVersion", self.api_version)
        manifest.setdefault("kind", self.kind)
        md = manifest.setdefault("metadata", {})
        md.setdefault("name", self.name)
        if self.namespace:
            md.setdefault("namespace", self.namespace)
        mismatch = [f"{k}: manifest says {v!r}, resource is {w!r}" for k, v, w in (
            ("kind", manifest.get("kind"), self.kind), ("apiVersion", manifest.get("apiVersion"), self.api_version),
            ("metadata.name", md.get("name"), self.name), ("metadata.namespace", md.get("namespace"), self.namespace),
        ) if (v or None) != (w or None)]
        if mismatch:
            raise ValueError("manifest does not describe this object — " + "; ".join(mismatch))
        md.pop("managedFields", None)
        md.pop("resourceVersion", None)
        md.pop("uid", None)
        md.pop("creationTimestamp", None)
        md.pop("generation", None)
        manifest.pop("status", None)
        return manifest

    # ---- the verbs ------------------------------------------------------------------------------

    def schema(self) -> dict[str, Any]:
        """Sync half of the contract — the static shape until schema_async ran."""
        return self._schema or _SCHEMA

    async def schema_async(self) -> dict[str, Any]:
        """One typed field per value present in the live spec/data (never one JSON blob) — the same
        flatten/derive the config and Helm tiers use, so dotted keys round-trip exactly."""
        doc = await self._get()
        if doc is None:
            self._schema = {}
            return dict(_SCHEMA)
        _root, body = self._body_of(doc["object"])
        if not body:
            self._schema = {}
            return dict(_SCHEMA)
        _flat, self._index = config_schema.flatten(body)
        self._schema = config_schema.derive_schema(body)
        return self._schema

    async def _get(self) -> dict[str, Any] | None:
        try:
            doc = await kubernetes.get_object(self._client(), self.cluster, self._resource_arg, self.name, namespace=self.namespace)
        except KubectlFailed as exc:
            if "NotFound" in exc.stderr or "not found" in exc.stderr or "doesn't have a resource type" in exc.stderr:
                return None
            raise
        return doc

    async def observe(self) -> dict[str, Any] | None:
        doc = await self._get()
        if doc is None:
            return None
        obj = doc["object"]
        return {
            "name": self.name, "namespace": self.namespace, "kind": obj.get("kind"), "api_version": obj.get("apiVersion"),
            "spec": doc.get("spec"), "status": doc.get("status"),
            "data_keys": doc.get("data_keys"), "labels": (doc.get("metadata") or {}).get("labels") or {},
            "state": doc["row"]["state"], "summary": doc["row"]["summary"],
            "versions": doc["versions"], "field_managers": doc["field_managers"], "etcd_key": doc["etcd_key"],
            "manifest": _clean_manifest(obj),
        }

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        manifest = await self._normalize(desired)
        text = json.dumps(manifest)
        client = self._client()
        observed = await self.observe()
        out: dict[str, Any] = {"resource_key": self.resource_key, "desired": {"manifest": manifest},
                               "observed": {k: observed.get(k) for k in ("state", "versions", "summary")} if observed else None}
        try:
            dry = await kubernetes.call(client, self.cluster, verb="apply-dry-run", manifest=text, namespace=self.namespace)
        except KubectlFailed as exc:
            # The server refused the manifest (validation, admission, Pod Security, quota): that IS the
            # preview — the reason the real apply would fail, shown before it is attempted.
            out.update({"action": "refused", "changed_count": 0, "refused": True, "reason": exc.stderr.strip()[:1500],
                        "server_warnings": None, "diff_text": None})
            return out
        warnings = (dry.get("stderr") or "").strip() or None
        if observed is None:
            out.update({"action": "create", "changed_count": 1, "server_warnings": warnings, "diff_text": None,
                        "result_object": dry.get("parsed")})
            return out
        diff = await kubernetes.call(client, self.cluster, verb="diff", manifest=text, namespace=self.namespace,
                                     args=["--server-side", "--field-manager=" + kubernetes.KUBECTL_FIELD_MANAGER_NAME])
        differs = bool(diff.get("differs")) or diff.get("rc") == 1   # the module sets differs; rc 1 is the same fact
        out.update({"action": "update" if differs else "noop", "changed_count": 1 if differs else 0,
                    "server_warnings": warnings or ((diff.get("stderr") or "").strip() or None),
                    "diff_text": (diff.get("stdout") or "") if differs else "", "result_object": dry.get("parsed")})
        return out

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True, note: str | None = None) -> dict[str, Any]:
        require_approval = bool(desired.get("require_approval", True))
        plan = await self.plan(desired)
        if dry_run:
            return {"dry_run": True, "plan": plan}
        if plan.get("refused"):
            return {"dry_run": False, "ok": False, "error": plan["reason"], "plan": plan}
        manifest = plan["desired"]["manifest"]

        if require_approval and not await is_yolo_mode(self._session):
            from bossman.services import proposals  # local: proposals imports resources (approve branch)

            p = await proposals.create_kubernetes_proposal(
                self._session, self._agent, self.cluster, manifest=manifest, preview=plan,
                requested_by=self.requested_by,
                title=f"{self.kind} {self.namespace + '/' if self.namespace else ''}{self.name} on {self.cluster.name}"
                      + (f" — {note}" if note else ""))
            return {"dry_run": False, "ok": True, "applied": False, "status": "pending_approval",
                    "awaiting_approval": True, "proposal_id": str(p.id), "plan": plan}

        try:
            res = await kubernetes.call(self._client(), self.cluster, verb="apply", manifest=json.dumps(manifest), namespace=self.namespace)
        except KubectlFailed as exc:
            return {"dry_run": False, "ok": False, "applied": False, "error": exc.stderr.strip()[:1500], "plan": plan}
        gen = await base.record_generation(self._session, self.resource_key, self.resource_type,
                                           {"manifest": manifest}, note=note, applied_by=self.requested_by)
        await self._namespaces_changed()
        return {"dry_run": False, "ok": True, "applied": True, "status": "applied", "awaiting_approval": False,
                "generation": gen, "plan": plan, "warnings": (res.get("stderr") or "").strip() or None,
                "result_object": res.get("parsed")}

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return await base.no_such_generation(self._session, self.resource_key, generation, f"{self.kind}/{self.name}")
        if spec.get("deleted"):
            # rolling back TO a deletion means deleting again — say so instead of applying an empty spec
            return await self.delete(preview=False, note=f"rollback to gen {generation} (a deletion)",
                                     require_approval=spec.get("require_approval", True))
        return await self.apply({"manifest": spec.get("manifest") or {}, "require_approval": spec.get("require_approval", True)},
                                dry_run=False, note=f"rollback to gen {generation}")

    # ---- the extra verb -------------------------------------------------------------------------

    async def delete(self, *, preview: bool = True, note: str | None = None, require_approval: bool = True) -> dict[str, Any]:
        """What goes with this object, what stays, and — with preview=false — the deletion itself.

        ONE GATE FOR EVERY WRITE: a deletion is a change like an apply or a scale, so outside YOLO mode and without
        a waiver it is filed as a change proposal (carrying this preview) and nothing is deleted. It used to bypass
        the gate — a namespace, and everything in it, went at one click while scaling that namespace's Deployment
        needed an approval."""
        doc = await self._get()
        if doc is None:
            return {"ok": False, "preview": preview, "error": f"{self.kind} {self.name} does not exist", "dependents": [], "kept": []}
        obj = doc["object"]
        uid = (obj.get("metadata") or {}).get("uid")
        dependents: list[dict[str, Any]] = []
        kept: list[dict[str, Any]] = []
        if self.namespace:
            try:
                data = await kubernetes.call(self._client(), self.cluster, verb="get",
                                             resource="pods,replicasets,jobs,persistentvolumeclaims", namespace=self.namespace)
                items = kubernetes._items(data)
            except KubectlFailed:
                items = []
            owned_uids = {uid}
            # two levels: Deployment → ReplicaSet → Pod; CronJob → Job → Pod
            for _ in range(2):
                for it in items:
                    md = it.get("metadata") or {}
                    if any(o.get("uid") in owned_uids for o in (md.get("ownerReferences") or [])) and md.get("uid") not in owned_uids:
                        owned_uids.add(md.get("uid"))
                        dependents.append({"kind": it.get("kind"), "name": md.get("name"), "why": "ownerReference → deleted with it (garbage collection)"})
            tpl = (((obj.get("spec") or {}).get("template") or {}).get("spec") or {})
            for v in tpl.get("volumes") or []:
                claim = (v.get("persistentVolumeClaim") or {}).get("claimName")
                if claim:
                    kept.append({"kind": "PersistentVolumeClaim", "name": claim, "why": "a PVC is never deleted with the workload — its data outlives it"})
            for t in (obj.get("spec") or {}).get("volumeClaimTemplates") or []:
                kept.append({"kind": "PersistentVolumeClaim", "name": f"{(t.get('metadata') or {}).get('name')}-{self.name}-*",
                             "why": "StatefulSet claims stay unless persistentVolumeClaimRetentionPolicy says Delete"})
        if self.kind == "Namespace":
            # A namespace takes EVERYTHING in it along — so the preview lists what is still there instead of
            # an empty "goes with it" that reads as "nothing else is affected".
            try:
                data = await kubernetes.call(self._client(), self.cluster, verb="get",
                                             resource="deployments,statefulsets,daemonsets,cronjobs,jobs,pods,services,"
                                                      "ingresses,configmaps,secrets,persistentvolumeclaims",
                                             namespace=self.name)
                for it in kubernetes._items(data):
                    md = it.get("metadata") or {}
                    if it.get("kind") == "ConfigMap" and md.get("name") == "kube-root-ca.crt":
                        continue   # created by the control plane in every namespace
                    dependents.append({"kind": it.get("kind"), "name": md.get("name"),
                                       "why": "in the namespace → deleted with it"
                                              + (" (its data too: the claim's volume follows its reclaim policy)"
                                                 if it.get("kind") == "PersistentVolumeClaim" else "")})
            except KubectlFailed as exc:
                dependents.append({"kind": "unknown", "name": "?",
                                   "why": f"the namespace's contents could not be listed: {exc.stderr.strip()[:200]}"})
        out = {"ok": True, "preview": preview, "object": {"kind": self.kind, "name": self.name, "namespace": self.namespace},
               "dependents": dependents, "kept": kept}
        if preview:
            return out
        if require_approval and not await is_yolo_mode(self._session):
            from bossman.services import proposals  # local: proposals imports resources (approve branch)

            p = await proposals.create_kubernetes_proposal(
                self._session, self._agent, self.cluster, manifest=_clean_manifest(obj), preview=out,
                requested_by=self.requested_by, delete=True,
                title=f"Delete {self.kind} {self.namespace + '/' if self.namespace else ''}{self.name} on {self.cluster.name}"
                      + (f" — {note}" if note else ""))
            return {**out, "deleted": False, "status": "pending_approval", "awaiting_approval": True,
                    "proposal_id": str(p.id)}
        try:
            res = await kubernetes.call(self._client(), self.cluster, verb="delete", resource=self._resource_arg, name=self.name, namespace=self.namespace)
        except KubectlFailed as exc:
            return {**out, "ok": False, "error": exc.stderr.strip()[:1000]}
        gen = await base.record_generation(self._session, self.resource_key, self.resource_type,
                                           {"deleted": True, "manifest": _clean_manifest(obj)},
                                           note=note or "deleted", applied_by=self.requested_by)
        await self._namespaces_changed()
        return {**out, "deleted": True, "generation": gen, "warnings": (res.get("stderr") or "").strip() or None}
