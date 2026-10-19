"""TunableResource — one kernel tunable on one host as a Resource (docs/kernel-tuning.md, block 4).

The agent's `yoloman.<tunable>` modules (sched_ext, systemd_resource, blockdev_tuning, cpu_governor,
kernel_cmdline) do the work; this class gives them the four verbs plus history, so a kernel tunable is
planned, applied, versioned and rolled back exactly like a container or a config file — and the same MCP
tools (`resource_plan`/`resource_apply`/`resource_rollback`) drive it.

Identity is `<tunable>[:<target>]`: `sched_ext`, `cpu_governor` and `kernel_cmdline` are one per host;
`systemd_resource:<unit>` and `blockdev_tuning:<device>` are one per unit / device. The target part fills
the module's identifying parameter, and a desired spec that names a different one is refused rather than
silently retargeted.

Each generation stores TWO things: `params` (what was applied) and `undo` (the rollback parameters the
module reported — one call that restores the state before that apply, persistence included). So:

* `rollback(n)` for n >= 1 re-applies generation n's `params` as a new generation (forward-converge, the
  uniform contract);
* `rollback(0)` is the named state "before yoloman managed this": it applies the `undo` of the OLDEST
  generation still held. When that generation has been pruned, the refusal says so — the baseline is then
  no longer known, and pretending otherwise would be the silent kind of wrong.

Refusals from the module keep their leading word (`unsupported:`, `tool_unavailable:`, `conflict:`), so a
caller — person or model — can tell "this host cannot" from "something failed".
"""
from __future__ import annotations

from typing import Any

from bossman.services.resources import base

#: tunable → (agent module, identifying parameter or None, human description). The ONE list of tunables
#: Bossman knows; tunable_catalog and the schema both read it.
TUNABLES: dict[str, tuple[str, str | None, str]] = {
    "sched_ext": ("yoloman.sched_ext", None,
                  "BPF CPU scheduler from the scx project (bpfland, lavd, rusty, ...) or back to the fair class"),
    "systemd_resource": ("yoloman.systemd_resource", "unit",
                         "cgroup limits of one systemd unit (CPUWeight, CPUQuota, MemoryMax/High, IOWeight, TasksMax, AllowedCPUs)"),
    "blockdev_tuning": ("yoloman.blockdev_tuning", "device", "readahead and I/O scheduler of one block device"),
    "cpu_governor": ("yoloman.cpu_governor", None, "cpufreq governor and energy/performance preference"),
    "kernel_cmdline": ("yoloman.kernel_cmdline", None, "kernel command-line parameters for the next boot"),
}

#: The words a module puts in front of a refusal; anything else is a failure.
REFUSAL_KINDS = ("unsupported", "tool_unavailable", "conflict")


class TunableError(ValueError):
    """A desired spec that cannot be sent at all (unknown tunable, contradicting target)."""


def parse_name(name: str) -> tuple[str, str | None]:
    """'systemd_resource:cron.service' → ('systemd_resource', 'cron.service'). Validates both parts."""
    tunable, _, target = name.partition(":")
    if tunable not in TUNABLES:
        raise TunableError(f"unknown tunable {tunable!r} (known: {', '.join(sorted(TUNABLES))})")
    key = TUNABLES[tunable][1]
    if key and not target:
        raise TunableError(f"{tunable} is per {key}: address it as {tunable}:<{key}>")
    if not key and target:
        raise TunableError(f"{tunable} is one per host: address it as {tunable} without ':{target}'")
    return tunable, (target or None)


def classify_refusal(message: str) -> dict[str, str]:
    """Split a module error into {kind, reason}. kind is one of REFUSAL_KINDS or 'error'."""
    for kind in REFUSAL_KINDS:
        marker = kind + ":"
        i = message.find(marker)
        if i >= 0:
            return {"kind": kind, "reason": message[i + len(marker):].strip().strip('"}').strip()}
    return {"kind": "error", "reason": message.strip()}


