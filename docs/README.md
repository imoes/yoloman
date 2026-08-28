# Documentation

GitHub shows this file when you browse the folder; **[index.html](index.html)** is the same entry point as a
page, for when this folder is served (GitHub Pages, or opened locally). Both exist on purpose: a repository
view renders markdown and shows HTML as source, so the folder needs a readable index either way.

## Start here

| | |
|---|---|
| [index.html](index.html) | The presentation: what yoloman and Bossman are, with screenshots. **A page — needs serving.** |
| [frontend-presentation.html](frontend-presentation.html) | Every screen (54) in five workspaces, each described by its own source. **A page.** |
| [../CHANGELOG.md](../CHANGELOG.md) | What is new, changed, fixed — and what is still missing. |

## Reference — for people, and for machines

| Subject | Human | Machine |
|---|---|---|
| Windows modules (34) | [modules-windows.md](modules-windows.md) | [modules-windows.json](modules-windows.json) |
| Linux modules (84) | [modules-linux.md](modules-linux.md) | [modules-linux.json](modules-linux.json) |
| Every screen (54) | [frontend-presentation.html](frontend-presentation.html) | the live API: `GET /openapi.json` |

Both module references are **generated** from what the agents themselves publish
(`GET /api/v1/agents/{id}/tools`) by `scripts/generate-module-docs.py`, in one pass — so the human and the
machine shape cannot disagree. Do not edit them by hand.

## Guides and design notes

| | |
|---|---|
| [checks-authoring.md](checks-authoring.md) | Writing a check, from empty file to a service state on a host — with the four traps that cost a real run. |
| [windows-management.md](windows-management.md) | Roles, features, packaging and the snap-ins. Every number in it was measured on a real host. |
| [windows-agent.md](windows-agent.md) | Why .NET, why WMI, and the defects only a real install could show. |

The rest of this folder is design documents, one per subject. They carry the reasoning; the generated pages
carry the current facts.

## Why `.nojekyll` is here

GitHub Pages runs Jekyll by default, which ignores files and folders whose names begin with `_` and can
rewrite paths. This site is plain HTML and needs neither, and a screenshot that silently 404s because of a
build step nobody asked for is the failure mode that file prevents.
