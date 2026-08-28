# `bossman/tools` — the scripts the PRODUCT runs

Eight files, and the boundary is not a matter of taste: these are the only ones something in the product
executes at runtime.

| | run by |
|---|---|
| `seed_admin.py` | the compose `seed` service, and `bossman-create-admin` in the package |
| `qualify_packages.py` | the on-demand qualify endpoint (`api/package_qualify.py`) |
| `build_package_catalog.py` | the same endpoint, right after it |
| `dump_module_sources.py` | the module-library surface |
| `enrich_gates.py`, `mine_directive_values.py`, `classify_config_codecs.py`, `batch_verify.py` | imported by the four above — the transitive closure, computed rather than guessed |

Everything else that used to live beside them (94 files: mining, translation, auditing, the systemd units that
drive the batches) is local OPERATING equipment and is not in this repository. It is where the LLM endpoints,
the proxy address and the model names live, which is how 35 tracked files came to carry one installation's
internal infrastructure.

The split is therefore: *the product ships what the product runs*. A batch you drive by hand is yours.
