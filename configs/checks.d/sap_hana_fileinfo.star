def main(ctx, params):
    if params.get("_discover"):
        # The real data source: parse_fileinfo consumes an AgentSection
        # "sap_hana_fileinfo". This is produced by an SAP HANA special agent
        # that runs on the host and emits a fileinfo-style section. We have no
        # such agent here, so there is nothing to discover on this host.
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}

    item = params.get("item", "")
    # No Checkmk agent / section present on this host -> data is ungatherable.
    # Discovery correctly returned an empty list; reporting OK here would be a
    # fabrication. Per the contract: UNKNOWN, never a zero/graded metric.
    return {
        "changed": False,
        "msg": "File %s: SAP HANA fileinfo section not available on this host" % item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }