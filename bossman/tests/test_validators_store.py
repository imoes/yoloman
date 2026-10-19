"""package_validators.json has two writers (the LLM miner, the probe). Each used to write back the copy it loaded at
start, and the miner erased 69 probe decisions (2026-10-16). Every write now reloads under a lock and changes one entry."""

import json
import threading

from bossman.tools import validators_store as VS


def test_two_writers_with_old_copies_lose_nothing(tmp_path):
    path = tmp_path / "package_validators.json"
    path.write_text(json.dumps({"debian": {"kannel": {"check_cmd": "bearerbox {path}", "status": "ok"}}}))
    # The probe rejects kannel while the miner, started earlier, adds another package.
    VS.update(lambda d: d["debian"]["kannel"].update(status="rejected"), path)
    VS.update(lambda d: d["debian"].__setitem__("zsh", {"check_cmd": "zsh -n {path}", "status": "ok"}), path)
    doc = VS.load(path)
    assert doc["debian"]["kannel"]["status"] == "rejected" and "zsh" in doc["debian"]


def test_concurrent_updates_all_land(tmp_path):
    path = tmp_path / "package_validators.json"
    path.write_text("{}")
    threads = [threading.Thread(target=VS.update, args=(lambda d, i=i: d.setdefault("x", {}).__setitem__(str(i), {}),
                                                         path)) for i in range(40)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(VS.load(path)["x"]) == 40


def test_decided_means_judged_on_a_test_host():
    assert VS.decided({"source": "verified by probe 2026-10-14"})
    assert VS.decided({"source": "verified by hand 2026-10-11"})
    assert VS.decided({"status": "rejected"})
    assert not VS.decided({"status": "ok", "source": ""})       # a model's guess
    assert not VS.decided(None)
