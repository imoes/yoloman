"""Deploying a VM: create it on a registered hypervisor and arm the PXE restore of a golden image — the ONE
implementation behind REST `POST /api/v1/provisioning/vm-hosts/{id}/auto-provision` and the MCP tools
`vm_hosts`, `deploy_vm` and `deployment_status`.

Sequence (unchanged from the REST route it was lifted out of):
  1. create the VM on the hypervisor           -> {vmid, mac}
  2. planned host with provision_mac = that mac (upsert by hostname)
  3. restore job with target_mac = that mac (+ optional bootstrap→production VLAN handoff)

`plan()` is the dry run the MCP tool shows first: it checks everything that can be checked without creating
anything — the image is ready, the node/storage/bridge exist on the hypervisor, the hostname is not an
enrolled host, the static address is free by every source (services/ip_check.py) — and lists each check with
its result, so a refusal names its reason before a VM exists.
"""
from __future__ import annotations

import ipaddress
import logging
import secrets
import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import select

from bossman.db.models import Agent, DiskImage, RestoreJob, VmHost
from bossman.services import hypervisor

log = logging.getLogger(__name__)


class ProvisionError(Exception):
    """A refusal with the HTTP status REST answers it with."""

    def __init__(self, message: str, status: int = 409):
        super().__init__(message)
        self.status = status


def _vault():
    from bossman.config import get_settings
    from bossman.services.vault import Vault

    s = get_settings()
    return Vault(s.vault_key, s.vault_key_path)


def client_for(vm_host: VmHost):
    password = _vault().decrypt(vm_host.secret)
    cls = hypervisor.ProxmoxClient if vm_host.kind == "proxmox" else hypervisor.VCenterClient
    return cls(vm_host.host, vm_host.username, password, verify_tls=vm_host.verify_tls)


async def vm_host_by_name(session, name: str) -> VmHost:
    row = await session.scalar(select(VmHost).where(VmHost.name == name))
    if row is None:
        names = [h.name for h in (await session.scalars(select(VmHost).order_by(VmHost.name))).all()]
        raise ProvisionError(f"no VM host {name!r} (registered: {', '.join(names) or 'none'})", status=404)
    return row


async def image_by_name(session, name: str) -> DiskImage:
    img = await session.scalar(select(DiskImage).where(DiskImage.name == name))
    if img is None:
        names = [i.name for i in (await session.scalars(select(DiskImage).order_by(DiskImage.name))).all()]
        raise ProvisionError(f"no image {name!r} (known: {', '.join(names) or 'none'})", status=404)
    return img


def static_network(address: str, gateway: str, dns: list[str]) -> dict[str, Any]:
    """The provision_network document the netboot restore writes into the target (same shape as the UI's)."""
    iface = ipaddress.IPv4Interface(address)  # raises ValueError on garbage
    gw = ipaddress.IPv4Address(gateway)
    if gw not in iface.network:
        raise ProvisionError(f"gateway {gw} is not inside {iface.network}", status=422)
    return {"mode": "static", "address": str(iface), "gateway": str(gw), "dns": [str(ipaddress.IPv4Address(d)) for d in dns]}


