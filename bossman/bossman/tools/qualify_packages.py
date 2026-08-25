"""Package qualification pass — qwen only, no Claude.

Per package, in workflow order: Qualify → Codec → Template → Enum → Enrich. The
authoritative source is the package's REAL config, extracted from its DEBIAN
.deb (downloaded via an isolated apt pinned to deb.debian.org, no install), plus
its section-5 man page. That one artifact grounds all stages:
  - Qualify: the .deb actually ships a file under /etc/ (hard signal) OR a
    section-5 man page exists → the package has a config; else skip.
  - Codec:   classify the file format from the real config + man page.
  - Template: PARAMETRIZE the real shipped config (kept verbatim, only site
    values → {{ vars }}) — complete + valid by construction. Man-page
    reconstruction is only the fallback when no .deb config is obtainable.
  - Enum:    mine enums grounded in man page + real config (its comments list
    allowed values) + web; every value must appear verbatim in a source.
  - Enrich:  on a complete dir, rewrite template.j2 to be self-documenting +
    Ansible-safe and emit capabilities.json (the Lego provides/requires contract),
    gated by enrich_gates' five deterministic checks (originals kept unless all
    pass). Runs on the existing 3.219 dirs too — that is why v6 reprocesses all.

Resumable systemd user service: completion recorded per package in
configs/.qualify_pipeline_state.json keyed by PIPELINE_VERSION; --rebuild
wipes the markers. .deb temp trees are extracted under AGENTIC_DEB_TMP
(/data1/agentic-dev-tmp) and cleaned up per package.

    .venv/bin/python scripts/qualify_packages.py [--limit N] [--only pkg1,pkg2] [--check-only] [--rebuild]
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from contextvars import ContextVar
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))          # scripts/ — enrich_gates
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))       # bossman/ — services

from bossman.tools._jsonio import write_catalog  # noqa: E402
from bossman.tools._paths import configs_dir, repo_root  # noqa: E402
import enrich_gates as EG  # noqa: E402
from mine_directive_values import mine_one  # noqa: E402 — the per-directive value miner, reused as a stage
from bossman.services.chat_client import ChatClient, ChatClientError  # noqa: E402
from bossman.services.websearch import SearxngClient  # noqa: E402

QWEN79B = (os.environ.get("YOLOMAN_LLM_BASE", "") + "/qwen79b", "qwen3next-79b")
LAGUNA = (os.environ.get("YOLOMAN_LLM_BASE", "") + "/laguna", "laguna")
# Qwen3.6-35B: the enrich pilot winner (10/10, ~73s/template) — the default for the v6 enrich pass.
QWEN35B = (os.environ.get("YOLOMAN_LLM_BASE", "") + "/qwen35b", "Qwen3.6-35B-A3B-UD-Q4_K_XL")
MODELS = {"qwen79b": QWEN79B, "laguna": LAGUNA, "qwen35b": QWEN35B}

# qwen79b is a reasoning model. Without this it spends the budget thinking: one package decoded 26 180
# tokens at ~29 t/s, which is about 15 minutes, tripped the 900 s client timeout below, and surfaced as
# an nginx 504 with the server logging `stop: cancel task`. The pipeline then burned its 7 retries on
# requests that were each going to take a quarter of an hour.
#
# Deliberately NOT a token cap: capping a reasoning model makes it think until the cap and return
# nothing usable (finish_reason=length). Every other batch script here does the same thing.
_NO_THINK = {"chat_template_kwargs": {"enable_thinking": False}}
SEARXNG = os.environ.get("YOLOMAN_SEARX_BASE", "")

# Hand-authored templates the batch must not regenerate (maintained + verified
# by hand; the LLM would clobber them). The web-server vhost/config templates
# drive the Management snapins.
_CURATED = frozenset({"nginx-vhost", "apache-vhost", "caddy", "haproxy", "traefik",
                      "apt-proxy", "suse-proxy"})
# FOUND, not counted: parents[2] is the repo root in the container and one level short in a checkout,
# which is why a patched duplicate of this file used to live in bossman/scripts/. See _paths.
ROOT = repo_root(__file__)
# The configs/ root holds every artifact + state file. Default to the repo's
# configs/ (host batch); env-override with AGENTIC_CONFIGS_DIR so Bossman can run
# this in-container against the RW bind-mounted configs (the on-demand qualify
# endpoint sets it). One knob moves templates, codecs, directives, catalog AND
# the .state files together, so an in-container run shares the host's state.
_CONFIGS = configs_dir(__file__)
TEMPLATES_DIR = _CONFIGS / "config_templates"
CATALOG = _CONFIGS / "package_catalog.json"
UNIVERSE = _CONFIGS / "package_universe_real.json"
STATE = _CONFIGS / ".schema_enum_state.json"
CODECS = _CONFIGS / "config_codecs.json"
# ADMX-style per-directive value catalog (config_directives.json). Mined as a
# stage of this pipeline (from the same internet-sourced man page + web docs the
# other stages use), but versioned INDEPENDENTLY of the codec/template pipeline
# (see DIRECTIVES_VERSION) so it can be back-filled without recomputing those.
DIRECTIVES = _CONFIGS / "config_directives.json"
DIRECTIVES_STATE = _CONFIGS / ".qualify_directives_state.json"

# LLM-failure sink. The per-step helpers swallow ChatClientError for resilience,
# but when the LLM endpoint is DOWN (crash / all connection attempts failed) a
# package must be recorded as FAILED and RETRIED next pass — NOT silently marked
# "ok", which the pipeline-state would then skip forever. process_package resets
# this at the start of each package; a non-empty list ⇒ status "failed".
#
# A ContextVar, not a module global: with --concurrency the outer loop runs each
# package in its own asyncio Task (which copies the context at creation), so
# process_package's set([]) isolates that package's failures — a plain shared list
# would cross-attribute failures between packages running at the same time.
_LLM_FAILURES: ContextVar[list[str]] = ContextVar("llm_failures", default=[])


def _note_llm_failure(where: str, exc: object) -> None:
    _LLM_FAILURES.get().append(f"{where}: {str(exc)[:120]}")

# ── JSON schema for template generation ──────────────────────────────────────

_TEMPLATE_SCHEMA = {
    "type": "object",
    "properties": {
        "template": {"type": "string"},
        "values_schema": {
            "type": "object",
            "additionalProperties": {
                "type": "object",
                "properties": {
                    "type": {"type": "string"},
                    # Constrain default to non-object scalars/arrays so the
                    # grammar cannot emit a {"value": X, …} wrapper (models differ
                    # on this when left unconstrained). Flatten stays as a
                    # belt-and-suspenders for legacy on-disk schemas.
                    "default": {"type": ["string", "number", "boolean", "array", "null"]},
                    "description": {"type": "string"},
                },
                "required": ["type"],
            },
        },
        "sample_values": {"type": "object"},
    },
    "required": ["template", "values_schema", "sample_values"],
}

_TEMPLATE_SYSTEM = (
    "You produce a reusable Class-B configuration template for a Linux service using the gonja "
    "(Go) Jinja2 engine — ONLY {{ var }}, {% for x in list %}…{% endfor %}, {% if cond %}…{% endif %}, "
    "and standard filters like default/join/indent. NO Python methods (.split, .replace), NO "
    "Django/Go-template extensions, NO custom filters. Given a package/service name, return:\n"
    "- `template`: a canonical, production-sane Jinja2 template. Parametrize ONLY site-specific "
    "values; one-line comment above every directive. Every variable used MUST appear in values_schema.\n"
    "- `values_schema`: var -> {type, default, description}. `type` is EXACTLY one of "
    "string|number|bool|list (use `bool`, not `boolean`). `default` MUST be a BARE scalar "
    "(string/number/bool) or array — NEVER a nested object; e.g. \"default\": 8080, never "
    "{\"value\": 8080, \"description\": …}. For a list-of-objects, add `items` as a FLAT map "
    "field-name -> {type, default, description} (NOT {type:object, properties:{…}}).\n"
    "- `sample_values`: concrete values matching values_schema that render a valid, representative "
    "config when applied to template.\n"
    "Base every variable on a real documented setting; invent nothing."
)

# ── JSON schema for enum mining ───────────────────────────────────────────────

_ENUM_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "enums": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "field": {"type": "string"},
                    "values": {"type": "array", "items": {"type": "string"}},
                    "default": {"type": "string"},
                },
                "required": ["field", "values"],
            },
        }
    },
    "required": ["enums"],
}

_ENUM_SYSTEM = (
    "You are a Linux system-administration expert. You are given a config-file schema (field "
    "names, types, defaults, descriptions) for a specific service, plus excerpts from its "
    "official documentation. Your task: identify which string fields are ENUMERATED and return "
    "ALL valid values.\n\n"
    "Rules:\n"
    "- Enumerate every field where the software accepts a KNOWN, finite set of values — "
    "log levels (debug/info/warn/error/crit), modes, protocols, drivers, algorithms, "
    "backends, authentication methods, compression types, hash algorithms, TLS versions, "
    "scheduler policies, etc.\n"
    "- Be COMPREHENSIVE: return ALL documented values, not just the most common 2-3. "
    "If a driver supports 20 backends, list all 20.\n"
    "- Skip only genuinely free-text fields: file paths, hostnames, IP addresses, "
    "usernames, passwords, numeric sizes, arbitrary human-readable strings.\n"
    "- For each enum, return the most sensible default value.\n"
    "- Use your expert knowledge when docs are unavailable — prefer a complete list "
    "over an empty result."
)

# Sections that virtually never ship a config file in /etc/
_NO_CONFIG_SECTIONS = frozenset({
    "libs", "libdevel", "oldlibs",
    "python", "perl", "ruby", "php", "javascript", "java",
    "fonts", "games",
    "science", "math", "tex",
    "doc", "debug", "introspection",
})

# ── helpers ───────────────────────────────────────────────────────────────────

def _hash(schema: dict) -> str:
    return hashlib.sha256(json.dumps(schema, sort_keys=True).encode()).hexdigest()[:16]


def _write_json(path: Path, data, *, sort: bool) -> None:
    """Write a shared catalog — the one writer, in _jsonio.

    Kept as a name here because a dozen call sites use it, but the FORMAT and the atomicity live in one
    place now: ~17 writers touch config_codecs.json and config_directives.json and they disagreed on indent
    AND on ensure_ascii, so the two groups took turns rewriting 200 000 lines and a real one-key change was
    indistinguishable from a reformat. See _jsonio for the measurement.
    """
    write_catalog(path, data, sort=sort)


class TrackedDict(dict):
    """A dict that remembers which keys THIS process changed.

    The pass used to load config_codecs.json, mutate it in memory for minutes, then write the whole
    dict back. Anything another writer put in the file meanwhile was silently gone — measured: a
    hand-curated `dirvalue` classification for /etc/pure-ftpd/conf came back as `keyvalue` after a
    concurrent pass flushed. That is a lost update against every other writer (a second pass, the
    on-demand qualify endpoint, an operator editing the file), not just against me.

    Tracking the keys is what makes a merging flush possible: on write we re-read the file and apply
    ONLY what this process actually touched, so a concurrent addition survives.

    It is a dict subclass rather than a set of hand-maintained bookkeeping calls on purpose. There
    are six mutation sites today; the seventh would have forgotten to record, and the failure mode
    is silent data loss discovered days later.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.touched: set = set()
        self.removed: set = set()

    def __setitem__(self, key, value):
        self.touched.add(key)
        self.removed.discard(key)
        super().__setitem__(key, value)

    def __delitem__(self, key):
        self.removed.add(key)
        self.touched.discard(key)
        super().__delitem__(key)

    def update(self, *args, **kwargs):  # noqa: D102 — same contract as dict.update
        other = dict(*args, **kwargs)
        self.touched.update(other)
        self.removed.difference_update(other)
        super().update(other)

    def pop(self, key, *default):  # noqa: D102
        if key in self:
            self.removed.add(key)
            self.touched.discard(key)
        return super().pop(key, *default)

    def merged_with_disk(self, path: Path) -> dict:
        """The file's CURRENT content with this process's changes applied on top.

        Not `disk | self`: that would reinstate every key this process merely read, undoing another
        writer's edit to an untouched entry. Only `touched` and `removed` carry intent.
        """
        disk = _load(path, {})
        if not isinstance(disk, dict):
            disk = {}
        for key in self.removed:
            disk.pop(key, None)
        for key in self.touched:
            if key in self:
                disk[key] = self[key]
        return disk


