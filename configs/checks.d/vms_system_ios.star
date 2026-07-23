# ===== check plugin: vms_system_ios =====

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["vms_system"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "agent plugin 'vms_system' not available or failed",
                "data": {"discovery": []}
            }
        lines = res.stdout.splitlines()
        if len(lines) == 0:
            return {
                "changed": False,
                "msg": "no data from vms_system",
                "data": {"discovery": []}
            }
        parts = lines[0].strip().split()
        if len(parts) < 3:
            return {
                "changed": False,
                "msg": "unexpected data format from vms_system",
                "data": {"discovery": []}
            }
        direct_ios_str = parts[0]
        buffered_ios_str = parts[1]
        # Guard: ensure strings represent floats before conversion
        def is_float_str(s):
            # Accept digits, optional single dot, optional minus, no letters
            s_clean = s.strip()
            if s_clean == "":
                return False
            seen_dot = False
            for c in s_clean:
                if c == '.':
                    if seen_dot:
                        return False
                    seen_dot = True
                elif not c.isdigit():
                    return False
            return True
        
        if not is_float_str(direct_ios_str) or not is_float_str(buffered_ios_str):
            return {
                "changed": False,
                "msg": "failed to parse numeric values from vms_system",
                "data": {"discovery": []}
            }
        
        direct_ios = float(direct_ios_str)
        buffered_ios = float(buffered_ios_str)
        
        return {
            "changed": False,
            "msg": "discovered IOs service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["direct", "buffered"]}]}
        }
    
    # Check mode (non-discovery)
    res = ctx.run(["vms_system"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "agent plugin 'vms_system' not available or failed",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return {
            "changed": False,
            "msg": "no data from vms_system",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    parts = lines[0].strip().split()
    if len(parts) < 3:
        return {
            "changed": False,
            "msg": "unexpected data format from vms_system",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    direct_ios_str = parts[0]
    buffered_ios_str = parts[1]
    
    def is_float_str(s):
        s_clean = s.strip()
        if s_clean == "":
            return False
        seen_dot = False
        for c in s_clean:
            if c == '.':
                if seen_dot:
                    return False
                seen_dot = True
            elif not c.isdigit():
                return False
        return True
    
    if not is_float_str(direct_ios_str) or not is_float_str(buffered_ios_str):
        return {
            "changed": False,
            "msg": "failed to parse numeric values from vms_system",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    direct_ios = float(direct_ios_str)
    buffered_ios = float(buffered_ios_str)
    
    return {
        "changed": False,
        "msg": "Direct IOs: %f/sec, Buffered IOs: %f/sec" % (direct_ios, buffered_ios),
        "data": {
            "state": "OK",
            "metrics": {"direct": direct_ios, "buffered": buffered_ios},
            "details": ""
        }
    }
