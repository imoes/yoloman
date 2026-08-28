# Documentation

GitHub shows this file when you browse the folder; **[index.html](index.html)** is the same entry point as a
page. This folder IS served: **https://imoes.github.io/yoloman/** (GitHub Pages, from `main`). Both files exist on purpose — a
repository view renders markdown and shows HTML as source, so the folder needs a readable index either way.

## Start here

| | |
|---|---|
| [index.html](index.html) | The presentation: what yoloman and Bossman are, with screenshots. **A page — needs serving.** |
| [frontend-presentation.html](frontend-presentation.html) | Every screen (54) in five workspaces, each described by its own source. **A page.** |
| [CHANGELOG.md](https://github.com/imoes/yoloman/blob/main/CHANGELOG.md) | What is new, changed, fixed — and what is still missing. |

## Reference

Prose, on purpose — and generated, so it cannot drift from the system it describes. **There is no JSON copy
any more.** There was one, on the theory that a machine reader wants a schema dump; that was a
misunderstanding of the machine reader. A model needs to know what an endpoint is *for*, what it refuses, and
which of two similar endpoints is right — a JSON schema answers none of those, and the copy could only repeat
the markdown less readably while needing to be kept in step.

| Page | What it answers | Generated from |
|---|---|---|
| [developing.md](developing.md) | **Start here.** What the system is, where truth lives, the contracts, how to add things, the traps — and a final section addressed to a language model working here. | Hand-written. |
| [api-reference.md](api-reference.md) | All 481 HTTP operations in 68 groups, in words. | A *running* server's `/openapi.json`. |
| [modules-windows.md](modules-windows.md) · [modules-linux.md](modules-linux.md) | Every module an agent exposes right now. | The agents' `GET /api/v1/tools`. |
| [frontend-presentation.html](frontend-presentation.html) | Every screen (54), described by its own source. | The UI source. |

Regenerate with `scripts/generate-api-reference.py`, `scripts/generate-module-docs.py` and
`scripts/generate-frontend-presentation.py`, all against a running instance. Do not edit the generated pages
by hand.

## Guides and design notes

| | |
|---|---|
| [developing.md](developing.md) | The developer guide — and the guide for an AI working in this repository. |
| [checks-authoring.md](checks-authoring.md) | Writing a check, from empty file to a service state on a host — with the four traps that cost a real run. |
| [windows-management.md](windows-management.md) | Roles, features, packaging and the snap-ins. Every number in it was measured on a real host. |
| [windows-agent.md](windows-agent.md) | Why .NET, why WMI, and the defects only a real install could show. |

The rest of this folder is design documents, one per subject. They carry the reasoning; the generated pages
carry the current facts.

## When a link 404s

[404.html](404.html) says *why*, per case: the two deleted JSON references, a `.md` that is served raw
rather than rendered, or something that was never here. A 404 that gives no reason leaves a reader unable to
tell "removed on purpose" from "never existed", and both of those are answers.

## Why `.nojekyll` is here

GitHub Pages runs Jekyll by default, which ignores files and folders whose names begin with `_` and can
rewrite paths. This site is plain HTML and needs neither, and a screenshot that silently 404s because of a
build step nobody asked for is the failure mode that file prevents.