def _load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def _man_candidates(name: str, *extra: str) -> list[str]:
    """Section-5 man-page name variants to try. The template dir is often the
    daemon name (sshd) while the config man page is "<name>_config" or
    "<name>.conf" (sshd_config, dnsmasq.conf). `extra` adds caller-known
    candidates (e.g. the config file's basename)."""
    seen: set[str] = set()
    cands: list[str] = []
    for n in (name, *extra):
        if not n:
            continue
        base = n.rsplit(".", 1)[0]
        for c in (n, base, f"{base}_config", f"{base}.conf", f"{base}.cfg"):
            if c and c not in seen:
                seen.add(c)
                cands.append(c)
    return cands


def _man_page(name: str, *extra: str) -> str | None:
    """Locally installed section-5 man page (fast path for installed pkgs).

    Best-effort: where `man` isn't installed (e.g. the on-demand qualify running
    in the Bossman container — we deliberately do NOT install man-db, since it
    wouldn't carry every package's pages anyway), this returns None so the caller
    falls back to the two public mirrors (_online_manpage: man7.org /
    manpages.debian.org). Packages that ship their own page are still covered via
    the .deb extraction path."""
    env = {**os.environ, "MANWIDTH": "100", "MANPAGER": "cat", "PAGER": "cat"}
    for cand in _man_candidates(name, *extra):
        try:
            if subprocess.run(["man", "-w", "5", cand], capture_output=True).returncode == 0:
                txt = subprocess.run(["man", "5", cand], capture_output=True, text=True, env=env).stdout
            else:
                continue
        except FileNotFoundError:
            return None  # no `man` binary here → use the online mirrors
        if txt.strip():
            # Return the WHOLE page — options are alphabetical and the ones
            # we need (LogLevel is ~char 39k in sshd_config) live well past
            # any small cap. The 200k ceiling only guards a pathological page.
            return txt[:200000]
    return None


#: Below this a "man page" is a table of contents. Measured on 15 packages: 7 fetches returned 1.5-4.7 kB of
#: site chrome that the previous 800-character floor accepted, including nginx and smb.conf whose real pages
#: run to hundreds of kilobytes.
_MAN_MIN_CHARS = 6000
#: NO CHROME TEST. Tried, and it rejected redis (43 kB), dnsmasq (138 kB) and ntp (60 kB): manpages.debian.org
#: wraps EVERY page in the same navigation, so its presence says nothing about whether the content is there.
#: Length alone separates them — the stubs measured 1.5-4.7 kB and the real pages 12-165 kB.


async def _online_manpage(searx: SearxngClient, name: str, *extra: str) -> str | None:
    """Fetch a section-5 man page from the public mirrors when it isn't
    installed locally (most universe packages aren't). man7.org has a
    predictable URL and 404s cleanly; manpages.debian.org covers every Debian
    package. First solid hit wins; the grounding filter tolerates a wrong
    fetch (its values simply won't match)."""
    for c in _man_candidates(name, *extra):
        for url in (f"https://man7.org/linux/man-pages/man5/{c}.5.html",
                    f"https://manpages.debian.org/{c}"):
            try:
                txt = await searx.fetch(url, max_chars=200000)
            except Exception:  # noqa: BLE001 — 404/network → next candidate
                continue
            head = txt[:400].lower()
            if not txt or "no such" in head or "not found" in head:
                continue
            # A NAVIGATION STUB IS NOT A MAN PAGE, and the 800-character floor let seven of fifteen sampled
            # fetches through as one. Measured: manpages.debian.org answers /ddclient with a 1548-character
            # index page (ddclient(8) links and site chrome), /nginx with 4271 and /smb with 4065 — while the
            # real smb.conf(5) is hundreds of kilobytes. The grounding gate then does its job perfectly and
            # rejects every correct value the model proposed, because the chrome does not contain them: not a
            # hallucination, a silent UNDER-grounding that looks like the package having no documented values.
            #
            # A section-5 page that documents a config file's directives is not 2 kB. Below the floor the
            # candidate is skipped, so the caller falls back to the shipped config and the web docs — both
            # better witnesses than a table of contents.
            if len(txt) < _MAN_MIN_CHARS:
                continue
            return txt
    return None


DEB_TMP = Path(os.environ.get("AGENTIC_DEB_TMP", "/data1/agentic-dev-tmp"))
DEB_APT = DEB_TMP / "apt"
DEB_SUITE = os.environ.get("AGENTIC_DEB_SUITE", "trixie")  # Debian 13 (current stable)
_apt_ready: bool | None = None


def _apt_opts() -> list[str]:
    """apt -o options pinning an ISOLATED apt rooted under DEB_APT, so we pull
    from the Debian archive and never touch the host's (Ubuntu) apt config."""
    return [
        "-o", f"Dir::Etc::sourcelist={DEB_APT}/etc/apt/sources.list",
        "-o", "Dir::Etc::sourceparts=/dev/null",
        "-o", f"Dir::State::lists={DEB_APT}/lists",
        "-o", f"Dir::Cache={DEB_APT}/cache",
        "-o", f"Dir::Etc::trusted={DEB_APT}/etc/apt/trusted.gpg",
        "-o", f"Dir::Etc::trustedparts={DEB_APT}/etc/apt/trusted.gpg.d",
        "-o", "Acquire::AllowInsecureRepositories=true",
        "-o", "APT::Get::AllowUnauthenticated=true",
    ]


def _ensure_debian_apt() -> bool:
    """Set up (once) an isolated apt pointing at the DEBIAN archive — the user
    wants Debian packages, not the host's Ubuntu ones — and fetch its index."""
    global _apt_ready
    if _apt_ready is not None:
        return _apt_ready
    try:
        for d in ("etc/apt/apt.conf.d", "etc/apt/preferences.d", "etc/apt/trusted.gpg.d",
                  "lists/partial", "cache/archives/partial"):
            (DEB_APT / d).mkdir(parents=True, exist_ok=True)
        (DEB_APT / "etc/apt/sources.list").write_text(
            f"deb [trusted=yes] https://deb.debian.org/debian {DEB_SUITE} main contrib\n")
        subprocess.run(["apt-get", *_apt_opts(), "update"],
                       capture_output=True, env=os.environ.copy(), timeout=300)
        _apt_ready = (DEB_APT / "lists").is_dir() and any((DEB_APT / "lists").glob("*Packages*"))
    except (OSError, subprocess.SubprocessError):
        _apt_ready = False
    return _apt_ready


#: Directories under /etc that hold a file named after the package which is NOT its config:
#: the PAM stack, the SysV init script, the sysconfig/defaults snippet, the logrotate and cron
#: fragments. A weak, name-only match must never land here.
_NOT_A_CONFIG_DIR = re.compile(
    r"^/etc/(pam\.d|init\.d|default|sysconfig|logrotate\.d|cron\.[a-z]+|rc\d?\.d|apparmor\.d|ufw/applications\.d)/"
)


def _catalog_packages() -> list[str]:
    """Every Debian package name the role catalog offers, so the worklist covers what the product
    actually promises. Read defensively: a missing or malformed catalog must not stop a pass."""
    try:
        cat = json.loads((_CONFIGS / "package_catalog.json").read_text())
    except (OSError, ValueError):
        return []
    out: list[str] = []
    for entry in cat.values() if isinstance(cat, dict) else []:
        fam = ((entry.get("families") or {}).get("debian") or {}) if isinstance(entry, dict) else {}
        for pkg in fam.get("packages") or []:
            if isinstance(pkg, str) and pkg and pkg not in out:
                out.append(pkg)
    return out


