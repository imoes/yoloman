# ===== translated Starlark check module: sansymphony_virtualdiskstatus =====
# READ-ONLY: reports the Online/CRIT state of DataCore SANsymphony virtual disks.
#
# The canonical Checkmk plugin reads its data from the special-agent
# `cmk/plugins/sansymphony` (querying the SANsymphony Management Service over
# the network). On a host there is NO on-host source for this data: it is
# gathered by the SANsymphony special agent, which only exists within a
# Checkmk deployment and is unreachable from this runtime.
#
# Per the translation contract ("ABSENCE IS AN ANSWER"), since no local
# source exists and no special-agent output is available, the honest
# reproduction reports absence: discovery returns an empty list and the
# per-item check returns UNKNOWN stating the data source is unavailable.

def main(ctx, params):
    # -----------------------------------------------------------------------
    # DISCOVERY MODE
    # -----------------------------------------------------------------------
    # PROBE FOR THE REAL THING FIRST: the SANsymphony special agent / local
    # tooling. rc == 127 means not installed / absent.
    probe = ctx.run(["sansymphony_agent", "--version"], mutates=False)
    has_local_source = (probe.rc == 0)

    if params.get("_discover"):
        if not has_local_source:
            # No local source -> nothing to discover. Never synthesise items.
            return {
                "changed": False,
                "msg": "no on-host SANsymphony data source available",
                "data": {"discovery": []},
            }

        # A local source exists in principle, but the original plugin's data
        # comes from the (absent) special agent; without its output section we
        # have no items to enumerate.
        return {
            "changed": False,
            "msg": "SANsymphony special agent not present; cannot discover disks",
            "data": {"discovery": []},
        }

    # -----------------------------------------------------------------------
    # CHECK MODE (single item)
    # -----------------------------------------------------------------------
    # Because discovery yields nothing above (no local source), any requested
    # item cannot be satisfied with real data.
    if not has_local_source:
        return {
            "changed": False,
            "msg": "SANsymphony virtual disk data source unavailable on this host",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "The SANsymphony virtual disk status is collected by the Checkmk SANsymphony special agent; no on-host data source is available here.",
            },
        }

    item = params.get("item", "")
    # We never reach here with data, but if a local source existed we would
    # parse its output. Without it, report the item as UNKNOWN.
    return {
        "changed": False,
        "msg": "no data for SANsymphony virtual disk " + item,
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "Virtual disk " + item + " could not be evaluated: no SANsymphony metric source is reachable.",
        },
    }