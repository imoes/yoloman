## checkmk.citrix_hostsystem_vms — translated Starlark check module
## This is a single-service (no per-item) check that reads the Citrix
## hostsystem data source on-host. In Checkmk the data comes from a
## special agent / section, but per the translation contract we read the
## SAME underlying host source the agent plugin would: here that is the
## Citrix XenServer / Citrix Hypervisor host state. There is no standard
## CLI that exposes "VMs running" and "CitrixPoolName" on a plain Linux
## host, so we probe for the real Citrix tooling first; absence is an
## answer -> empty discovery / UNKNOWN.

def main(ctx, params):
    if params.get("_discover"):
        # --- Discovery mode: enumerate services this host actually has.
        # The citrix_hostsystem_vms check is single-service: it yields one
        # Service() iff there is at least one VM, i.e. iff the Citrix host
        # system data is present. We surface it with the one metric this
        # item exposes (vm_count), matching the check's perfdata.
        data = _read_citrix_section(ctx)
        if data == None or len(data["vms"]) == 0:
            return {"changed": False, "msg": "Citrix hostsystem not present on this host",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False,
                "msg": "discovered Citrix VMs service",
                "data": {"discovery": [
                    {"item": "",
                     "params": {},
                     "metrics": ["vm_count"]}
                ],
                "host_labels": _host_labels(data)}}

    # --- Check mode: grade the single service for params.item (must be "").
    item = params.get("item", "")
    if item != "":
        return {"changed": False, "msg": "single-service check, item must be empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = _read_citrix_section(ctx)
    if data == None:
        return {"changed": False,
                "msg": "no Citrix hostsystem found (citrixcli/xe not installed or not a Citrix host)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vmlist = data["vms"]
    count = len(vmlist)
    summary = "%d VMs running: %s" % (count, ", ".join(vmlist))
    return {"changed": False,
            "msg": summary,
            "data": {"state": "OK", "metrics": {"vm_count": count}, "details": ""}}


## ---------------------------------------------------------------------------
## Real on-host data source for the citrix_hostsystem section.
## Checkmk's Citrix special agent queries the XenServer / Citrix Hypervisor
## host via the XenAPI and emits VMName / CitrixPoolName lines. The on-host
## equivalent accessible from a standard Linux shell is the `xe` CLI (or
## `citrixcli`); we probe for it first. If neither is present this host has
## nothing to do with Citrix -> return None (absence is an answer).
## ---------------------------------------------------------------------------

def _read_citrix_section(ctx):
    # Probe for the real Citrix tooling. rc==127 => not installed.
    probe = ctx.run(["xe", "host-list", "--minimal"], mutates=False)
    if probe.rc == 127:
        # `xe` not on PATH; this is almost certainly not a Citrix host.
        return None
    if probe.rc != 0:
        # Non-zero, non-127: xe exists but could not talk to a host.
        return None

    # Enumerate VMs on this Citrix host (only those currently running,
    # matching the check's "VMs running" wording). `xe vm-list` with
    # power-state=haled lists running VMs; we join the name-label column.
    vms = []
    vmres = ctx.run(["xe", "vm-list", "power-state=running", "--minimal"], mutates=False)
    if vmres.rc == 0 and vmres.stdout.strip() != "":
        # xe --minimal returns a comma-separated list of object references;
        # resolve each to its name-label via xe vm-param-get.
        refs = [r for r in vmres.stdout.strip().split(",") if r != ""]
        for ref in refs:
            name_res = ctx.run(["xe", "vm-param-get", "param-name=name-label", "uuid=" + ref],
                               mutates=False)
            if name_res.rc == 0 and name_res.stdout.strip() != "":
                name = name_res.stdout.strip()
                if name not in vms:
                    vms.append(name)

    # Pool name: the CitrixPoolName line is host-wide (same for all VMs).
    pool = ""
    pool_res = ctx.run(["xe", "pool-list", "--minimal"], mutates=False)
    if pool_res.rc == 0 and pool_res.stdout.strip() != "":
        pool_refs = [r for r in pool_res.stdout.strip().split(",") if r != ""]
        if len(pool_refs) > 0:
            name_res = ctx.run(["xe", "pool-param-get", "param-name=name-label",
                                "uuid=" + pool_refs[0]], mutates=False)
            if name_res.rc == 0:
                pool = name_res.stdout.strip()

    # If we got neither VMs nor a pool, the Citrix host is effectively inert.
    if len(vms) == 0 and pool == "":
        return None

    return {"vms": tuple(vms), "pool": pool}


def _host_labels(data):
    labels = {}
    # Stable, host-wide facts about the Citrix host — not measurements.
    if data["pool"] != "":
        labels["cmk/citrix_pool"] = data["pool"]
    return labels