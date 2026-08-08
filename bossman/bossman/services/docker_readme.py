"""Extract a Docker image's configurable variables from its Docker Hub README.

For a given image this fetches the Hub overview (full_description) and asks the
configured OpenRouter model (settings.docker_extract_model, e.g. laguna-s2.1) to
pull out the env-var knobs (name/default/description), exposed ports and volumes
as templating-style parameters — the docker counterpart to the config-template
schemas. Results are stored in docker_app_templates for the app store/blueprint.
TOP_IMAGES is a curated set of the most-deployed containers to seed the catalog.
"""

from __future__ import annotations

import hashlib
import json
import re
from typing import Any

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from bossman.config import Settings
from bossman.db.models import DEFAULT_TENANT_ID, DockerAppTemplate
from bossman.services.chat_backend import ChatBackendError, chat_backend_for

# Curated most-common containers (rank = popularity). Official images use the
# bare name; others carry their namespace.
TOP_IMAGES: list[str] = [
    "nginx", "postgres", "redis", "mysql", "mariadb", "mongo", "httpd", "node", "python", "traefik",
    "memcached", "rabbitmq", "influxdb", "elasticsearch", "wordpress", "grafana/grafana", "prom/prometheus",
    "portainer/portainer-ce", "jenkins/jenkins", "gitlab/gitlab-ce", "sonarqube", "nextcloud", "vaultwarden/server",
    "jellyfin/jellyfin", "linuxserver/plex", "homeassistant/home-assistant", "adguard/adguardhome", "pihole/pihole",
    "louislam/uptime-kuma", "photoprism/photoprism", "minio/minio", "haproxy", "caddy", "consul", "vault",
    "telegraf", "prom/node-exporter", "prom/alertmanager", "grafana/loki", "grafana/promtail", "jaegertracing/all-in-one",
    "eclipse-mosquitto", "nats", "keycloak/keycloak", "quay.io/keycloak/keycloak", "gitea/gitea", "drone/drone",
    "registry", "docker", "busybox", "alpine", "ubuntu", "debian", "hashicorp/vault", "hashicorp/consul",
    "bitnami/postgresql", "bitnami/redis", "bitnami/kafka", "confluentinc/cp-kafka", "zookeeper", "cassandra",
    "couchdb", "neo4j", "clickhouse/clickhouse-server", "timescale/timescaledb", "pgvector/pgvector",
    "ghost", "joomla", "drupal", "mediawiki", "matomo", "rocket.chat", "mattermost/mattermost-team-edition",
    "wekanteam/wekan", "focalboard", "vikunja/vikunja", "linuxserver/sonarr", "linuxserver/radarr",
    "linuxserver/qbittorrent", "linuxserver/nextcloud", "filebrowser/filebrowser", "syncthing/syncthing",
    "duplicati/duplicati", "restic/rest-server", "miniflux/miniflux", "freshrss/freshrss", "wallabag/wallabag",
    "code-server", "codercom/code-server", "gitpod/openvscode-server", "n8nio/n8n", "nodered/node-red",
    "apache/airflow", "metabase/metabase", "apache/superset", "redash/redash", "grafana/tempo", "vectordotdev/vector",
    "fluent/fluentd", "opensearchproject/opensearch", "kibana", "logstash", "sentry", "getsentry/sentry",
]


def _repo_path(image: str) -> str:
    """Docker Hub repo path: official images live under `library/`."""
    img = image.split(":", 1)[0]  # drop any tag
    if img.startswith("quay.io/") or "@" in img:
        return img  # non-Hub / digest — return as-is (README fetch will just fail)
    return img if "/" in img else f"library/{img}"


async def fetch_readme(image: str, timeout: float = 20.0) -> dict[str, str]:
    """{name, description, readme} from Docker Hub, or raises ValueError."""
    path = _repo_path(image)
    url = f"https://hub.docker.com/v2/repositories/{path}/"
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(url)
    except httpx.HTTPError as exc:
        raise ValueError(f"fetching Hub page for {image!r}: {exc}") from exc
    if resp.status_code != 200:
        raise ValueError(f"Docker Hub returned {resp.status_code} for {image!r}")
    data = resp.json()
    return {
        "name": data.get("name") or image,
        "description": data.get("description") or "",
        "readme": data.get("full_description") or "",
    }


