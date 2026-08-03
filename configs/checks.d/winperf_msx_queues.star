def main(ctx, params):
    """Translate of Checkmk check: checkmk.winperf_msx_queues

    Replicates the discovery + check logic of the Checkmk winperf_msx_queues
    plugin for MSX (Microsoft Exchange) queue lengths reported by the
    Windows perf-agent. The original reads a <<<winperf_msx_queues>>> section
    produced by the Windows agent. On our (non-Windows) host there is no such
    section, so discovery returns an empty list and check mode reports UNKNOWN.
    """
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }

    return {
        "changed": False,
        "msg": "winperf_msx_queues section not available on this host",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }