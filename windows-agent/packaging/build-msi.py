#!/usr/bin/env python3
"""Build the agent's MSI: harvest the publish output into a component list, then call `wix build`.

WHY A SCRIPT AND NOT WiX'S OWN HARVESTER. A self-contained .NET agent is about 450 files, including
PowerShell's whole module tree, and every one needs a component with a stable GUID. WiX 4+ can harvest with an
extension (`WixToolset.Heat`), which is one more thing to install and one more thing whose output nobody
reads. This walks the directory and writes the fragment, so the file list in the package is exactly the file
list on disk, and the GUIDs are DERIVED FROM THE PATH — stable across builds, which is what makes an upgrade
replace files instead of installing a second copy beside them.

    ./build-msi.py --publish <dir> --version 0.2.0 --out agentic-mcp-agent.msi

IT NEEDS A WINDOWS BUILD HOST, and that is a measurement rather than an assumption. `wix` runs on Linux and
prints "The WiX Toolset only supports Windows … all behavior after this point is undefined", and it means it:
building this package there failed three ways in a row, each time on the tool's own path validation and each
time inconsistently — File/@Source rejected backslashes (which is the separator WiX exists for),
Component/@Subdirectory rejected 20 of ~40 values while accepting others of identical shape, and
Directory/@Name rejected every name containing a dot ("Microsoft.PowerShell.Host") while accepting "net9.0".
Fighting that further would mean shipping installers from a toolchain that declares its own behaviour
undefined, so the .wxs and this harvester are the deliverable and the build step belongs on Windows:

    dotnet tool install --global wix --version 5.0.2     # v6+ requires accepting the OSMF fee agreement
    wix extension add -g WixToolset.Util.wixext/5.0.2
    python build-msi.py --publish <publish dir> --version 0.2.0 --out agentic-mcp-agent.msi
    .\verify-msi.ps1 -Msi agentic-mcp-agent.msi -ExpectedVersion 0.2.0   # the package is not done until this passes

Until verify-msi.ps1 has passed on a real host, the package is UNVERIFIED — an MSI that compiles can still
install a service that never starts, leave a second copy beside the first on upgrade, or fail to remove
itself, and none of that shows up at build time.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import uuid

#: The namespace the component GUIDs are derived from. A fixed namespace plus the file's relative path gives
#: the same GUID on every build, which is the whole requirement: MSI identifies a component by its GUID, and a
#: GUID that changes per build turns every upgrade into "install the new one, leave the old one behind".
GUID_NAMESPACE = uuid.UUID("3f6c1d92-5a84-4b17-9e2f-8c07d5b3a614")

#: Already in the package by hand (agent.wxs owns the service component and its key file), so the harvest must
#: not add a second component for it — two components claiming one file is an MSI that installs and then
#: cannot uninstall cleanly.
ALREADY_PACKAGED = {"AgenticMcp.Agent.Host.exe"}


def component_guid(relative: str) -> str:
    return str(uuid.uuid5(GUID_NAMESPACE, relative)).upper()


def identifier(relative: str) -> str:
    """A WiX Id from a path: letters, digits, underscore and period only, prefixed so it never starts with a
    digit, and truncated with a hash so two long paths cannot collide after truncation."""
    safe = "".join(c if c.isalnum() or c in "._" else "_" for c in relative)
    if len(safe) <= 60:
        return "f_" + safe
    # The tail is the distinguishing part of a long path, and the hash guarantees uniqueness anyway.
    return "f_" + safe[-52:] + "_" + uuid.uuid5(GUID_NAMESPACE, relative).hex[:6]


def read_file_list(listing: pathlib.Path) -> list[pathlib.Path]:
    r"""Relative paths from a text listing, one per line.

    WHY THIS EXISTS. The build is split across two machines and always was: `wix` only works on Windows
    (measured — off Windows it declares its own behaviour undefined and proved it three ways), and the build
    host has no Python. So harvesting happens where Python is and `wix build` happens where the files are,
    and the only thing that has to travel between them is the file LIST — the harvester never opens a file,
    it only needs paths, because the component GUIDs are derived from the path.

    Producing the listing on the build host:

        Get-ChildItem <publish> -Recurse -File | Resolve-Path -Relative | %{ $_ -replace '^\.\\','' } > files.txt

    Until this option existed, the split was done by hand each time and left no trace — which is how a
    documented build step became one nobody could repeat.
    """
    out: list[pathlib.Path] = []
    for line in listing.read_text().splitlines():
        entry = line.strip().strip('"').replace("\\", "/")
        if entry and entry not in ALREADY_PACKAGED:
            out.append(pathlib.PurePosixPath(entry))  # type: ignore[arg-type]
    return out  # type: ignore[return-value]


def harvest(publish: pathlib.Path, listing: pathlib.Path | None = None) -> str:
    """The <Fragment> with a real Directory tree and one component per file.

    A NESTED <Directory> TREE, not the newer Component/@Subdirectory attribute. Subdirectory is tidier and it
    was tried first: WiX rejected 20 of ~40 values with "is not a relative path" — including paths of exactly
    the same shape as ones it accepted, which is the "behaviour off Windows is undefined" warning showing up as
    an inconsistency rather than an error. The Directory tree is the form WiX has supported since v3 and it
    does not go near that validation.
    """
    files: list[pathlib.Path] = (
        sorted(read_file_list(listing), key=str) if listing is not None
        else [p.relative_to(publish) for p in sorted(publish.rglob("*"))
              if p.is_file() and str(p.relative_to(publish)) not in ALREADY_PACKAGED])

    # THE SATELLITE TRANSLATIONS ARE LEFT OUT, and it is a choice rather than a workaround: 13 locale folders
    # and 9.5 MB of .NET's own localised error messages, in a service whose messages are read by a server and
    # by an AI. English is what the fleet's logs, the operation log and every message in this codebase are
    # written in, and a German .NET exception inside an English record is harder to act on, not easier — the
    # event log's localised level names already cost us a bug. Dropped from the package; the folder build is
    # unaffected, so nothing that wants them loses them.
    locale = re.compile(r"^[a-z]{2}(-[A-Za-z]{2,4})?$")
    skipped = [f for f in files if locale.match(f.parts[0]) and f.parts[0] not in ("ref",)]
    files = [f for f in files if f not in skipped]

    # Every directory that holds a file, and every parent of one, with a stable id per path.
    directories: dict[str, str] = {}

    def directory_id(path: str) -> str:
        if path in ("", "."):
            return "INSTALLFOLDER"
        if path not in directories:
            directories[path] = "d_" + uuid.uuid5(GUID_NAMESPACE, "dir:" + path).hex[:20]
        return directories[path]

    for relative in files:
        parts = list(relative.parts[:-1])
        for depth in range(1, len(parts) + 1):
            directory_id("/".join(parts[:depth]))

    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!-- GENERATED by build-msi.py from the publish output. Do not edit: the next build overwrites it,",
        "     and the point of generating it is that the package's file list cannot drift from the build's. -->",
        '<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">',
        "  <Fragment>",
        '    <DirectoryRef Id="INSTALLFOLDER">',
    ]

    # The tree, depth-first, so a child is always inside its parent element.
    def emit(prefix: str, indent: int) -> None:
        children = sorted({
            path for path in directories
            if path.rsplit("/", 1)[0] == prefix and path != prefix
        } if prefix else {path for path in directories if "/" not in path})
        for child in children:
            name = child.rsplit("/", 1)[-1]
            pad = " " * indent
            lines.append(f'{pad}<Directory Id="{directories[child]}" Name="{name}">')
            emit(child, indent + 2)
            lines.append(f"{pad}</Directory>")

    emit("", 6)
    lines += ["    </DirectoryRef>", '    <ComponentGroup Id="PayloadGroup">']

    for relative in files:
        rel = str(relative)
        parent = "/".join(relative.parts[:-1])
        lines += [
            f'      <Component Id="{identifier(rel)}" Guid="{component_guid(rel)}" '
            f'Directory="{directory_id(parent)}">',
            f'        <File Id="{identifier(rel)}_file" Source="$(var.PublishDir)/{rel}" KeyPath="yes" />',
            "      </Component>",
        ]

    lines += ["    </ComponentGroup>", "  </Fragment>", "</Wix>", ""]
    print(f"harvest: {len(files)} file(s), {len(directories)} directory/ies, "
          f"{len(skipped)} localisation file(s) left out on purpose")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", required=True, type=pathlib.Path,
                        help="the `dotnet publish` output directory (a PATH ON THE BUILD HOST when "
                             "--file-list is used: it goes into the .wxs as PublishDir and is never read here)")
    parser.add_argument("--version", required=True, help="the package version, e.g. 0.2.0")
    parser.add_argument("--out", type=pathlib.Path, help="the .msi to write (not needed with --wxs-only)")
    parser.add_argument("--wix", default="wix", help="the wix executable")
    parser.add_argument("--file-list", type=pathlib.Path,
                        help="harvest from this listing of relative paths instead of walking --publish. For "
                             "the split build: the list comes from the machine that has the files, this runs "
                             "where Python is. See read_file_list.")
    parser.add_argument("--wxs-only", action="store_true",
                        help="write payload.generated.wxs and stop, without calling wix. The other half of "
                             "the split build — `wix build` then runs on the Windows host.")
    args = parser.parse_args()

    publish = args.publish if args.file_list else args.publish.resolve()
    if args.file_list is None and not (publish / "AgenticMcp.Agent.Host.exe").is_file():
        print(f"no AgenticMcp.Agent.Host.exe in {publish} — point --publish at a published agent",
              file=sys.stderr)
        return 2
    if not args.wxs_only and args.out is None:
        print("--out is required unless --wxs-only is given", file=sys.stderr)
        return 2

    here = pathlib.Path(__file__).resolve().parent
    fragment = here / "payload.generated.wxs"
    fragment.write_text(harvest(publish, args.file_list))
    files = (len(read_file_list(args.file_list)) if args.file_list
             else sum(1 for _ in publish.rglob("*") if _.is_file()))
    print(f"harvested {files} file(s) from {'the listing ' + str(args.file_list) if args.file_list else publish}")
    if args.wxs_only:
        # The wxs is the deliverable of this half. Naming the next command means the split does not have to
        # be remembered.
        print(f"wrote {fragment} — now on the Windows build host:\n"
              f"  wix build agent.wxs payload.generated.wxs -arch x64 -ext WixToolset.Util.wixext "
              f"-d PublishDir={publish} -d AgentVersion={args.version} -o agentic-mcp-agent.msi")
        return 0

    command = [
        args.wix, "build",
        str(here / "agent.wxs"), str(fragment),
        "-arch", "x64",
        "-ext", "WixToolset.Util.wixext",
        "-d", f"PublishDir={publish}",
        "-d", f"AgentVersion={args.version}",
        "-o", str(args.out.resolve()),
    ]
    print(" ".join(command))
    result = subprocess.run(command, text=True, capture_output=True)
    print(result.stdout.strip()[-4000:] or "(no output)")
    if result.returncode != 0:
        print(result.stderr.strip()[-4000:], file=sys.stderr)
        return result.returncode

    size = args.out.stat().st_size if args.out.exists() else 0
    print(f"wrote {args.out} ({size / 1_000_000:.1f} MB)")
    # SAID EVERY TIME, not once in a README: an artefact built by a toolchain that declares its own behaviour
    # undefined is unverified until a real host has installed and removed it.
    print("NOTE: if this ran on Linux, wix printed that only Windows is supported. Treat the package as "
          "unverified until packaging/verify-msi.ps1 has installed, upgraded and uninstalled it on a real "
          "Windows host.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