def _pick_primary_config(
    conffiles: list[str], cfg_base: str, name: str, cfg_path: str = "",
) -> str | None:
    """Choose the package's PRIMARY config from its declared conffiles, BEST match first.

    This used to take the first conffile whose basename was in
    `{cfg_base, name.conf, name.cfg, name}` — and the bare package name is the trap. openssh-server
    ships BOTH /etc/pam.d/sshd and /etc/ssh/sshd_config; "sshd" matches the PAM file, which sorts
    first, so the generated "template" for sshd_config WAS /etc/pam.d/sshd. Same for
    nfs-kernel-server and samba, whose init scripts share the package name. Measured effect: 7 of
    90 catalog roles carried a template that configures a different file than its own schema
    describes, and the Configure step renders whole-file to config_path — applying the sshd one
    replaces sshd_config with a PAM stack and locks you out.

    So: rank instead of first-match, and take the FULL catalog path (`cfg_path`) as the strongest
    signal. It was available at the call site all along and thrown away one line before use.
    """
    if not conffiles:
        return None

    def rank(c: str) -> tuple[int, int]:
        base = c.rsplit("/", 1)[-1]
        fragment = bool(re.search(r"/(conf|mods|sites)-available/|\.d/", c))
        if cfg_path and c == cfg_path:
            tier = 0                                    # the catalog says exactly this file
        elif cfg_base and base == cfg_base:
            tier = 1                                    # right name, some other directory
        elif base in (f"{name}.conf", f"{name}.cfg"):
            tier = 2                                    # conventional name, unambiguous suffix
        elif base == name and not _NOT_A_CONFIG_DIR.match(c):
            tier = 3                                    # bare name, but not the PAM/init trap
        else:
            tier = 5 if fragment else 4                 # fall back to a real file before a fragment
        return (tier, c.count("/"))                     # shallowest wins inside a tier

    return min(conffiles, key=rank)


def _deb_config(pkg: str, cfg_base: str, name: str, cfg_path: str = "") -> tuple[str | None, bool, str | None]:
    """Download the DEBIAN .deb (no install), extract it, and return
    (primary_config_text, ships_etc_config, real_config_path). `ships_etc_config`
    is the HARD has-config signal — the package actually ships a file under
    /etc/ — replacing the qwen guess. Cleans up the temp tree afterwards."""
    if not pkg or not _ensure_debian_apt():
        return None, False, None
    work = Path(tempfile.mkdtemp(dir=str(DEB_TMP)))
    try:
        subprocess.run(["apt-get", *_apt_opts(), "download", pkg], cwd=str(work),
                       capture_output=True, env=os.environ.copy(), timeout=180)
        debs = list(work.glob("*.deb"))
        if not debs:
            return None, False, None
        root, ctrl = work / "root", work / "DEBIAN"
        subprocess.run(["dpkg-deb", "-x", str(debs[0]), str(root)], capture_output=True, timeout=60)
        subprocess.run(["dpkg-deb", "-e", str(debs[0]), str(ctrl)], capture_output=True, timeout=60)
        etc = root / "etc"
        ships_etc = etc.is_dir() and any(p.is_file() for p in etc.rglob("*"))
        conffiles: list[str] = []
        cf = ctrl / "conffiles"
        if cf.is_file():
            conffiles = [ln.strip() for ln in cf.read_text().splitlines()
                         if ln.strip().startswith("/etc/")]
        # The candidates are the DECLARED conffiles — but a package may install a config under
        # /etc without declaring it one (libvirt-daemon ships no conffile for
        # /etc/libvirt/libvirtd.conf, though the file is right there in the extracted tree). So if
        # the catalog names a path and the package really ships it, that file IS the answer and no
        # ranking is needed: `ships_etc` is already computed from the tree, so the tree is the
        # better-informed source and it was simply not being consulted for the candidate list.
        if cfg_path and (root / cfg_path.lstrip("/")).is_file() and cfg_path not in conffiles:
            conffiles = [*conffiles, cfg_path]
        primary = _pick_primary_config(conffiles, cfg_base, name, cfg_path)
        text = None
        if primary:
            p = root / primary.lstrip("/")
            if p.is_file():
                text = p.read_text(errors="replace")[:60000]
        return text, ships_etc, primary
    except (OSError, subprocess.SubprocessError):
        return None, False, None
    finally:
        shutil.rmtree(work, ignore_errors=True)


_SKIP_MARKER = _CONFIGS / ".qualify_no_config.json"


def _load_skip_set() -> set[str]:
    return set(_load(_SKIP_MARKER, []))


def _save_skip_set(s: set[str]) -> None:
    _write_json(_SKIP_MARKER, sorted(s), sort=False)


# ── codec classification (stage 2) ──────────────────────────────────────────────

