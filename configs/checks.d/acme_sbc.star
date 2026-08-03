# ===== translated Checkmk check: acme_sbc =====
# READ-ONLY Starlark check module.
# The original parses the `<<<acme_sbc>>>` Checkmk agent section, which only
# exists when the proprietary "acme_sbc" system is present and emitting that
# section through its special agent. There is no on-host binary to probe, so on
# hosts without that setup discovery yields nothing and the check reports UNKNOWN.

def main(ctx, params):
    if params.get("_discover"):
        # The `<<<acme_sbc>>>` section is produced by a Checkmk special agent for
        # the proprietary acme_sbc product. Without that agent/section present,
        # this check does not apply — return an empty discovery list (never a
        # placeholder item, never a hardcoded name).
        return {"changed": False, "msg": "no acme_sbc source found",
                "data": {"discovery": []}}

    # No on-host source for the real data: report UNKNOWN, never OK/zero metrics.
    return {"changed": False,
            "msg": "acme_sbc section not available on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}