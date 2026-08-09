def main(ctx, params):
    if params.get("_discover"):
        # sansymphony_ports monitors SANsymphony storage array FC/iSCSI ports.
        # This data comes from a special agent querying the storage array
        # management system over the network — there is no on-host source
        # (no local binary, socket, /proc or /sys entry provides Sansymphony
        # port names and statuses on this host). Report absence honestly.
        return {"changed": False, "msg": "no sansymphony_ports data source available on host",
                "data": {"discovery": []}}

    item = params.get("item", "")
    return {"changed": False, "msg": "sansymphony storage array not accessible from host",
            "data": {"state": "UNKNOWN", "metrics": {},
                     "details": "Sansymphony port status requires a special agent querying the storage array management system"}}