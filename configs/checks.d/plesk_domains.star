def main(ctx, params):
    # Read the agent section data for plesk_domains
    # The Checkmk agent plugin would fetch this from: plesk_ext util client --domains-info
    # We replicate that by calling the same command
    res = ctx.run(["plesk_ext", "util", "client", "--domains-info"], mutates=False)
    
    # If command fails or returns empty, we report UNKNOWN
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "No domains configured",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.strip().splitlines()
    # Filter out empty lines
    domains = [line.strip() for line in lines if line.strip()]
    
    if not domains:
        return {
            "changed": False,
            "msg": "No domains configured",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }
    
    # First line is the summary (e.g., "Total: 3 domains"), rest are domain names
    summary = domains[0] if domains else "No domains configured"
    details = "\n".join(domains)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": details
        },
    }