class TunableResource:
    resource_type = "tunable"

    def __init__(self, session, agent, client_factory, settings, name: str):
        self._session = session
        self._agent = agent
        self._cf = client_factory
        self._settings = settings
        self.tunable, self.target = parse_name(name)
        self.module = TUNABLES[self.tunable][0]
        self.name = name
        self.resource_key = f"tunable:{agent.id}:{name}"

    def schema(self) -> dict[str, Any]:
        module, key, desc = TUNABLES[self.tunable]
        return {
            "tunable": {"type": "string", "enum": sorted(TUNABLES), "description": desc},
            "params": {"type": "object", "description": (
                f"the parameters of the agent module {module}; see list_agent_tools for its input schema"
                + (f" ('{key}' comes from the resource name)" if key else ""))},
        }

    def _params(self, desired: dict[str, Any]) -> dict[str, Any]:
        params = dict(desired.get("params", desired))
        key = TUNABLES[self.tunable][1]
        if key:
            given = params.get(key)
            if given not in (None, "", self.target):
                raise TunableError(f"{self.name} addresses {key}={self.target!r}, the spec says {key}={given!r}")
            params[key] = self.target
        return params

    async def _call(self, params: dict[str, Any], *, dry_run: bool) -> dict[str, Any]:
        client = self._cf(self._agent, self._settings)
        try:
            res = await client.call_tool(self.module, {**params, "dry_run": dry_run})
        except Exception as exc:  # noqa: BLE001 — the agent's refusal travels as the error text
            return {"ok": False, "refusal": classify_refusal(str(exc))}
        data = (res.get("data") if isinstance(res, dict) else None) or {}
        return {"ok": True, "changed": bool(res.get("changed")) if isinstance(res, dict) else False,
                "msg": res.get("msg") if isinstance(res, dict) else "", "data": data}

    async def _latest(self) -> dict[str, Any] | None:
        gens = await base.list_generations(self._session, self.resource_key)
        return gens[0] if gens else None

    async def observe(self) -> dict[str, Any] | None:
        """The values as the host reports them, measured against the last applied spec.

        A tunable has no "current value" independent of what is asked about it (which unit, which
        properties), so observation re-asks the module, in check mode, for the spec yoloman last applied:
        `drift` is true when the host no longer matches it. Never managed → `managed: false`."""
        latest = await self._latest()
        if latest is None:
            return {"tunable": self.tunable, "target": self.target, "managed": False}
        params = (latest["spec"] or {}).get("params", {})
        r = await self._call(params, dry_run=True)
        if not r["ok"]:
            return {"tunable": self.tunable, "target": self.target, "managed": True,
                    "generation": latest["generation"], "refusal": r["refusal"]}
        d = r["data"]
        return {"tunable": self.tunable, "target": self.target, "managed": True,
                "generation": latest["generation"], "params": params, "values": d.get("before"),
                "persistence": d.get("persistence"), "drift": r["changed"]}

    async def plan(self, desired: dict[str, Any]) -> dict[str, Any]:
        params = self._params(desired)
        r = await self._call(params, dry_run=True)
        out: dict[str, Any] = {"resource_key": self.resource_key, "desired": params}
        if not r["ok"]:
            return {**out, "action": "refused", "changed": {}, "changed_count": 0, "refusal": r["refusal"]}
        d = r["data"]
        before, after = d.get("before") or {}, d.get("after") or {}
        changed = {k: [before.get(k), after.get(k)] for k in sorted(set(before) | set(after))
                   if before.get(k) != after.get(k)} if r["changed"] else {}
        return {**out, "action": "update" if r["changed"] else "noop", "changed": changed,
                "changed_count": len(changed) if r["changed"] else 0, "persistence": d.get("persistence"),
                "backend": d.get("backend"), "rollback": d.get("rollback"), "msg": r["msg"]}

    async def apply(self, desired: dict[str, Any], *, dry_run: bool = True,
                    note: str | None = None) -> dict[str, Any]:
        plan = await self.plan(desired)
        if dry_run or plan["action"] == "refused":
            return {"dry_run": dry_run, "ok": plan["action"] != "refused", "plan": plan}
        if plan["action"] == "noop":
            return {"dry_run": False, "ok": True, "plan": plan, "generation": None,
                    "msg": "already as requested — no generation recorded"}
        r = await self._call(plan["desired"], dry_run=False)
        if not r["ok"]:
            return {"dry_run": False, "ok": False, "plan": plan, "refusal": r["refusal"]}
        d = r["data"]
        gen = await base.record_generation(
            self._session, self.resource_key, self.resource_type,
            {"params": plan["desired"], "undo": d.get("rollback"), "persistence": d.get("persistence"),
             "before": d.get("before"), "after": d.get("after")},
            note=note)
        return {"dry_run": False, "ok": True, "generation": gen, "plan": plan, "result": d}

    async def generations(self) -> list[dict[str, Any]]:
        return await base.list_generations(self._session, self.resource_key)

    async def rollback(self, generation: int) -> dict[str, Any]:
        if generation == 0:
            gens = await base.list_generations(self._session, self.resource_key)
            if not gens:
                return {"ok": False, "error": f"{self.name} was never applied by yoloman — nothing to roll back"}
            oldest = gens[-1]
            if oldest["generation"] != 1:
                return {"ok": False, "error": (
                    f"the state before yoloman managed {self.name} is no longer known: generation 1 has been "
                    f"pruned (the oldest held is {oldest['generation']}); roll back to a held generation instead")}
            undo = (oldest["spec"] or {}).get("undo")
            if not undo:
                return {"ok": False, "error": f"generation 1 of {self.name} recorded no undo parameters"}
            return await self.apply({"params": undo}, dry_run=False, note="rollback to the state before generation 1")
        spec = await base.get_generation_spec(self._session, self.resource_key, generation)
        if spec is None:
            return await base.no_such_generation(self._session, self.resource_key, generation, self.name)
        return await self.apply({"params": spec.get("params", {})}, dry_run=False, note=f"rollback to gen {generation}")