_CODEC_SCHEMA = {
    "type": "object",
    "properties": {
        "codec": {"type": "string", "enum": ["keyvalue", "ini", "json", "yaml", "xml", "toml", "none"]},
        "separator": {"type": "string"},
        "comment": {"type": "string"},
        "sections": {"type": "boolean"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "notes": {"type": "string"},
    },
    "required": ["codec", "confidence"],
}

_CODEC_SYSTEM = (
    "You are given a Linux config file's man page (and maybe a sample). Classify how the file is "
    "structured so a generic codec can parse+serialize it:\n"
    "- codec: keyvalue (KEY<sep>VALUE lines), ini (sections of key=value), json, yaml, xml, toml, "
    "or none (free-form/custom grammar like nginx/apache/bind/sudoers — no generic codec fits).\n"
    "- separator: for keyvalue this is REQUIRED and non-empty — the exact key/value separator, "
    'one of " " (space), "=", or ":".\n'
    '- comment: the comment marker ("#", ";", "//").\n'
    "- sections: true if the file is organized into [sections] (ini-style).\n"
    "- confidence: high/medium/low. Judge STRICTLY from the man page's documented syntax. "
    "If the man page does not clearly document the format, say low.\n"
    "Return only the classification JSON. Do NOT guess a structured codec for a free-form "
    "grammar — when in doubt, 'none'."
)


def _config_path(name: str, entry: dict, man_text: str | None, codecs: dict | None = None) -> str:
    """Derive the /etc config-file path used to key the codec registry.
    Priority: catalog/seed config_path → an EXISTING codec entry whose file
    basename matches (so we update the canonical /etc/<pkg>/<file> entry
    instead of writing a duplicate at /etc/<file>) → first /etc path named in
    the man page → best-effort /etc/<name>."""
    fam = (entry.get("families") or {}).get("debian") or {}
    cfg = fam.get("config_path", "")
    if cfg:
        return cfg
    want = name.rsplit("/", 1)[-1]
    if codecs:
        for p in codecs:
            if p.rsplit("/", 1)[-1] == want:
                return p
    if man_text:
        m = re.search(r"/etc/[\w./-]+", man_text)
        if m:
            return m.group(0).rstrip(".,;)")
    return f"/etc/{name}"


async def _classify_codec(man_text: str, sample: str, qwen: ChatClient) -> dict | None:
    """Classify the config-file format from its man page (+ optional sample).
    Grounded: no man page → no classification (return None), never guess."""
    if not man_text:
        return None
    user = (
        (f"=== sample ===\n{sample[:4000]}\n\n" if sample else "")
        + f"=== man page (section 5) ===\n{man_text[:60000]}"
    )
    try:
        cls = await qwen.complete_json(
            [{"role": "system", "content": _CODEC_SYSTEM}, {"role": "user", "content": user}],
            _CODEC_SCHEMA, "codec_classification",
            extra_body=_NO_THINK,
        )
    except ChatClientError as exc:
        _note_llm_failure("codec classification", exc)
        return None
    return cls


# ── qualification checks ──────────────────────────────────────────────────────

def _check(tdir: Path) -> dict[str, bool]:
    has_template = (tdir / "template.j2").exists()
    has_schema = (tdir / "schema.json").exists()
    has_sample = (tdir / "sample.json").exists()
    has_enum = False
    if has_schema:
        schema = _load(tdir / "schema.json", {})
        props = schema.get("properties", schema)  # flat or wrapped
        has_enum = any(
            isinstance(v, dict) and "enum" in v
            for v in props.values()
        )
    return {
        "template": has_template,
        "schema": has_schema,
        "sample": has_sample,
        "enum": has_enum,
    }


# ── shared source resolution ────────────────────────────────────────────────────

async def _resolve_man(searx: SearxngClient, name: str, cfg_base: str = "") -> str | None:
    """The one man-page fetch per package: local `man` first (installed pkgs),
    then the public mirrors (man7.org / manpages.debian.org). Passed into every
    downstream stage so a package's man page is fetched exactly once."""
    return _man_page(name, cfg_base) or await _online_manpage(searx, name, cfg_base)


# Skip the SearXNG METASEARCH (QUALIFY_NO_SEARXNG) and ground only on the man
# page — local, then the two public mirrors (man7.org / manpages.debian.org) —
# plus the shipped .deb config. Used by the on-demand qualify endpoint, where the
# SearXNG instance may be unreachable; the two direct URLs (fetched over plain
# HTTP, not via SearXNG) are the doc fallback "for a while".
_NO_SEARXNG = os.environ.get("QUALIFY_NO_SEARXNG", "").strip().lower() in ("1", "true", "yes")


async def _web_docs(searx: SearxngClient, label: str, name: str, cfg_base: str) -> str:
    """The one web-doc fetch per package: a short, clean config-doc query
    (config basename is the strongest signal), top hits concatenated. Empty
    string on any failure — callers treat missing sources as 'cannot ground'."""
    if _NO_SEARXNG:
        return ""  # metasearch disabled → ground on man (two URLs) + .deb only
    query = f"{label} {cfg_base or name} configuration options directives allowed values documentation"
    try:
        hits = await searx.search(query, limit=8)
        hits.sort(key=lambda h: 0 if any(
            s in h.url.lower()
            for s in ("man", "docs.", "/doc", "documentation", "wiki", "readthedocs",
                      name.lower(), (cfg_base or "\x00").lower())
        ) else 1)
        parts = []
        for h in hits[:3]:
            try:
                parts.append(await searx.fetch(h.url, max_chars=12000))
            except Exception:  # noqa: BLE001
                continue
        return "\n\n".join(parts)[:32000]
    except Exception:  # noqa: BLE001
        return ""


# ── generators ────────────────────────────────────────────────────────────────

def _flatten_schema_defaults(schema: dict) -> dict:
    """Unwrap `{"value": X, "description": …}` field defaults to a bare X. The
    model sometimes emits the wrapped form despite the prompt; ParamForm + the
    snapins expect a bare scalar `default`, so normalize deterministically before
    writing schema.json. Recurses into list `items`."""
    if not isinstance(schema, dict):
        return schema
    for spec in schema.values():
        if not isinstance(spec, dict):
            continue
        d = spec.get("default")
        if isinstance(d, dict) and "value" in d:
            spec["default"] = d["value"]
        if isinstance(spec.get("items"), dict):
            _flatten_schema_defaults(spec["items"])
    return schema


def _record_target(name: str, path: str, from_deb: bool) -> None:
    """Write down WHICH FILE this template renders — configs/config_templates/<name>/meta.json.

    The pipeline has always known this and always thrown it away. `_deb_config` extracts the package and
    returns the primary conffile it found; `path` right below it is that path (or the derived fallback).
    Nothing recorded it, so the server had to re-derive it from the directory NAME — and a directory is
    named after the PACKAGE while the editor resolves by FILE. Measured consequence: 2786 of 5460
    template dirs were reachable by nobody, 2071 of them purely because no config file's basename
    matched their name.

    `witness: "deb"` when the path came out of the extracted .deb — the strongest evidence there is,
    since the file was read from the package itself. Otherwise "derived", i.e. the man-page/codec
    fallback: still recorded, but the difference is not hidden.

    Kept out of schema.json on purpose: that file describes the template's FIELDS. Mixing "what file is
    this" into "what are its settings" is how one file starts meaning two things.
    """
    if not path or not path.startswith("/") or path.endswith("/") or "*" in path:
        return
    try:
        (TEMPLATES_DIR / name / "meta.json").write_text(
            json.dumps({"target_path": path, "source": "qualify",
                        "witness": "deb" if from_deb else "derived"}, indent=2) + "\n")
    except OSError:
        pass


async def _generate_template(name: str, man_text: str | None, web_text: str, qwen: ChatClient) -> bool:
    """Generate template.j2, schema.json, sample.json from PRE-FETCHED sources.
    Gate: refuse to generate from pure model knowledge — without a man page or
    substantial web doc the result is a hallucination (a2jmidid got a systemd
    unit, 0install got invented keys), so skip instead."""
    if not man_text and len(web_text) < 400:
        print(f"  {name}: no config source — template skipped", flush=True)
        return False
    tdir = TEMPLATES_DIR / name
    user = (
        f"Package/service: {name}\n\n"
        + (f"Man page (section 5):\n{man_text}\n\n" if man_text else "")
        + (f"Official documentation (web):\n{web_text}\n\n" if web_text else "")
        + "Produce the Jinja2 template, values_schema, and sample_values as JSON. "
        + "Base it STRICTLY on the documented directives above — every variable must "
        + "correspond to a real documented setting. Do not invent settings, and do not "
        + "emit a systemd unit or any file that is not this package's config file."
    )
    try:
        out = await qwen.complete_json(
            [{"role": "system", "content": _TEMPLATE_SYSTEM}, {"role": "user", "content": user}],
            _TEMPLATE_SCHEMA, "qualify_template", max_tokens=None,
            extra_body=_NO_THINK,
        )
    except ChatClientError as exc:
        _note_llm_failure(f"{name}: template gen", exc)
        print(f"  {name}: template gen failed: {exc}", flush=True)
        return False

    tdir.mkdir(parents=True, exist_ok=True)
    (tdir / "template.j2").write_text(out["template"])
    (tdir / "schema.json").write_text(json.dumps(_flatten_schema_defaults(out.get("values_schema", {})), indent=2) + "\n")
    (tdir / "sample.json").write_text(json.dumps(out.get("sample_values", {}), indent=2) + "\n")
    print(f"  {name}: generated template+schema+sample", flush=True)
    return True


_PARAM_SYSTEM = (
    "You are given the REAL, complete default config file a Debian package ships — the "
    "authoritative, working configuration. Turn it into a reusable template by "
    "PARAMETRIZING it, and NOTHING else:\n"
    "- Replace ONLY site-specific literal values an admin would change (ports, hostnames, "
    "domains, emails, document roots / paths, sizes, worker counts) with {{ variable }} "
    "placeholders.\n"
    "- Keep EVERYTHING ELSE BYTE-FOR-BYTE VERBATIM: every Include/IncludeOptional, module "
    "load, [section], comment, block (<Directory>, <VirtualHost>…), ${ENVVAR}, and directive "
    "must stay exactly as in the real file, in the same order. Do NOT add, remove, reorder, "
    "or 'improve' anything. The rendered template with sample_values must reproduce a valid "
    "config that the package's own validator accepts.\n"
    "- NEVER replace an Include/IncludeOptional line (or any directive) with a loop, filter, "
    "or {{ ... | ... }} expression. Includes like 'IncludeOptional sites-enabled/*.conf' MUST "
    "stay verbatim. Only substitute a plain scalar value with a simple {{ variable }}. Use no "
    "Jinja beyond {{ variable }} — no filters, no map/join, no for-loops.\n"
    "- values_schema: var -> {type: string|number|bool|list, default, description}. Reuse the "
    "provided existing variable names where they map to the same setting.\n"
    "- sample_values: the shipped default values, so rendering reproduces the real file."
)

_PARAM_SCHEMA = _TEMPLATE_SCHEMA  # same {template, values_schema, sample_values} shape


async def _parametrize_config(
    name: str, real_config: str, existing_schema: dict, qwen: ChatClient,
) -> bool:
    """Build template/schema/sample by PARAMETRIZING the real shipped config
    (kept verbatim except site-specific values). Guarantees a complete, valid
    config — unlike man-page reconstruction."""
    tdir = TEMPLATES_DIR / name
    user = (
        f"Package/service: {name}\n\n"
        + (f"Existing values_schema (reuse these variable names where they fit):\n"
           f"{json.dumps(existing_schema, indent=2)[:4000]}\n\n" if existing_schema else "")
        + f"=== REAL default config file (parametrize this, keep it verbatim) ===\n{real_config}\n\n"
        + "Return the parametrized template, values_schema, and sample_values as JSON."
    )
    try:
        out = await qwen.complete_json(
            [{"role": "system", "content": _PARAM_SYSTEM}, {"role": "user", "content": user}],
            _PARAM_SCHEMA, "parametrize_config", max_tokens=None,
            extra_body=_NO_THINK,
        )
    except ChatClientError as exc:
        _note_llm_failure(f"{name}: parametrize", exc)
        print(f"  {name}: parametrize failed: {exc}", flush=True)
        return False
    tpl = out.get("template", "")
    if not tpl.strip():
        return False
    tdir.mkdir(parents=True, exist_ok=True)
    (tdir / "template.j2").write_text(tpl)
    (tdir / "schema.json").write_text(json.dumps(_flatten_schema_defaults(out.get("values_schema", {})), indent=2) + "\n")
    (tdir / "sample.json").write_text(json.dumps(out.get("sample_values", {}), indent=2) + "\n")
    print(f"  {name}: template from shipped config ({len(real_config)} bytes)", flush=True)
    return True


_REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "changed": {"type": "boolean"},
        "template": {"type": "string"},
        "values_schema": {
            "type": "object",
            "additionalProperties": {
                "type": "object",
                "properties": {
                    "type": {"type": "string"},
                    # Constrain default to non-object scalars/arrays so the
                    # grammar cannot emit a {"value": X, …} wrapper (models differ
                    # on this when left unconstrained). Flatten stays as a
                    # belt-and-suspenders for legacy on-disk schemas.
                    "default": {"type": ["string", "number", "boolean", "array", "null"]},
                    "description": {"type": "string"},
                },
                "required": ["type"],
            },
        },
        "removed": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["changed"],
}

_REVIEW_SYSTEM = (
    "You review an EXISTING config template + its values_schema against the authoritative "
    "man page / documentation, and CORRECT factual errors only:\n"
    "- Remove any variable/directive that is NOT documented in the sources (hallucinated — "
    "e.g. invented keys, or a systemd unit masquerading as a config).\n"
    "- Fix a wrong default or type to match the documented value.\n"
    "- Add a clearly-documented, important directive only if it is genuinely missing.\n\n"
    "PRESERVE everything already correct. This is the hard rule: KEEP the existing variable "
    "NAMES and their naming convention (usually snake_case), KEEP the schema shape (scalar "
    "`default` values — never {\"value\": ...} wrappers), KEEP the template structure. Do NOT "
    "rename fields, do NOT restructure, do NOT switch conventions, do NOT reformat for taste.\n\n"
    "If the template is already correct, set changed=false (you may omit template/values_schema). "
    "Only when you actually fix something, set changed=true and return the FULL corrected "
    "template + values_schema. List removed variable names in `removed`."
)


async def _review_template(name: str, man_text: str | None, web_text: str, qwen: ChatClient) -> str | None:
    """Read the existing template+schema, correct factual errors against the
    sources while preserving correct structure/naming. Returns a short note if
    it changed anything, else None. No source ⇒ leave the template untouched."""
    if not man_text and len(web_text) < 400:
        return None
    tdir = TEMPLATES_DIR / name
    template = (tdir / "template.j2").read_text() if (tdir / "template.j2").exists() else ""
    schema = _load(tdir / "schema.json", {})
    docs = ""
    if man_text:
        docs += f"=== MAN PAGE (section 5) ===\n{man_text}\n\n"
    if web_text:
        docs += f"=== OFFICIAL DOCUMENTATION (web) ===\n{web_text}"
    user = (
        f"Package/service: {name}\n\n"
        f"=== EXISTING template.j2 ===\n{template}\n\n"
        f"=== EXISTING values_schema ===\n{json.dumps(schema, indent=2)}\n\n"
        f"{docs}\n\n"
        "Review the template+schema against the docs and correct factual errors "
        "per the rules. Preserve everything already correct."
    )
    try:
        out = await qwen.complete_json(
            [{"role": "system", "content": _REVIEW_SYSTEM}, {"role": "user", "content": user}],
            _REVIEW_SCHEMA, "review_template", max_tokens=None,
            extra_body=_NO_THINK,
        )
    except ChatClientError as exc:
        _note_llm_failure(f"{name}: template review", exc)
        print(f"  {name}: template review failed: {exc}", flush=True)
        return None
    if not out.get("changed"):
        return None
    new_tpl = out.get("template")
    new_schema = out.get("values_schema")
    if new_tpl:
        (tdir / "template.j2").write_text(new_tpl)
    if isinstance(new_schema, dict) and new_schema:
        (tdir / "schema.json").write_text(json.dumps(new_schema, indent=2) + "\n")
    removed = out.get("removed") or []
    return f"corrected (removed {len(removed)}: {', '.join(removed[:5])})" if removed else "corrected"


#: Why each string field has NO dropdown, per template. Shipped and served, not a debug log: the field
#: editor's job is to say why a setting is free text, and "nobody looked" / "looked, and no documentation
#: contains these values" / "the default contradicts the documented set" are three different answers an
#: operator would act on differently.
ENUM_ABSTENTIONS = _CONFIGS / "schema_enum_abstentions.json"