async def plan(session, settings, client_factory, *, vm_host: VmHost | None, node: str, storage: str, bridge: str,
               image: DiskImage | None, hostname: str, network: dict[str, Any] | None,
               install: dict[str, str] | None = None, memory_mb: int | None = None, uefi: bool = False,
               finalize: dict[str, Any] | None = None, ai: bool = False, mac: str | None = None,
               grow: dict[str, Any] | None = None, roles: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    """Every pre-flight check, each with its result. ok is True only when all of them passed.

    vm_host None = bare metal: the machine exists and is identified by `mac` (required for a network install,
    whose boot entry is per MAC; optional for an image restore, where no MAC arms a job the next machine that
    PXE-boots claims, with DHCP open to everyone for a bounded window)."""
    from bossman.services import ip_check

    checks: list[dict[str, Any]] = []

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append({"check": name, "ok": ok, "detail": detail})

    import uuid as _uuid

    from bossman.db.models import SYSTEM_SETTINGS_ID, SystemSettings

    # Same rule as api/images._require_netboot: a stored secret makes the DB toggle authoritative, otherwise the
    # BOSSMAN_NETBOOT_SECRET env being set means on.
    sys_row = await session.get(SystemSettings, _uuid.UUID(SYSTEM_SETTINGS_ID))
    if sys_row is not None and sys_row.netboot_secret:
        netboot_on = bool(sys_row.netboot_enabled)
    else:
        netboot_on = bool(getattr(settings, "netboot_secret", ""))
    add("netboot enabled", netboot_on, "on" if netboot_on else "netboot is off — the PXE container serves no DHCP and "
        "no boot entry; switch it on with set_netboot(enabled=true) (needs an all-hosts grant)")
    if image is not None:
        add("image ready", image.status == "ready", f"{image.name} is {image.status}")
    if install is not None:
        from bossman.services import netinstall as _ni

        drv = _ni.DRIVERS[install["distro"]]
        add("installer available", True, f"{install.get('label') or install['distro']}: {install['kernel']}")
        if memory_mb is not None:
            add("enough memory for the installer", memory_mb >= drv.min_memory_mb,
                f"{memory_mb} MB of the {drv.min_memory_mb} MB the {drv.title} installer needs")
        # The per-MAC installer entry is a pxelinux (BIOS) entry; UEFI netboot reads grub's config instead.
        add("BIOS boot", not uefi, "BIOS" if not uefi else "network installs boot through pxelinux (BIOS) — set uefi=false")
        if "missing_packages" in install:
            miss = install["missing_packages"]
            add("packages available", not miss, ("all of " + ", ".join(install["packages"])) if not miss else
                f"not in the {install['distro']} {install['release']} release or updates repository: {', '.join(miss)} "
                "— the installer would stop and ask; pass packages=[...] without them")
    if vm_host is None:
        from bossman.api.images import normalise_mac

        norm = normalise_mac(mac or "") if mac else ""
        if install is not None:
            add("machine identified by MAC", bool(norm) and len(norm) == 17,
                f"bare metal {norm}" if norm else "a network install boots a per-MAC entry — give the machine's mac")
        else:
            add("machine identified by MAC", True, f"bare metal {norm}" if norm else
                f"no MAC: the next machine that PXE-boots claims the job; DHCP answers everyone for "
                f"{getattr(settings, 'netboot_open_dhcp_minutes', 15)} min")
        placement = None
    else:
        try:
            placement = await client_for(vm_host).placement()
        except hypervisor.HypervisorError as exc:
            placement = None
            add("hypervisor reachable", False, str(exc)[:300])
    if placement is not None:
        by_node = {n.get("node") or n.get("name"): n for n in placement.get("nodes", [])}
        add("node exists", node in by_node, f"{node} in {sorted(by_node)}")
        if node in by_node:
            storages = [x.get("name") for x in by_node[node].get("storages", [])]
            add("storage exists on the node", storage in storages, f"{storage} in {storages}")
            bridges = [x.get("name") for x in by_node[node].get("bridges", by_node[node].get("networks", []))]
            add("bridge exists on the node", bridge in bridges, f"{bridge} in {bridges}")
    if grow and image is not None:
        from bossman.api.images import grow_policy_keys

        policy, mode = grow.get("policy") or {}, grow.get("mode") or "percent"
        keys = grow_policy_keys(image)
        unknown = sorted(set(policy) - keys)
        vals = [int(v) for v in policy.values()]
        problem = (f"unknown keys {unknown} (growable: {sorted(keys)})" if unknown
                   else "values must be 0 or more" if any(v < 0 for v in vals)
                   else "mode must be percent or absolute" if mode not in ("percent", "absolute")
                   else "only one volume can be 0 (it fills the rest)" if mode == "absolute" and vals.count(0) > 1
                   else "")
        add("volume sizing", not problem, problem or f"{mode}: " + ", ".join(f"{k} {v}" for k, v in policy.items())
            + " — for this deployment only; the image's own default is unchanged")
    for r in roles or []:
        from bossman.db.models import OrchestrationPlan

        found = await session.scalar(select(OrchestrationPlan).where(OrchestrationPlan.name == r["name"],
                                                                     OrchestrationPlan.plan_type == "role"))
        add(f"role {r['name']}", found is not None, "bound as desired state once the host exists; it converges "
            "after the first report (approval-gated unless YOLO mode is on)" if found else
            f"no role named {r['name']!r}")
    if finalize and finalize.get("runbook"):
        from bossman.services import finalize as fin
        from bossman.services.compiler import is_yolo_mode

        try:
            await fin.check_runbook(session, finalize["runbook"])
            add("finalization runbook", True, f"{finalize['runbook']} ({'apply' if finalize.get('apply') else 'check mode'})")
        except fin.FinalizeError as exc:
            add("finalization runbook", False, str(exc))
        if ai and finalize.get("apply"):
            yolo = await is_yolo_mode(session)
            add("finalization may apply", yolo, "YOLO mode is on" if yolo else
                "an AI caller may only run the finalization in check mode unless a person turned YOLO mode on "
                "(same gate as run_runbook)")
    existing = await session.scalar(select(Agent).where(Agent.name == hostname))
    # Taken only by a host that has actually reported: a row left by an install that never came up may be reused.
    live_host = existing is not None and existing.enrollment_state == "enrolled" and existing.last_seen_at is not None
    add("hostname not a live host", not live_host,
        "new" if existing is None else (f"{hostname} is {existing.enrollment_state}"
                                        + (f", last report {existing.last_seen_at.isoformat()}" if existing.last_seen_at
                                           else ", never reported — will be reused")))
    if network and network.get("mode") == "static":
        ip = network["address"].split("/")[0]
        prefix_len = int(network["address"].split("/")[1])
        [verdict] = await ip_check.check(session, settings, client_factory, [ip], prefix_len)
        # Re-provisioning the SAME planned host: its own record is the only holder, nothing answers on the
        # wire, and NetBox (when asked) records nothing either.
        src = verdict["sources"]
        live = src.get("live")
        own_record_only = existing is not None and src.get("bossman") == [hostname]
        silent_on_wire = isinstance(live, dict) and live.get("answer") == "none"
        netbox_clear = src.get("netbox") == "no record" or str(src.get("netbox")).startswith("not configured")
        own_only = own_record_only and silent_on_wire and netbox_clear
        add("address free", verdict["verdict"] == "free" or own_only, f"{ip}: {verdict['verdict']} — {verdict['reason']}")
    return {"ok": all(c["ok"] for c in checks), "checks": checks}


async def create_vm_only(vm_host: VmHost, *, node: str, name: str, storage: str, bridge: str, cores: int,
                         memory_mb: int, disk_gib: int, uefi: bool, vlan: int | None, start: bool = True,
                         cpu: str | None = None) -> dict[str, str]:
    """Create the VM (PXE first, empty disk), start it unless start=False, return {vmid, mac} (MAC normalised)."""
    from bossman.api.images import normalise_mac

    try:
        created = await client_for(vm_host).create_vm(node, name.strip(), cores=cores, memory_mb=memory_mb,
                                                      disk_gib=disk_gib, storage=storage, bridge=bridge, uefi=uefi, vlan=vlan,
                                                      start=start, cpu=cpu)
    except hypervisor.HypervisorError as exc:
        raise ProvisionError(f"VM creation failed: {exc}", status=502) from exc
    return {"vmid": str(created.get("vmid") or ""), "mac": normalise_mac(created.get("mac") or "")}


async def auto_provision(session, *, vm_host: VmHost, node: str, name: str, storage: str, bridge: str,
                         cores: int, memory_mb: int, disk_gib: int, uefi: bool, vlan: int | None,
                         image: DiskImage, hostname: str, roles: list[str], network: dict[str, Any],
                         write: bool, target_disk: str | None, production_vlan: int | None,
                         production_bridge: str | None, requested_by: str, grow: dict[str, Any] | None = None,
                         bare_metal_mac: str | None = None) -> dict[str, Any]:
    """Create the VM (or, with vm_host None, take the bare-metal machine by bare_metal_mac — "" arms a wildcard
    job), register the planned host and arm the restore job, with this deployment's own sizing when given."""
    from bossman.api.images import RestoreJobOut  # the response shape REST has always returned

    if image.status != "ready":
        raise ProvisionError(f"image {image.name!r} is {image.status}, not ready to deploy")
    hostname = hostname.strip()
    if not hostname:
        raise ProvisionError("hostname is required", status=422)
    from bossman.api.images import normalise_mac

    if vm_host is None:
        vmid, mac = "", normalise_mac(bare_metal_mac or "")
    else:
        try:
            created = await client_for(vm_host).create_vm(
                node, name.strip(), cores=cores, memory_mb=memory_mb, disk_gib=disk_gib, storage=storage,
                bridge=bridge, uefi=uefi, vlan=vlan)
        except hypervisor.HypervisorError as exc:
            log.warning("auto-provision create-vm on %s (%s/%s) failed: %s", vm_host.host, node, name, exc)
            raise ProvisionError(f"VM creation failed: {exc}", status=502) from exc
        vmid = str(created.get("vmid") or "")
        mac = normalise_mac(created.get("mac") or "")
    new_meta = {"provision_mac": mac, "provision_network": network or {}, "provision_roles": list(roles),
                "provision_write": bool(write)}
    planned = await session.scalar(select(Agent).where(Agent.name == hostname))
    if planned is not None:
        meta = dict(planned.agent_metadata or {})
        meta.update(new_meta)
        planned.agent_metadata = meta
        planned.enrollment_state = "planned"
    else:
        planned = Agent(name=hostname, address=None, token=secrets.token_hex(16), mode="standalone",
                        enrollment_state="planned", agent_metadata=new_meta)
        session.add(planned)
    await session.flush()

    if mac:
        dupe = await session.scalar(
            select(RestoreJob).where(RestoreJob.target_mac == mac, RestoreJob.status.in_(("pending", "running"))))
        if dupe is not None:
            raise ProvisionError(f"{mac} already has an active job ({dupe.status})")
    handoff = vm_host is not None and (production_bridge is not None or production_vlan is not None)
    job = RestoreJob(
        image_id=image.id, target_mac=mac, target_hostname=hostname, target_disk=target_disk, agent_id=planned.id,
        vm_host_id=vm_host.id if handoff else None, vm_node=node if handoff else None, vm_id=vmid if handoff else None,
        production_vlan=production_vlan if handoff else None, production_bridge=production_bridge if handoff else None,
    )
    if grow and grow.get("policy"):
        job.grow_policy = {k: int(v) for k, v in grow["policy"].items()}
        job.grow_mode = grow.get("mode") or "percent"
    session.add(job)
    await session.commit()
    log.info("auto-provision: host=%s vmid=%s mac=%s -> planned %s + restore job %s (by %s)",
             hostname, vmid, mac, planned.id, job.id, requested_by)
    return {"vmid": vmid, "mac": mac, "host_id": str(planned.id), "hostname": hostname,
            "job": RestoreJobOut.from_model(job).model_dump(mode="json")}


async def status(session, hostname: str) -> dict[str, Any]:
    """Where a deployment stands: the newest restore job or network install for the hostname, and the host."""
    from bossman.services import netinstall

    await netinstall.reconcile(session)
    agent = await session.scalar(select(Agent).where(Agent.name == hostname))
    job = await session.scalar(select(RestoreJob).where(RestoreJob.target_hostname == hostname)
                               .order_by(RestoreJob.created_at.desc()).limit(1))
    install = await netinstall.status(session, hostname)
    from bossman.services import finalize as fin

    finalization = await fin.status(session, hostname)
    if agent is None and job is None and install is None:
        raise ProvisionError(f"no deployment for {hostname!r}", status=404)
    out: dict[str, Any] = {"hostname": hostname}
    if install is not None:
        out["install"] = install
    if finalization is not None:
        out["finalize"] = finalization
    if job is not None:
        steps = job.steps or []
        out["restore"] = {"status": job.status, "step": f"{job.step_index}/{len(steps)}",
                          "current": (steps[job.step_index] if 0 <= job.step_index < len(steps) else None),
                          "error": job.error, "log_tail": (job.log or "")[-1200:]}
    if agent is not None:
        out["host"] = {"enrollment_state": agent.enrollment_state, "address": agent.address,
                       "agent_version": agent.agent_version,
                       "last_seen_at": agent.last_seen_at.isoformat() if agent.last_seen_at else None}
    return out


async def delete_vm(session, vm_host: VmHost, vmid: str, *, remove_host: bool = False) -> dict[str, Any]:
    """Destroy a VM — only one Bossman itself created (a netinstall or restore job on this hypervisor names its
    vmid). Its job becomes `vm_deleted` whatever state it was in (the reason names the previous one), so a list
    never shows "done" for a VM that no longer exists, and a finalization still waiting for it is `cancelled`; its
    agent row goes too when that agent never reported (a host that did
    report keeps its history and is removed with DELETE /api/v1/agents/{id})."""
    from bossman.api.agents import purge_agent_rows
    from bossman.db.models import NetinstallJob

    ni = await session.scalar(select(NetinstallJob).where(NetinstallJob.vm_host_id == vm_host.id,
                                                          NetinstallJob.vm_id == str(vmid))
                              .order_by(NetinstallJob.created_at.desc()).limit(1))
    rj = await session.scalar(select(RestoreJob).where(RestoreJob.vm_host_id == vm_host.id, RestoreJob.vm_id == str(vmid))
                              .order_by(RestoreJob.created_at.desc()).limit(1))
    job = ni or rj
    if job is None:
        raise ProvisionError(f"VM {vmid} on {vm_host.name} was not created by Bossman (no install or restore job "
                             "names it) — refusing to delete it", status=403)
    try:
        out = await client_for(vm_host).vm_delete(str(vmid), job.vm_node)
    except hypervisor.HypervisorError as exc:
        raise ProvisionError(f"deleting VM {vmid} failed: {exc}", status=502) from exc
    from bossman.db.models import DeployFinalization

    previous = job.status
    job.status, job.error = "vm_deleted", f"VM {vmid} on {vm_host.name} was deleted (the deployment was {previous})"
    job.finished_at = job.finished_at or datetime.now(timezone.utc)
    if job.agent_id:
        for fin in (await session.scalars(select(DeployFinalization).where(DeployFinalization.agent_id == job.agent_id,
                                                                           DeployFinalization.status == "waiting"))).all():
            fin.status, fin.error = "cancelled", f"VM {vmid} was deleted before the host reported"
    agent = await session.get(Agent, job.agent_id) if job.agent_id else None
    out["agent"] = ("kept (it has reported; vm_delete(remove_host=true) removes it with its history)"
                    if agent and agent.last_seen_at else "none")
    if agent is not None and (agent.last_seen_at is None or remove_host):
        from sqlalchemy import text

        # The same TimescaleDB budget as DELETE /api/v1/agents/{id}: a host with compressed metrics cannot be
        # deleted under the default decompression cap.
        await session.execute(text("SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0"))
        await purge_agent_rows(session, agent.id)
        await session.delete(agent)
        out["agent"] = f"removed {agent.name} " + ("(never reported)" if agent.last_seen_at is None else "and its history (remove_host)")
    await session.commit()
    return out


async def bind_roles(session, settings, client_factory, agent: Agent, roles: list[dict[str, Any]],
                     requested_by: str) -> list[dict[str, Any]]:
    """Bind each role to the new host as desired state — the same RoleResource.apply as the Role bindings snap-in
    and resource_apply(kind="role"). It converges after the host's first report; without YOLO mode a binding waits
    for approval (four-eyes). Before, deploy_vm(roles=[...]) only stored the names and nothing ever bound them."""
    from bossman.services.resources.role import RoleResource

    out = []
    for r in roles:
        res = await RoleResource(session, agent, client_factory, settings, r["name"], requested_by=requested_by).apply(
            {"params": r.get("params") or {}}, dry_run=False, note="deploy")
        out.append({"role": r["name"], "ok": bool(res.get("ok", True)), "status": res.get("status") or res.get("link_status"),
                    "error": res.get("error")})
    return out


async def deploy(session, settings, client_factory, *, req: dict[str, Any], requested_by: str, ai: bool) -> dict[str, Any]:
    """The ONE deployment path — MCP deploy_vm and the deploy wizard (POST /api/v1/provisioning/deploy).

    req: name, address (CIDR), gateway, dns[], exactly one of image|install, and
      target "vm" (default: vm_host, node, storage, bridge, optional vlan, cores, memory_mb, disk_gib, uefi,
             production_vlan / production_bridge for an image restore's bootstrap→production handoff)
      or "bare_metal" (mac — required for install; for an image "" arms a wildcard job);
    optionally hostname, roles[] (names or {name, params}: bound as desired state once the host exists),
    grow_policy + grow_mode (an image restore's own volume sizing, keyed by mountpoint or role), packages[],
    write, finalize_runbook, finalize_variables, finalize_apply, dry_run (default true). Pre-flight checks run
    first and are returned; a real run is refused while any fails."""
    from bossman.services import finalize as fin
    from bossman.services import netinstall as ni

    image, install = req.get("image") or None, req.get("install") or None
    if (image is None) == (install is None):
        raise ProvisionError("give exactly one of image=<golden image> or install=<distro[-release]>", status=422)
    name = (req.get("name") or "").strip()
    if not name:
        raise ProvisionError("name is required", status=422)
    hostname = (req.get("hostname") or name).strip()
    dry_run = req.get("dry_run", True)
    memory_mb, cores, disk_gib = int(req.get("memory_mb", 2048)), int(req.get("cores", 2)), int(req.get("disk_gib", 32))
    uefi, vlan = bool(req.get("uefi", False)), req.get("vlan")
    target = req.get("target") or "vm"
    if target not in ("vm", "bare_metal"):
        raise ProvisionError("target must be vm or bare_metal", status=422)
    bare = target == "bare_metal"
    roles = [r if isinstance(r, dict) else {"name": str(r), "params": {}} for r in (req.get("roles") or [])]
    grow = ({"policy": dict(req["grow_policy"]), "mode": req.get("grow_mode") or "percent"}
            if req.get("grow_policy") else None)
    finalize = ({"runbook": req["finalize_runbook"], "variables": req.get("finalize_variables") or {},
                 "apply": bool(req.get("finalize_apply"))} if req.get("finalize_runbook") else None)
    try:
        host = None if bare else await vm_host_by_name(session, req["vm_host"])
        img = await image_by_name(session, image) if image else None
        network = static_network(req["address"], req["gateway"], req.get("dns") or [])
        inst = None
        if install:
            distro, release = ni.parse_install(install)
            inst = await ni.resolve_release(settings, distro, release)
            ni.http_base(settings)  # refuse now, not after the VM exists
            inst["packages"], inst["missing_packages"] = await ni.missing_packages(settings, inst, req.get("packages"))
    except ni.NetinstallError as exc:
        raise ProvisionError(str(exc), status=exc.status) from exc
    except (KeyError, ValueError) as exc:
        raise ProvisionError(f"invalid request: {exc}", status=422) from exc
    pre = await plan(session, settings, client_factory, vm_host=host, node=req.get("node", ""),
                     storage=req.get("storage", ""), bridge=req.get("bridge", ""), image=img, hostname=hostname,
                     network=network, install=inst, memory_mb=None if bare else memory_mb, uefi=uefi,
                     finalize=finalize, ai=ai, mac=req.get("mac"), grow=grow, roles=roles)
    head = {"hostname": hostname, "target": target, "network": network, "vlan": vlan, "install": inst,
            "finalize": finalize, "roles": [r["name"] for r in roles], "grow": grow}
    if dry_run or not pre["ok"]:
        return {"dry_run": dry_run, "would_deploy": pre["ok"], **head, **pre}
    try:
        if img is not None:
            done = await auto_provision(
                session, vm_host=host, node=req.get("node", ""), name=name, storage=req.get("storage", ""),
                bridge=req.get("bridge", ""), cores=cores, memory_mb=memory_mb, disk_gib=disk_gib, uefi=uefi, vlan=vlan,
                image=img, hostname=hostname, roles=[r["name"] for r in roles], network=network,
                write=bool(req.get("write", True)), target_disk=None, production_vlan=req.get("production_vlan"),
                production_bridge=req.get("production_bridge") or (req.get("bridge") if req.get("production_vlan") else None),
                requested_by=requested_by, grow=grow, bare_metal_mac=req.get("mac") if bare else None)
            agent_id, out = done["host_id"], {"vmid": done["vmid"], "mac": done["mac"], "job": done["job"]}
        else:
            # Created stopped: the pxe container mirrors the installer first and reports readiness, and Bossman
            # starts the VM then (netinstall.mark_ready).
            if bare:
                from bossman.api.images import normalise_mac

                created = {"vmid": None, "mac": normalise_mac(req.get("mac") or "")}
            else:
                created = await create_vm_only(host, node=req["node"], name=name, storage=req["storage"],
                                               bridge=req["bridge"], cores=cores, memory_mb=memory_mb, disk_gib=disk_gib,
                                               uefi=uefi, vlan=vlan, start=False, cpu=ni.DRIVERS[inst["distro"]].cpu_model)
            job = await ni.create(session, settings, mac=created["mac"], hostname=hostname, network=network, install=inst,
                                  packages=req.get("packages"), vm_host_id=host.id if host else None,
                                  vm_node=req.get("node") if host else None, vm_id=created["vmid"], created_by=requested_by)
            agent_id = job.agent_id
            out = {"vmid": created["vmid"], "mac": created["mac"],
                   "install": {"job_id": str(job.id), "distro": job.distro, "release": job.release,
                               "label": inst.get("label"), "status": job.status, "packages": job.packages}}
        agent = await session.get(Agent, uuid.UUID(str(agent_id))) if agent_id else None
        out["host_id"] = str(agent_id) if agent_id else None
        if roles and agent is not None:
            out["roles"] = await bind_roles(session, settings, client_factory, agent, roles, requested_by)
        if finalize:
            row = await fin.arm(session, agent, runbook=finalize["runbook"], variables=finalize["variables"],
                                apply=finalize["apply"], requested_by=requested_by)
            out["finalize"] = {"runbook": row.runbook, "apply": row.apply, "status": row.status}
    except ni.NetinstallError as exc:
        raise ProvisionError(str(exc), status=exc.status) from exc
    return {"dry_run": False, **pre, "hostname": hostname, **out}