_SYSTEM = """You extract the configurable knobs of a Docker image from its README as TYPED DIRECTIVES.
Reply with a SINGLE JSON object and nothing else (no prose, no code fences):

{
  "description": "one line on what the image is",
  "variables": [
    {"name": "POSTGRES_PASSWORD", "type": "string", "default": "", "required": true,
     "secret": true, "description": "Superuser password; must be set."},
    {"name": "TZ", "type": "string", "default": "UTC", "required": false,
     "description": "Container timezone, e.g. Europe/Berlin."},
    {"name": "LOG_LEVEL", "type": "enum", "choices": ["debug","info","warn","error"], "default": "info",
     "required": false, "description": "Logging verbosity."}
  ],
  "ports": ["5432"],
  "volumes": ["/var/lib/postgresql/data"]
}

Each variable is a directive with:
- name  : the env var name, exactly.
- type  : one of "string" | "int" | "bool" | "enum" | "port" | "path".
- default: the documented default (a real value; "" only if there truly is none).
- required: true if the container won't start / is unsafe without it.
- choices: for type "enum", the allowed values (omit otherwise).
- secret: true for passwords/tokens/keys (render as a password field).
- description: one clear sentence — ALWAYS fill this, never leave empty.

Include only variables/ports/volumes the README actually documents — do not invent. Empty arrays if none."""


def _parse_json_object(text: str) -> dict[str, Any]:
    t = re.sub(r"^```(?:json)?|```$", "", (text or "").strip(), flags=re.MULTILINE).strip()
    start = t.find("{")
    if start < 0:
        raise ValueError("model returned no JSON object")
    depth = 0
    for i in range(start, len(t)):
        if t[i] == "{":
            depth += 1
        elif t[i] == "}":
            depth -= 1
            if depth == 0:
                return json.loads(t[start : i + 1])
    raise ValueError("unterminated JSON object")


async def extract_variables(readme: str, image: str, settings: Settings) -> dict[str, Any]:
    """LLM-extract {description, variables, ports, volumes} from a README."""
    backend = chat_backend_for(settings, "openrouter")
    # Keep the prompt bounded — READMEs can be huge; the knobs are near the top.
    body = readme[:12000]
    messages = [
        {"role": "system", "content": _SYSTEM},
        {"role": "user", "content": f"Image: {image}\n\nREADME:\n{body}"},
    ]
    try:
        res = await backend.complete_with_tools(messages, [], model=settings.docker_extract_model)
    except ChatBackendError as exc:
        raise ValueError(f"LLM backend error: {exc}") from exc
    return _parse_json_object(res.get("content", ""))


_VALID_TYPES = {"string", "int", "bool", "enum", "port", "path"}


def _normalize_var(v: Any) -> dict[str, Any] | None:
    """Coerce one extracted variable into a complete, typed directive; drop it if
    it has no usable name. Guarantees name/type/default/required/description keys
    so the UI can render a typed field without guessing."""
    if not isinstance(v, dict) or not str(v.get("name") or "").strip():
        return None
    vtype = str(v.get("type") or "string").lower()
    if vtype not in _VALID_TYPES:
        vtype = "string"
    default = v.get("default", "")
    out: dict[str, Any] = {
        "name": str(v["name"]).strip(),
        "type": vtype,
        "default": "" if default is None else default,
        "required": bool(v.get("required", False)),
        "description": str(v.get("description") or "").strip(),
    }
    if v.get("secret"):
        out["secret"] = True
    if vtype == "enum" and isinstance(v.get("choices"), list) and v["choices"]:
        out["choices"] = [str(c) for c in v["choices"]]
    return out


async def extract_and_store(
    session: AsyncSession, settings: Settings, image: str, popularity: int = 0
) -> DockerAppTemplate:
    """Fetch the README, extract the variables, and upsert a DockerAppTemplate.
    Skips the LLM call when the README is unchanged since the last extraction."""
    meta = await fetch_readme(image)
    readme_hash = hashlib.sha256(meta["readme"].encode("utf-8")).hexdigest()
    row = await session.scalar(select(DockerAppTemplate).where(DockerAppTemplate.image == image))
    # Re-extract when the README changed OR the stored vars predate the typed
    # directive shape (missing "type"), so upgrades enrich existing rows.
    typed = bool(row and row.variables) and all(isinstance(v, dict) and "type" in v for v in (row.variables or []))
    if row is not None and row.readme_hash == readme_hash and row.variables and typed:
        if popularity and not row.popularity:
            row.popularity = popularity
        return row

    extracted = await extract_variables(meta["readme"], image, settings)
    variables = [nv for nv in (_normalize_var(v) for v in (extracted.get("variables") or [])) if nv]
    ports = [str(p) for p in (extracted.get("ports") or [])]
    volumes = [str(v) for v in (extracted.get("volumes") or [])]
    desc = extracted.get("description") or meta["description"]

    if row is None:
        row = DockerAppTemplate(tenant_id=DEFAULT_TENANT_ID, image=image)
        session.add(row)
    row.name = image.split("/")[-1]
    row.description = desc
    row.variables = variables
    row.ports = ports
    row.volumes = volumes
    row.readme_hash = readme_hash
    if popularity:
        row.popularity = popularity
    return row