def _record_enum_abstentions(name: str, fields: dict[str, dict]) -> None:
    """Merge this template's abstentions into the shared record.

    Read-modify-write per template rather than accumulated in memory: the pass is resumable and may be killed
    at any point, and an abstention that only exists in a dead process's heap is the silent absence this
    record exists to end. An EMPTY dict is written too — that is the positive statement "every candidate
    field here got an enum", which is not the same as "this template was never processed".
    """
    try:
        have = json.loads(ENUM_ABSTENTIONS.read_text())
        if not isinstance(have, dict):
            have = {}
    except (OSError, ValueError):
        have = {}
    have[name] = fields
    write_catalog(ENUM_ABSTENTIONS, have, sort=True)


async def _mine_enums(
    name: str, entry: dict, man_text: str | None, web_text: str,
    sample_text: str, searx: SearxngClient, qwen: ChatClient,
) -> int:
    """Add enum values to schema.json from grounded sources. Sources, all
    authoritative (never model knowledge): (1) man page, (2) official web docs,
    (3) the installed default config file's comments — which often list the
    allowed values inline (# allowed: standard, administrator), and (4) a short
    PER-FIELD web search for the candidate fields, so a value set documented on
    a project page the general query missed still gets grounded. Every accepted
    value must appear verbatim in one of these."""
    tdir = TEMPLATES_DIR / name
    schema = _load(tdir / "schema.json", {})
    if not schema:
        return 0

    # Accept both flat {field: {type:...}} and wrapped {properties: {field: {...}}}
    props = schema.get("properties", schema)
    cands = {
        k: v
        for k, v in props.items()
        if isinstance(v, dict) and v.get("type") == "string"
        and not v.get("enum")
        and not k.startswith("_")
    }
    if not cands:
        return 0

    label = entry.get("label", name)
    fam = (entry.get("families") or {}).get("debian") or {}
    cfg = fam.get("config_path", "")

    # Combine sources — man page first (most authoritative). Show the FULL man
    # page: values we need sit far into it (LogLevel ~char 39k in sshd_config),
    # so any truncation would hide exactly the enumerations we're after.
    # (a) the installed default config's comments are included as a source.
    docs_sections = []
    if man_text:
        docs_sections.append(f"=== MAN PAGE (section 5) ===\n{man_text}")
    if sample_text:
        docs_sections.append(f"=== INSTALLED DEFAULT CONFIG (comments often list allowed values) ===\n{sample_text[:16000]}")
    if web_text:
        docs_sections.append(f"=== OFFICIAL DOCUMENTATION (web) ===\n{web_text}")
    docs = "\n\n".join(docs_sections) if docs_sections else ""

    field_lines = "\n".join(
        f"- {k} (type={v.get('type')}, default={v.get('default')!r}): {v.get('description','')[:100]}"
        for k, v in cands.items()
    )
    user = (
        f"Service: {label} (config file: {cfg or 'n/a'})\n\n"
        f"Candidate string fields (without enums yet):\n{field_lines}\n\n"
        f"{'Man page and official documentation' if docs else 'No documentation fetched — use your expert knowledge'}:\n{docs or '(none available)'}\n\n"
        "IMPORTANT: Only enumerate values that are ACTUALLY DOCUMENTED or well-established for this specific service. "
        "Do NOT invent or hallucinate values. If the man page lists accepted values, use exactly those. "
        "For each field above that accepts a KNOWN finite set of values, return ALL valid values. "
        "Typical enumerable fields: log_level, mode, driver, protocol, backend, algorithm, "
        "compression, auth_method, tls_version, scheduler, strategy, format, encoding. "
        "Be comprehensive — list every documented option, not just the most common ones. "
        "Skip only genuine free-text: paths, hostnames, IPs, usernames, arbitrary strings."
    )
    try:
        out = await qwen.complete_json(
            [{"role": "system", "content": _ENUM_SYSTEM}, {"role": "user", "content": user}],
            _ENUM_SCHEMA, "qualify_enums", max_tokens=None,
            extra_body=_NO_THINK,
        )
    except ChatClientError as exc:
        _note_llm_failure(f"{name}: enum mining", exc)
        print(f"  {name}: enum mining failed: {exc}", flush=True)
        return 0

    # Grounding: only accept enum values that literally appear in a fetched
    # source (man page or web docs). This is the anti-hallucination gate —
    # anything the model invents beyond what the sources document is dropped.
    # No source at all → write no enums (the field stays free-text) rather
    # than trust pure model knowledge (which mixed VMware/VBox OS types into
    # Proxmox's ostype). The web search IS the fix: richer, grounded sources.
    source_blob = f"{man_text or ''}\n{web_text or ''}\n{sample_text or ''}".lower()

    def _grounded_in(vals: list[str], blob: str) -> list[str]:
        if not blob.strip():
            return []
        # whole-token, case-insensitive: the value appears verbatim in a source
        return [v for v in vals if v and re.search(rf"(?<![\w-]){re.escape(v.lower())}(?![\w-])", blob)]

    # (b) Per-field web search fired ONLY on a gap: when the model proposed
    # values for a field but they don't ground in the primary sources, run one
    # short targeted query for THAT field and re-ground against it. Targets
    # exactly the missing value set instead of searching every field up front.
    async def _field_blob(field: str) -> str:
        try:
            hits = await searx.search(f"{label} {cfg or name} {field} possible values allowed", limit=3)
            if hits:
                return (await searx.fetch(hits[0].url, max_chars=8000)).lower()
        except Exception:  # noqa: BLE001
            pass
        return ""

    added = 0
    dropped = 0
    field_searches = 0
    # WHY A FIELD STAYED FREE TEXT, per field. Without this the only recoverable fact was "there is no
    # dropdown", and the three reasons a field ends up that way are not the same thing at all: nothing was
    # proposed, values were proposed but no source contains them, or exactly one grounded — which is not a
    # choice. 25 917 of 28 760 string fields have no enum, and until now not one of them could say why.
    abstained: dict[str, dict] = {}
    for item in out.get("enums", []):
        field, values = item.get("field"), item.get("values")
        if field not in props or not isinstance(props[field], dict):
            continue
        if not values or props[field].get("enum"):
            continue
        grounded = _grounded_in(values, source_blob)
        # Gap → one targeted per-field search (capped per package), re-ground.
        searched = False
        if len(grounded) < 2 and field_searches < 6:
            field_searches += 1
            searched = True
            extra = await _field_blob(field)
            if extra:
                grounded = _grounded_in(values, source_blob + "\n" + extra)
        dropped += len(values) - len(grounded)
        # A 1-value "enum" is not a choice — it means grounding kept only the
        # default (e.g. a y/n boolean where docs mention 'n' but not a bare
        # 'y'). Reject: better free-text than a nonsensical single-option
        # dropdown. Enums need at least two grounded values.
        if len(grounded) < 2:
            abstained[field] = {
                "reason": "no source contains any proposed value" if not grounded
                          else "only one value grounded — a single option is not a choice",
                "proposed": values[:12],
                "grounded": grounded,
                "sources": [k for k, v in (("man", man_text), ("shipped_config", sample_text),
                                           ("web", web_text)) if v],
                "field_search": searched,
            }
            continue
        cur = props[field].get("default")
        if cur in (None, "", *grounded):
            props[field]["enum"] = grounded
            if cur in (None, "") and item.get("default") in grounded:
                props[field]["default"] = item["default"]
            added += 1
        else:
            # The default is not among the grounded values, so one of the two is wrong and this pass cannot
            # tell which. Offering the dropdown would silently change the file's current setting on the
            # first Apply.
            abstained[field] = {
                "reason": f"the recorded default {cur!r} is not among the grounded values",
                "proposed": values[:12], "grounded": grounded,
                "sources": [k for k, v in (("man", man_text), ("shipped_config", sample_text),
                                           ("web", web_text)) if v],
                "field_search": searched,
            }

    # Every candidate the model said nothing about — the largest group, and previously the most invisible.
    for field in cands:
        if field not in abstained and not props.get(field, {}).get("enum"):
            abstained[field] = {
                "reason": "the model proposed no values for this field",
                "proposed": [], "grounded": [],
                "sources": [k for k, v in (("man", man_text), ("shipped_config", sample_text),
                                           ("web", web_text)) if v],
                "field_search": False,
            }
    _record_enum_abstentions(name, abstained)

    if added:
        (tdir / "schema.json").write_text(json.dumps(schema, indent=2) + "\n")
        note = f" ({dropped} ungrounded value(s) dropped)" if dropped else ""
        print(f"  {name}: +{added} enum field(s){note}", flush=True)
    elif dropped:
        print(f"  {name}: 0 enum field(s) — {dropped} ungrounded value(s) rejected", flush=True)
    return added


# ── main loop ─────────────────────────────────────────────────────────────────

def _strip_all_enums() -> int:
    """Remove all 'enum' keys from every schema.json in TEMPLATES_DIR.
    Returns the number of schemas modified.
    """
    modified = 0
    for tdir in TEMPLATES_DIR.iterdir():
        if not tdir.is_dir():
            continue
        schema_path = tdir / "schema.json"
        if not schema_path.exists():
            continue
        schema = _load(schema_path, {})
        if not schema:
            continue
        props = schema.get("properties", schema)
        changed = False
        for v in props.values():
            if isinstance(v, dict) and "enum" in v:
                del v["enum"]
                changed = True
        if changed:
            schema_path.write_text(json.dumps(schema, indent=2) + "\n")
            modified += 1
    return modified


def _has_unenumerated_strings(schema: dict) -> bool:
    """Return True if the schema has any string field without an enum."""
    props = schema.get("properties", schema)
    return any(
        isinstance(v, dict) and v.get("type") == "string"
        and not v.get("enum")
        and not k.startswith("_")
        for k, v in props.items()
    )


PIPELINE_STATE = _CONFIGS / ".qualify_pipeline_state.json"
# v6-enriched: every package now also gets a self-documenting template + capabilities.json (the Lego
# contract) via _enrich_template. Bumping from v5 re-runs all packages so the existing 3.219 dirs get
# enriched too (process_package leaves a complete dir's codec/enum alone and just adds the enrich step).
PIPELINE_VERSION = "v6-enriched"
# Directive catalog version — SEPARATE from PIPELINE_VERSION on purpose. A
# package is (re-)mined for directives whenever its directives_done marker
# != this; bumping it back-fills directives across already-qualified packages
# WITHOUT touching their codec/template/enum (those stay gated on
# PIPELINE_VERSION). Bump this alone to force a directive-only catch-up pass.
DIRECTIVES_VERSION = "dir-v1"


