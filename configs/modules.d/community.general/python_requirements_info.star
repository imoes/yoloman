def main(ctx, params):
    dependencies = params.get("dependencies", [])
    
    # Get python executable path
    res = ctx.run(["python", "-c", "import sys; print(sys.executable)"])
    if res.rc != 0:
        res = ctx.run(["python3", "-c", "import sys; print(sys.executable)"])
    python_path = res.stdout.strip() if res.rc == 0 else "python"
    
    # Check if pkg_resources is available
    check_pkg = ctx.run(["python", "-c", "try:\n import pkg_resources\n print('yes')\nexcept ImportError:\n print('no')"])
    if check_pkg.rc != 0 or check_pkg.stdout.strip() != "yes":
        # Try with python3
        check_pkg = ctx.run(["python3", "-c", "try:\n import pkg_resources\n print('yes')\nexcept ImportError:\n print('no')"])
        if check_pkg.rc != 0 or check_pkg.stdout.strip() != "yes":
            fail("Could not import pkg_resources library to introspect python environment.")
    
    # Get Python version info
    py_ver_res = ctx.run(["python", "-c", "import sys; print(sys.version.split()[0]); print(sys.version); print(sys.path)"])
    if py_ver_res.rc != 0:
        py_ver_res = ctx.run(["python3", "-c", "import sys; print(sys.version.split()[0]); print(sys.version); print(sys.path)"])
    
    if py_ver_res.rc != 0:
        fail("Failed to get Python version information")
    
    lines = py_ver_res.stdout.strip().splitlines()
    if len(lines) < 3:
        fail("Unexpected Python version info format")
    
    py_version = lines[0]
    py_full_version = lines[1]
    
    # Parse python system path
    path_str = lines[2]
    if path_str.startswith("[") and path_str.endswith("]"):
        path_str = path_str[1:-1]
    if path_str == "":
        py_system_path = []
    else:
        py_system_path = []
        for item in path_str.split(","):
            item = item.strip()
            if item.startswith("'") and item.endswith("'"):
                item = item[1:-1]
            elif item.startswith('"') and item.endswith('"'):
                item = item[1:-1]
            py_system_path.append(item)
    
    # Parse version info into components
    version_parts = py_version.split(".")
    major = 0
    minor = 0
    micro = 0
    if len(version_parts) >= 1 and version_parts[0].isdigit():
        major = int(version_parts[0])
    if len(version_parts) >= 2 and version_parts[1].isdigit():
        minor = int(version_parts[1])
    if len(version_parts) >= 3 and version_parts[2].isdigit():
        micro = int(version_parts[2])
    
    # Initialize results
    not_found = []
    mismatched = {}
    valid = {}
    
    # Process each dependency
    for dep in dependencies:
        pkg = dep
        op = None
        version = None
        
        # Try to find operator
        operators = ["<=", ">=", "==", "<", ">"]
        found_op = None
        for o in operators:
            if o in dep:
                idx = dep.find(o)
                pkg = dep[:idx].strip()
                op = o
                version = dep[idx + len(o):].strip()
                break
        
        # Check if parsing succeeded
        if not pkg or not pkg[0].isalpha():
            fail("Failed to parse version requirement '{0}'. Must be formatted like 'ansible>2.6'".format(dep))
        
        # Get installed version
        get_ver_cmd = ["python", "-c", "try:\n import pkg_resources; print(pkg_resources.get_distribution('{0}').version)\nexcept:\n print('NOT_FOUND')".format(pkg)]
        ver_res = ctx.run(get_ver_cmd)
        
        if ver_res.rc != 0:
            get_ver_cmd = ["python3", "-c", "try:\n import pkg_resources; print(pkg_resources.get_distribution('{0}').version)\nexcept:\n print('NOT_FOUND')".format(pkg)]
            ver_res = ctx.run(get_ver_cmd)
        
        if ver_res.rc != 0 or ver_res.stdout.strip() == "NOT_FOUND":
            not_found.append(pkg)
            continue
        
        installed_version = ver_res.stdout.strip()
        
        # Compare versions if operator specified
        if op == None and version == None:
            valid[pkg] = {"installed": installed_version, "desired": None}
        else:
            # Build comparison command - escape strings properly
            cmd_parts = [
                "from ansible_collections.community.general.plugins.module_utils.version import LooseVersion",
                "import operator",
                "ops = {'<=': operator.le, '>=': operator.ge, '<': operator.lt, '>': operator.gt, '==': operator.eq}",
                "try:",
                " print(ops['{0}'](LooseVersion('{1}'), LooseVersion('{2}')))",
                "except Exception as e:",
                " print('ERROR')"
            ]
            cmd = "\n".join(cmd_parts).format(op, installed_version, version)
            cmp_cmd = ["python", "-c", cmd]
            cmp_res = ctx.run(cmp_cmd)
            
            if cmp_res.rc != 0:
                cmp_cmd = ["python3", "-c", cmd]
                cmp_res = ctx.run(cmp_cmd)
            
            if cmp_res.rc != 0 or cmp_res.stdout.strip() == "ERROR":
                fail("Failed to compare versions for {0}".format(dep))
            
            match = cmp_res.stdout.strip() == "True"
            
            if match:
                valid[pkg] = {"installed": installed_version, "desired": dep}
            else:
                mismatched[pkg] = {"installed": installed_version, "desired": dep}
    
    return {
        "changed": False,
        "msg": "Dependency check completed",
        "data": {
            "python": python_path,
            "python_version": py_full_version,
            "python_version_info": {
                "major": major,
                "minor": minor,
                "micro": micro,
                "releaselevel": "final",
                "serial": 0
            },
            "python_system_path": py_system_path,
            "valid": valid,
            "mismatched": mismatched,
            "not_found": not_found
        }
    }
