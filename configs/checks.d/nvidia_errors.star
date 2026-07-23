def main(ctx, params):
    if params.get("_discover"):
        # Try nvidia-smi query for temperature errors
        res = ctx.run(["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"], mutates=False)
        
        # If primary method fails, try alternative
        if res.rc != 0:
            res = ctx.run(["nvidia-smi", "-q", "-d", "TEMPERATURE"], mutates=False)
        
        # Check for errors section
        res_err = ctx.run(["nvidia-smi", "-q", "-d", "ERRORS"], mutates=False)
        if res_err.rc == 0 and ("GPU Error" in res_err.stdout or "GPUErrors" in res_err.stdout):
            return {"changed": False, "msg": "discovered 1 items",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        
        # Fallback: check procfs
        proc_path = "/proc/driver/nvidia/gpus/0/information"
        if ctx.file_exists(proc_path):
            content = ctx.file_read(proc_path)
            for line in content.split("\n"):
                if line.startswith("GPUErrors:"):
                    return {"changed": False, "msg": "discovered 1 items",
                            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    
    # Check mode for NVIDIA GPU Errors
    res_err = ctx.run(["nvidia-smi", "-q", "-d", "ERRORS"], mutates=False)
    
    if res_err.rc != 0:
        # Try procfs fallback
        proc_path = "/proc/driver/nvidia/gpus/0/information"
        if ctx.file_exists(proc_path):
            content = ctx.file_read(proc_path)
            errors = 0
            for line in content.split("\n"):
                if line.startswith("GPUErrors:"):
                    parts = line.split(":", 1)
                    if len(parts) > 1:
                        val = parts[1].strip()
                        if val.isdigit():
                            errors = int(val)
                        break
            state = "CRIT" if errors > 0 else "OK"
            msg = "%d GPU errors" % errors if errors > 0 else "No GPU errors"
            return {"changed": False, "msg": msg,
                    "data": {"state": state, "metrics": {"errors": errors}, "details": ""}}
        return {"changed": False, "msg": "incomplete output from agent",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse nvidia-smi error output
    lines = res_err.stdout.split("\n")
    errors = 0
    for line in lines:
        if line.startswith("GPUErrors:"):
            parts = line.split(":", 1)
            if len(parts) > 1:
                val = parts[1].strip()
                if val.isdigit():
                    errors = int(val)
                break
    
    state = "CRIT" if errors > 0 else "OK"
    msg = "%d GPU errors" % errors if errors > 0 else "No GPU errors"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"errors": errors}, "details": ""}}