_ENRICH_SYSTEM = EG.SYSTEM_TEMPLATE + "\n\n" + EG.SYSTEM_CAPABILITIES
_ENRICH_ROUNDS = 3


async def _enrich_template(name: str, qwen: ChatClient) -> dict:
    """Turn a COMPLETE template dir into the two enriched artifacts (self-documenting template.j2 +
    capabilities.json) and a normalised schema.json, gated by enrich_gates' five checks with ≤3
    self-corrections. Writes back ONLY when every gate passes — otherwise the originals stand and the
    package is simply not (yet) enriched. Mirrors the proven pilot exactly."""
    tdir = TEMPLATES_DIR / name
    try:
        raw_schema = _load(tdir / "schema.json", {})
        props = raw_schema.get("properties", raw_schema) if isinstance(raw_schema, dict) else {}
        props, schema_changed = EG.normalize_schema(props)
        sample = _load(tdir / "sample.json", {})
        template_src = (tdir / "template.j2").read_text()
    except OSError as exc:
        return {"enriched": False, "gate_fail": f"read: {exc}"}

    async def _call(user: str) -> tuple[str, str]:
        reply = await qwen.complete_text(
            [{"role": "system", "content": _ENRICH_SYSTEM}, {"role": "user", "content": user}],
            extra_body=_NO_THINK,
        )
        return EG.split_artifacts(reply)

    # run_all_gates shells out to render-check (gonja) and renders jinja — blocking; keep it off the loop.
    async def _gates(tmpl: str, craw: str) -> tuple:
        return await asyncio.to_thread(EG.run_all_gates, name, tmpl, craw, props, sample)

    try:
        template, caps_raw = await _call(EG.build_user(name, template_src, props))
        caps, problems = await _gates(template, caps_raw)
        rounds = 0
        while problems and rounds < _ENRICH_ROUNDS:
            rounds += 1
            template, caps_raw = await _call(EG.build_fix_user(name, template, caps_raw, problems, props))
            caps, problems = await _gates(template, caps_raw)
    except ChatClientError as exc:
        _note_llm_failure("enrich", exc)   # endpoint down → package retried next pass
        return {"enriched": False}

    if problems:  # gates never all-green → leave originals untouched
        return {"enriched": False, "gate_fail": "; ".join(problems[:3])}

    # All gates green: write the three artifacts back atomically-ish (template + caps + normalised schema).
    (tdir / "template.j2").write_text(template)
    (tdir / "capabilities.json").write_text(json.dumps(caps, indent=2) + "\n")
    if schema_changed:
        if isinstance(raw_schema, dict) and "properties" in raw_schema:
            raw_schema["properties"] = props
            (tdir / "schema.json").write_text(json.dumps(raw_schema, indent=2) + "\n")
        else:
            (tdir / "schema.json").write_text(json.dumps(props, indent=2) + "\n")
    return {"enriched": True, "caps": caps}


def _doc_text(man_text: str | None, web_text: str | None, sample_text: str | None = None) -> str:
    """Combine the internet man page + the .deb-shipped config + web docs into one
    grounding blob for the directive miner — the SAME sources the codec/template/
    enum stages ground on. The man page documents allowed VALUES (enums); the
    shipped config carries the real keys + inline comments (the strongest key
    signal, exactly as the template stage uses it); web docs fill the gaps. A
    package with no LOCAL man page (e.g. jail.conf) is still mineable."""
    parts: list[str] = []
    if man_text:
        parts.append(man_text)
    if sample_text:
        parts.append("=== shipped config file ===\n" + sample_text)
    if web_text:
        parts.append("=== web docs ===\n" + web_text)
    return "\n\n".join(parts).strip()


async def _mine_directives(
    name: str, path: str | None, codecs: dict, doc_text: str,
    directives: dict, qwen: ChatClient, lock: asyncio.Lock | None = None,
) -> int:
    """Directive stage: mine this package's config file into the per-directive
    value catalog (config_directives.json) from `doc_text` (man page + web docs).
    codec:none / missing / no-doc files aren't mineable but still count as done
    for the directives version (nothing to add). An LLM failure registers via
    _note_llm_failure so the package is retried, not marked done. Returns the
    number of directives written."""
    spec = codecs.get(path) if path else None
    if not spec or spec.get("codec") in (None, "none") or not doc_text:
        return 0
    try:
        mined = await mine_one(path, doc_text, qwen)
    except Exception as exc:  # noqa: BLE001 — endpoint down → retry next pass
        _note_llm_failure(f"{name}: directive mining", exc)
        return 0
    if not mined:
        return 0
    async with (lock or contextlib.nullcontext()):
        directives[path] = mined
    return len(mined)


async def process_package(
    name: str, entry: dict, searx: SearxngClient, qwen: ChatClient,
    codecs: dict, state: dict, directives: dict, run_full: bool, run_directives: bool,
    lock: asyncio.Lock | None = None,
) -> dict:
    """Grounded pipeline for ONE package with SEPARATE focused calls (higher
    quality than one combined prompt, which dropped enums to 0). Sources (man
    page + web) are fetched ONCE and shared across the calls. Workflow order:
      Qualify → Codec → Template → Enum.
    Templates are regenerated ONLY for new/incomplete packages — an existing,
    complete template is left untouched (regenerating destroys curated ones:
    PascalCase names + malformed defaults). Existing templates still get their
    codec fixed and enums (re-)mined. Mutates codecs/state in memory."""
    _LLM_FAILURES.set([])   # per-package; a non-empty list at the end ⇒ "failed"
    tdir = TEMPLATES_DIR / name
    fam = (entry.get("families") or {}).get("debian") or {}
    cfg = fam.get("config_path", "")
    cfg_base = cfg.rsplit("/", 1)[-1] if cfg else ""
    label = entry.get("label", name)
    is_new = not tdir.is_dir()

    # ── Qualify from the Debian package + man page. ──
    # Download the Debian .deb ONCE: it yields the real config (template/codec/
    # enum source), the real /etc config path, AND the HARD has-config signal
    # (does it actually ship a file under /etc/). A section-5 man page is the
    # secondary source/signal. These two — extracted config + man page — are
    # the qualification basis; no qwen guessing.
    man_text = await _resolve_man(searx, name, cfg_base)
    web_text = await _web_docs(searx, label, name, cfg_base)
    # EVERY package of the role, not just the first. A role often names several — libvirtd is
    # ["libvirt-daemon-system", "qemu-system-x86"] — and the first one can be a metapackage that
    # ships nothing under /etc while a sibling carries the actual config. Taking [0] made libvirtd
    # look config-less when libvirt-daemon ships /etc/libvirt/libvirtd.conf, 17 kB of it.
    pkgs = fam.get("packages") if isinstance(fam.get("packages"), list) and fam.get("packages") else [name]
    pkg = pkgs[0]
    # _deb_config shells out to apt/dpkg (blocking); run it off the event loop so a package's .deb
    # download doesn't freeze every other concurrent worker. The shipped config is the strongest
    # grounding for BOTH the template AND the directives (real keys + inline comments), so it is
    # fetched for the directives-only fast path too — that path still skips the expensive LLM stages.
    shipped, ships_etc, real_path = None, False, None
    for candidate in pkgs:
        shipped, ships_etc, real_path = await asyncio.to_thread(
            _deb_config, candidate, cfg_base, name, cfg)
        # Stop at the first package that yields an actual config file. `ships_etc` alone is not
        # enough to stop on: a package can drop something under /etc (a defaults snippet, a
        # logrotate fragment) without shipping the config this role is about.
        if shipped:
            pkg = candidate
            break

    # Config path + sample text shared by every stage (codec/template/enum AND
    # directives): prefer the REAL path/config from the .deb, else derive/read local.
    path = real_path or _config_path(name, entry, man_text, codecs)
    sample_text = shipped or ""
    if not sample_text and cfg and Path(cfg).exists():
        try:
            sample_text = Path(cfg).read_text(errors="replace")[:60000]
        except OSError:
            pass

    # ── Directives-only fast path ─────────────────────────────────────────────
    # codec/template/enum/enrich are already at PIPELINE_VERSION; only the
    # independently-versioned directive catalog is behind. Mine it — grounded on
    # the man page + web docs + the .deb-shipped config — and return, with NO
    # codec/template/enum/enrich recompute.
    if not run_full:
        result = {"status": "ok"}
        if run_directives:
            result["directives"] = await _mine_directives(
                name, path, codecs, _doc_text(man_text, web_text, sample_text), directives, qwen, lock,
            )
        failures = _LLM_FAILURES.get()
        if failures:
            result["status"] = "failed"
            result["llm_errors"] = list(failures)
        return result

    has_config = ships_etc or bool(man_text)
    if is_new and not has_config:
        return {"status": "skip", "reason": "no config (no /etc in .deb, no man5)"}
    if not has_config and len(web_text) < 400:
        return {"status": "skip", "reason": "no config source"}

    result = {"status": "ok", "codec": None, "template": False, "enums": 0}

    # ── Codec: classify from the real config sample + man page. ──
    existing = codecs.get(path)
    if existing is None or existing.get("confidence") == "inferred":
        cls = await _classify_codec(man_text, sample_text[:8000], qwen)
        if cls and cls.get("codec"):
            # Write the shared codecs dict under the lock (re-reading `existing` inside, so a concurrent
            # package classifying the SAME path merges its package name rather than clobbering it), so a
            # concurrent flush() never iterates the dict mid-mutation.
            async with (lock or contextlib.nullcontext()):
                prev = codecs.get(path) or {}
                codecs[path] = {
                    "codec": cls.get("codec"), "separator": cls.get("separator", ""),
                    "comment": cls.get("comment", "#"), "sections": bool(cls.get("sections")),
                    "confidence": cls.get("confidence", "low"), "notes": cls.get("notes", ""),
                    "packages": sorted(set(prev.get("packages", []) + [name])),
                    "paths": [path],
                }
                result["codec"] = codecs[path]["codec"]

    # Parseable files (codec != none) are edited per-key via codec + directives;
    # they do NOT get a whole-file template. Template + enum + enrich are the
    # freeform (codec == none) path only — this is what stops the ~764-file
    # template/directive overlap from ever regrowing. (An unclassifiable file —
    # no codec written — falls through as freeform, which is the right fallback.)
    codec_none = (codecs.get(path) or {}).get("codec") in (None, "none")
    if codec_none:
        # Recorded BEFORE the generators run and regardless of which one wins: the fact "this template is
        # for that file" is true either way, and a failed LLM stage should not cost us the one piece of
        # knowledge we already had.
        _record_target(name, path, bool(real_path))
        # ── Template: parametrize the REAL shipped config (complete, valid by
        # construction). Man-page reconstruction is only the fallback. ──
        st = _check(tdir)
        if shipped:
            existing_schema = _load(tdir / "schema.json", {}) if st["schema"] else {}
            if await _parametrize_config(name, shipped, existing_schema, qwen):
                result["template"] = True
        if not result["template"]:
            if not (st["template"] and st["schema"] and st["sample"]):
                result["template"] = await _generate_template(name, man_text, web_text, qwen)
            else:
                note = await _review_template(name, man_text, web_text, qwen)
                if note:
                    result["template"] = True
                    result["review"] = note

        # ── Enum: (re-)mine grounded enums; the real config's comments are a source. ──
        schema = _load(tdir / "schema.json", {})
        if schema and _has_unenumerated_strings(schema):
            result["enums"] = await _mine_enums(name, entry, man_text, web_text, sample_text, searx, qwen)
        # ── Enrich: self-documenting template + capabilities.json (the Lego contract). ──
        # Runs on a COMPLETE template dir; leaves the originals untouched unless all five gates pass.
        complete = _check(tdir)
        if complete["template"] and complete["schema"] and complete["sample"]:
            enr = await _enrich_template(name, qwen)
            result["enriched"] = enr.get("enriched", False)
            if enr.get("caps"):
                result["capabilities"] = enr["caps"]
            if enr.get("gate_fail"):
                result["enrich_gate_fail"] = enr["gate_fail"]

    # ── Directives: independently versioned; grounded on the same man page + web
    #    docs + .deb-shipped config the codec/template/enum stages just used. ──
    if run_directives:
        result["directives"] = await _mine_directives(
            name, path, codecs, _doc_text(man_text, web_text, sample_text), directives, qwen, lock,
        )

    async with (lock or contextlib.nullcontext()):
        state[name] = _hash(_load(tdir / "schema.json", {}))
    # LLM was down for one or more steps → don't record as done; retry next pass.
    failures = _LLM_FAILURES.get()
    if failures:
        result["status"] = "failed"
        result["llm_errors"] = list(failures)
    return result


def build_entry_map(catalog: dict) -> dict[str, dict]:
    """name → the catalog entry that describes it, keyed by TEMPLATE and by PACKAGE.

    Extracted from main() so the on-demand path resolves a package exactly the way the batch does. It is
    not a lookup dressed up as a function: the second loop is the fix for a measured bug, and an endpoint
    that skipped it would silently produce a different template for the same package.
    """
    entry_by_name: dict[str, dict] = {}
    for pkg_name, pkg_info in catalog.items():
        tpl = pkg_info.get("template")
        if tpl:
            entry_by_name.setdefault(tpl, {"name": pkg_name, **pkg_info})
    # …and by PACKAGE name, so a worklist item that is a package rather than a template still
    # inherits its role's config_path. Without this, `libvirt-daemon` arrived with no catalog entry,
    # so cfg_path was empty, so the picker fell back to the shallowest conffile and templated
    # /etc/default/libvirtd (6 SysV variables) instead of /etc/libvirt/libvirtd.conf (17 kB). The
    # role knows the path; the package just had no way to ask. setdefault keeps the template
    # mapping above authoritative where both apply.
    for pkg_name, pkg_info in catalog.items():
        for dep in ((pkg_info.get("families") or {}).get("debian") or {}).get("packages") or []:
            if isinstance(dep, str) and dep:
                entry_by_name.setdefault(dep, {"name": pkg_name, **pkg_info})
    return entry_by_name


class SharedCatalogs:
    """The five files every qualify run reads and writes, with the MERGING flush.

    Why a class rather than five locals: the on-demand endpoint writes the same files as the batch service,
    and the safety of that is entirely in `flush()` — re-read, apply only the keys this process touched,
    write. Given as five separate dicts, the second caller reimplements the flush, and the first wholesale
    overwrite silently discards the other's pass. One object means one flush.

    The window is not closed (this is read-modify-write, not a transaction) but it shrinks from "the whole
    pass" — minutes — to "the flush", milliseconds.
    """

    def __init__(self) -> None:
        self.state = TrackedDict(_load(STATE, {}))
        self.pipeline_done = TrackedDict(_load(PIPELINE_STATE, {}))
        self.directives_done = TrackedDict(_load(DIRECTIVES_STATE, {}))
        self.skip_set = _load_skip_set()
        self.codecs = TrackedDict(_load(CODECS, {}))
        self.directives = TrackedDict(_load(DIRECTIVES, {}))

    def flush(self) -> None:
        _write_json(STATE, self.state.merged_with_disk(STATE), sort=False)
        _write_json(PIPELINE_STATE, self.pipeline_done.merged_with_disk(PIPELINE_STATE), sort=False)
        _write_json(DIRECTIVES_STATE, self.directives_done.merged_with_disk(DIRECTIVES_STATE), sort=False)
        _write_json(CODECS, self.codecs.merged_with_disk(CODECS), sort=True)
        _write_json(DIRECTIVES, self.directives.merged_with_disk(DIRECTIVES), sort=True)
        # The skip-set only ever grows, so a union is the whole merge it needs.
        _save_skip_set(self.skip_set | _load_skip_set())

    def stale(self, name: str) -> tuple[bool, bool]:
        """(codec/template/enum is behind, directives are behind) — the two independently versioned halves."""
        return (self.pipeline_done.get(name) != PIPELINE_VERSION,
                self.directives_done.get(name) != DIRECTIVES_VERSION)

    def mark_done(self, name: str) -> None:
        self.pipeline_done[name] = PIPELINE_VERSION
        self.directives_done[name] = DIRECTIVES_VERSION

    def clear(self, name: str) -> list[str]:
        """Forget every marker for one name so the next run redoes it. What `--rebuild --only` does,
        scoped to a single package: a global rebuild would re-run ~5400 packages for days."""
        cleared = []
        for data in (self.state, self.pipeline_done, self.directives_done):
            for key in [k for k in list(data) if k == name or Path(k).name == name]:
                del data[key]
                cleared.append(key)
        self.skip_set.discard(name)
        return cleared


def llm_client(llm_url: str = "", llm_model: str = "", llm_token: str = "",
               preset: str = "qwen79b") -> ChatClient:
    """The LLM backend: an explicit endpoint wins over the baked-in preset.

    The AI endpoint must be CONFIGURABLE and not hardwired — Bossman passes its own configured backend, and
    a caller that forgot to would silently talk to whatever host the preset names.
    """
    if llm_url and llm_model:
        return ChatClient(llm_url, llm_model, token=llm_token, timeout=900.0)
    base_url, model_id = MODELS[preset]
    return ChatClient(base_url, model_id, token="", timeout=900.0)


async def qualify_one(
    name: str, *, llm_url: str = "", llm_model: str = "", llm_token: str = "",
    preset: str = "qwen79b", force: bool = False,
) -> dict:
    """Run the pipeline for ONE package, IN THIS PROCESS, and return what it did.

    The on-demand endpoint used to spawn `python -m bossman.tools.qualify_packages --only <name>` and then
    reconstruct the outcome from a 40-line log tail plus a re-read of the config files. Two things were wrong
    with that beyond the cost of an interpreter:

      * process_package ALREADY RETURNS the outcome — status, codec, whether a template was written, how many
        enums and directives were mined, whether the enrich gates passed. Parsing prose to recover a value
        the callee handed back is a self-inflicted loss of information, and it is why the endpoint reported
        `codec: null` for packages whose codec it had just classified.
      * An already-current package fell out of the batch's `pending` list, so NOTHING ran and the caller was
        told `ok: true` — indistinguishable from having just built it. Here that is `already_current`, a
        stated answer, and `force=True` is how a caller asks for the rebuild instead.

    Returns process_package's dict plus `already_current`, `cleared` and `flushed`.
    """
    catalog = _load(CATALOG, {})
    universe_deb: dict[str, dict] = _load(UNIVERSE, {}).get("debian", {})
    shared = SharedCatalogs()

    cleared: list[str] = []
    if force:
        cleared = shared.clear(name)
    run_full, run_directives = shared.stale(name)
    if not (run_full or run_directives):
        return {"status": "ok", "already_current": True, "cleared": cleared, "flushed": False,
                "pipeline_version": PIPELINE_VERSION, "directives_version": DIRECTIVES_VERSION}

    entry = build_entry_map(catalog).get(name) or {**universe_deb.get(name, {}), "name": name}
    qwen = llm_client(llm_url, llm_model, llm_token, preset)
    searx = SearxngClient(SEARXNG)
    # Blocking: it may compile the gonja render-check binary. Off the loop, or a single qualify request
    # stalls every other request this Bossman is serving — which the subprocess never had to think about.
    await asyncio.to_thread(EG.render_check_bin)

    result = await process_package(
        name, entry, searx, qwen, shared.codecs, shared.state, shared.directives,
        run_full, run_directives, asyncio.Lock(),
    )
    if result.get("status") == "skip":
        shared.skip_set.add(name)
    elif result.get("status") != "failed":
        # A "failed" package is a step whose LLM was down. NOT marking it done is the whole reason the batch
        # is resumable — marking it would record a package as qualified that never was.
        shared.mark_done(name)
    await asyncio.to_thread(shared.flush)
    return {**result, "already_current": False, "cleared": cleared, "flushed": True,
            "pipeline_version": PIPELINE_VERSION, "directives_version": DIRECTIVES_VERSION}


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--limit", type=int, default=0, help="max packages processed this pass")
    ap.add_argument("--only", default="", help="comma-separated package/template names")
    ap.add_argument("--check-only", action="store_true", help="report status, do not generate")
    ap.add_argument("--rebuild", action="store_true",
                    help="full redo: clear pipeline state, enum state and skip-set, "
                         "regenerate every template grounded and re-classify guessed codecs")
    ap.add_argument("--model", choices=sorted(MODELS),
                    default=os.environ.get("QUALIFY_MODEL", "qwen79b"),
                    help="LLM backend PRESET (default: env QUALIFY_MODEL or qwen79b). "
                         "Overridden by --llm-url/--llm-model when given.")
    # Explicit LLM endpoint (the AI endpoint must be CONFIGURABLE, not hardwired):
    # when --llm-url + --llm-model are given (or the env fallbacks), they win over
    # the --model preset, so the on-demand qualify endpoint can pass Bossman's own
    # configured AI backend + optional API key instead of the baked-in URLs.
    ap.add_argument("--llm-url", default=os.environ.get("QUALIFY_LLM_URL", ""),
                    help="LLM base URL (OpenAI-compatible); overrides --model. Env: QUALIFY_LLM_URL")
    ap.add_argument("--llm-model", default=os.environ.get("QUALIFY_LLM_MODEL", ""),
                    help="LLM model name for --llm-url. Env: QUALIFY_LLM_MODEL")
    ap.add_argument("--llm-token", default=os.environ.get("QUALIFY_LLM_TOKEN", ""),
                    help="optional bearer token for --llm-url. Env: QUALIFY_LLM_TOKEN")
    ap.add_argument("--concurrency", type=int,
                    default=int(os.environ.get("QUALIFY_CONCURRENCY", "1")),
                    help="packages processed in parallel (the llamacpp endpoint has parallel slots). "
                         "Default: env QUALIFY_CONCURRENCY or 1 (sequential).")
    args = ap.parse_args()

    only = {s.strip() for s in args.only.split(",") if s.strip()}
    catalog = _load(CATALOG, {})
    universe_deb: dict[str, dict] = _load(UNIVERSE, {}).get("debian", {})

    # ── --rebuild: wipe the markers so every package is reprocessed grounded. ──
    if args.rebuild and args.only:
        # SCOPED redo. --rebuild alone wipes the state for all ~5400 packages, which is the right
        # tool for a pipeline-wide change and the wrong one for "this template is wrong, make it
        # again": that would re-run every package for days while the supervisor is mid-pass. With
        # --only, clear the markers for those names and nothing else, so the next pass regenerates
        # exactly them. The enum strip is deliberately skipped here — it is global by nature and
        # the per-package enum marker being cleared already forces a re-mine.
        wanted = {n.strip() for n in args.only.split(",") if n.strip()}
        cleared = []
        for path, default in ((STATE, {}), (PIPELINE_STATE, {}), (DIRECTIVES_STATE, {})):
            data = _load(path, default)
            hit = [k for k in list(data) if k in wanted or Path(k).name in wanted]
            for k in hit:
                del data[k]
            if hit:
                path.write_text(json.dumps(data, indent=2) + "\n")
                cleared += hit
        skip = _load_skip_set()
        if isinstance(skip, (list, set)) and any(s in wanted for s in skip):
            _SKIP_MARKER.write_text(json.dumps(sorted(s for s in skip if s not in wanted), indent=2) + "\n")
        print(f"rebuild --only: cleared markers for {len(set(cleared))} name(s): "
              f"{', '.join(sorted(set(cleared))) or '—'}", flush=True)
    elif args.rebuild:
        _strip_all_enums()
        STATE.write_text("{}\n")
        PIPELINE_STATE.write_text("{}\n")
        DIRECTIVES_STATE.write_text("{}\n")   # re-mine directives too (the catalog itself is kept)
        _SKIP_MARKER.write_text("[]\n")
        print("rebuild: cleared enum state, pipeline state, directive state and skip-set", flush=True)

    # TrackedDict, not dict: a pass runs for minutes and another writer may touch the same files
    # meanwhile. See TrackedDict and SharedCatalogs.flush for the measurement — the flush MERGES
    # rather than overwriting, and it is the same object the on-demand endpoint uses.
    shared = SharedCatalogs()
    state, codecs, directives = shared.state, shared.codecs, shared.directives
    pipeline_done, directives_done, skip_set = shared.pipeline_done, shared.directives_done, shared.skip_set

    # Package entry map: catalog templates + universe metadata (section/desc).
    entry_by_name = build_entry_map(catalog)

    # Work list: existing template dirs first (fix/regrade), then universe.
    existing_names = sorted(d.name for d in TEMPLATES_DIR.iterdir() if d.is_dir())
    worklist: list[str] = list(existing_names)
    for pkg_name, pkg_info in universe_deb.items():
        if pkg_name in existing_names:
            continue
        if pkg_info.get("section", "") in _NO_CONFIG_SECTIONS:
            skip_set.add(pkg_name)  # fast section filter, no LLM
            continue
        worklist.append(pkg_name)

    # The worklist so far is "template dirs + the universe snapshot". That leaves out packages the
    # CATALOG itself offers as roles: libvirtd installs libvirt-daemon-system, whose config lives in
    # libvirt-daemon — a package absent from the universe listing, so the pipeline could never
    # qualify it and the role sat there permanently config-less. A role the product offers must be
    # reachable by the pipeline that is supposed to configure it; anything else is the catalog
    # promising something no stage is responsible for.
    for pkg_name in _catalog_packages():
        if pkg_name not in worklist and pkg_name not in skip_set:
            worklist.append(pkg_name)

    if only:
        worklist = [n for n in worklist if n in only]

    # Curated, hand-authored templates the batch must NOT regenerate (they are
    # maintained by hand + verified, e.g. the web-server vhost templates). --only
    # can still target them explicitly for a deliberate rebuild.
    if not only:
        worklist = [n for n in worklist if n not in _CURATED]

    # Resume: process a package if its codec/template pipeline is behind
    # PIPELINE_VERSION OR its (separately versioned) directive catalog is behind
    # DIRECTIVES_VERSION — the latter alone triggers a directives-only fast pass
    # that leaves codec/template untouched. Skip no-config packages (skip-set).
    pending = [
        n for n in worklist
        if n not in skip_set and (
            pipeline_done.get(n) != PIPELINE_VERSION
            or directives_done.get(n) != DIRECTIVES_VERSION
        )
    ]
    dir_only = sum(
        1 for n in pending
        if pipeline_done.get(n) == PIPELINE_VERSION and directives_done.get(n) != DIRECTIVES_VERSION
    )

    print(
        f"qualify pipeline {PIPELINE_VERSION} / directives {DIRECTIVES_VERSION}: {len(worklist)} packages "
        f"({len(existing_names)} existing + universe) — "
        f"{len(pending)} pending ({dir_only} directives-only), {len(worklist) - len(pending)} done, "
        f"{len(skip_set)} skipped (no config)",
        flush=True,
    )

    if args.check_only:
        for n in pending[:25]:
            print(f"  pending: {n}")
        return 0

    if args.limit:
        pending = pending[: args.limit]

    # Explicit endpoint (Bossman-configured / on-demand) wins over the preset — decided by llm_client(),
    # the same function the on-demand path calls, so "which backend answered" cannot differ between them.
    if args.llm_url and args.llm_model:
        print(f"qualify LLM backend: {args.llm_model} @ {args.llm_url} (explicit)", flush=True)
    else:
        print(f"qualify LLM backend: {args.model} ({MODELS[args.model][1]})", flush=True)
    qwen = llm_client(args.llm_url, args.llm_model, args.llm_token, args.model)
    searx = SearxngClient(SEARXNG)
    # Build the gonja render-check binary ONCE up front — lazily building it inside concurrent workers
    # would race two `go build`s onto the same output path.
    EG.render_check_bin()

    lock = asyncio.Lock()   # guards the shared state dicts + flush against concurrent workers
    # The merging write lives on SharedCatalogs, shared with the on-demand endpoint — see its docstring for
    # why a second copy of it would be the bug it prevents. Here it is additionally serialised by `lock`
    # against this pass's own concurrent workers.
    flush = shared.flush

    total = len(pending)
    conc = max(1, args.concurrency)
    sem = asyncio.Semaphore(conc)
    counter = {"n": 0}
    print(f"\n[pipeline] processing {total} package(s), concurrency={conc}…", flush=True)

    async def record(name: str, r: dict) -> None:
        # All shared-state mutation + flushing happens here, serialised by `lock`, so concurrent workers
        # never corrupt the dicts or flush a half-written one.
        async with lock:
            counter["n"] += 1
            i = counter["n"]
            if r["status"] == "skip":
                skip_set.add(name)
                print(f"[{i}/{total}] {name}: skip ({r['reason']})", flush=True)
            elif r["status"] == "failed":
                # LLM down for a step → NOT marked done, so the resumable pass retries it once the
                # endpoint is back (was previously mis-recorded as "ok").
                print(f"[{i}/{total}] {name}: FAILED (llm) — "
                      f"{'; '.join(r.get('llm_errors', []))[:180]}", flush=True)
            else:
                # A directives-only fast pass leaves pipeline_done as it already
                # was (still == PIPELINE_VERSION); a full pass (re)affirms it.
                shared.mark_done(name)
                bits = []
                if r.get("codec"):
                    bits.append(f"codec={r['codec']}")
                if r.get("template"):
                    bits.append("template")
                if r.get("enums"):
                    bits.append(f"+{r['enums']} enum")
                if r.get("directives"):
                    bits.append(f"+{r['directives']} dir")
                if r.get("enriched"):
                    caps = r.get("capabilities") or {}
                    bits.append(f"enriched(prov={len(caps.get('provides', []))},"
                                f"req={len(caps.get('requires', []))})")
                elif r.get("enrich_gate_fail"):
                    bits.append(f"enrich-skip[{r['enrich_gate_fail'][:60]}]")
                print(f"[{i}/{total}] {name}: {', '.join(bits) or 'ok'}", flush=True)
            if counter["n"] % 5 == 0:
                flush()

    async def worker(name: str) -> None:
        entry = entry_by_name.get(name) or {**universe_deb.get(name, {}), "name": name}
        run_full = pipeline_done.get(name) != PIPELINE_VERSION
        run_directives = directives_done.get(name) != DIRECTIVES_VERSION
        async with sem:
            try:
                r = await process_package(
                    name, entry, searx, qwen, codecs, state, directives, run_full, run_directives, lock,
                )
            except Exception as exc:  # noqa: BLE001 — one bad package must not kill the batch
                async with lock:
                    counter["n"] += 1
                    print(f"[{counter['n']}/{total}] {name}: ERROR {str(exc)[:120]}", flush=True)
                return
        await record(name, r)

    # asyncio.gather wraps each worker in a Task, which copies the context — so every package's
    # _LLM_FAILURES ContextVar binding is isolated even when conc > 1.
    await asyncio.gather(*(worker(n) for n in pending))
    flush()
    print("[pipeline] pass complete", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
