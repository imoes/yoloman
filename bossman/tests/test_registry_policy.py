"""The declared registry value, and the conflict report against Group Policy.

The report exists for one sentence — "Group Policy sets AUOptions = 3, you declare 4, the GPO wins" — and
these tests are mostly about the three outcomes that are NOT that sentence, because a report that calls
everything a conflict is a report people switch off.
"""

from bossman.services.registry_policy import canonical_key, conflicts, declared_values


class TestCanonicalKey:
    def test_the_two_spellings_of_one_key_resolve_to_one(self):
        # An operator types HKLM:\…; the agent reports HKEY_LOCAL_MACHINE\…. A comparison that treated them
        # as different keys would silently find no conflicts at all — the worst outcome for this feature,
        # because it looks like good news.
        assert canonical_key(r"HKLM:\SOFTWARE\Contoso") == r"HKEY_LOCAL_MACHINE\SOFTWARE\Contoso"
        assert canonical_key(r"HKEY_LOCAL_MACHINE\SOFTWARE\Contoso") == r"HKEY_LOCAL_MACHINE\SOFTWARE\Contoso"

    def test_every_hive_abbreviation(self):
        assert canonical_key(r"HKCU:\X") == r"HKEY_CURRENT_USER\X"
        assert canonical_key(r"HKCR:\X") == r"HKEY_CLASSES_ROOT\X"
        assert canonical_key(r"HKU:\X") == r"HKEY_USERS\X"
        assert canonical_key(r"HKCC:\X") == r"HKEY_CURRENT_CONFIG\X"

    def test_slashes_and_trailing_separators_do_not_make_a_second_key(self):
        assert canonical_key("HKLM:/SOFTWARE/Contoso/") == canonical_key(r"HKLM:\SOFTWARE\Contoso")

    def test_case_is_preserved_because_a_report_is_read_by_people(self):
        # Windows does not care; a reader does. Folding happens in the comparison, where it belongs.
        assert canonical_key(r"HKLM:\SOFTWARE\CamelCase") == r"HKEY_LOCAL_MACHINE\SOFTWARE\CamelCase"


class TestDeclaredValues:
    def test_a_registry_resource_yields_one_row_per_value_with_its_winning_scope(self):
        resources = [{
            "path": r"HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU",
            "source": "OU:/berlin",
            "key_sources": {"AUOptions": "host", "NoAutoUpdate": "OU:/berlin"},
            "resource": {"type": "registry", "values": {
                "AUOptions": {"type": "dword", "data": 4},
                "NoAutoUpdate": {"type": "dword", "data": 0},
            }},
        }]
        got = declared_values(resources)
        assert len(got) == 2
        au = next(v for v in got if v["name"] == "AUOptions")
        # THE PER-KEY source, not the resource's overall one: a merged resource whose report named only the
        # strongest contributor would hide where an individual value came from.
        assert au["source"] == "host"
        assert au["type"] == "dword" and au["value"] == 4
        assert next(v for v in got if v["name"] == "NoAutoUpdate")["source"] == "OU:/berlin"

    def test_file_resources_are_skipped(self):
        resources = [{"path": "/etc/nginx/nginx.conf", "resource": {"type": "config", "values": {"worker": 4}}}]
        assert declared_values(resources) == []

    def test_a_bare_scalar_keeps_its_value_and_states_no_type(self):
        # An operator who wrote {"Foo": 1} has said what they mean; the agent's registry module refuses to
        # guess a type it was not given, so the report must not invent one either.
        got = declared_values([{"path": r"HKLM:\SOFTWARE\X", "resource": {"type": "registry",
                                                                          "values": {"Foo": 1}}}])
        assert got[0]["value"] == 1 and got[0]["type"] is None


class TestConflicts:
    IMPOSED = [
        {"path": r"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU",
         "name": "AUOptions", "type": "DWord", "value": "3"},
        {"path": r"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\TPM",
         "name": "OSManagedAuthLevel", "type": "DWord", "value": "5"},
    ]

    def declared(self, path, name, value, typ="dword"):
        return [{"path": path, "name": name, "type": typ, "value": value, "source": "host"}]

    def test_the_finding_the_report_exists_for(self):
        got = conflicts(
            self.declared(r"HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU", "AUOptions", 4),
            self.IMPOSED)
        assert got["conflict_count"] == 1
        row = got["overridden"][0]
        assert row["gp_value"] == "3" and row["value"] == 4
        # The explanation has to say WHAT WILL HAPPEN, not just that two numbers differ: the convergence run
        # will write ours and find it reverted, on every pass.
        assert "every pass" in row["explanation"]
        # With the area as the source, the author is NOT named as Group Policy — we cannot know that from a
        # read of a shared registry area, and claiming it would be a guess dressed as a finding.
        assert "Another authority" in row["explanation"]
        assert got["imposed_source"] == "registry-policy-area" and got["imposed_names_author"] is False

    def test_a_matching_value_is_not_reported_as_group_policy_agreeing(self):
        """The self-confirmation trap: after we apply our own declaration, the policy area holds OUR value.

        Calling that "Group Policy agrees with us" would make the report confirm itself — it would have found
        agreement with the value it just wrote. So a match is recorded as `same_value` and its explanation
        says explicitly what it does and does not prove."""
        got = conflicts(
            self.declared(r"HKLM:\SOFTWARE\Policies\Microsoft\TPM", "OSManagedAuthLevel", 5),
            self.IMPOSED)
        assert got["conflict_count"] == 0
        assert len(got["same_value"]) == 1
        assert "NOT proof" in got["same_value"][0]["explanation"]

    def test_a_source_that_names_the_author_may_claim_agreement(self):
        """Same data, a source that CAN name the author (RSoP extension data) — then the caveat is dropped.

        Kept as a test rather than as a promise: the day gpresult provides per-setting data on a host, the
        report's wording must strengthen without anything else changing."""
        from bossman.services.registry_policy import IMPOSED_SOURCE_RSOP

        got = conflicts(
            self.declared(r"HKLM:\SOFTWARE\Policies\Microsoft\TPM", "OSManagedAuthLevel", 5),
            self.IMPOSED, IMPOSED_SOURCE_RSOP)
        assert got["imposed_names_author"] is True
        assert "NOT proof" not in got["same_value"][0]["explanation"]

    def test_a_declaration_in_gp_territory_that_no_gpo_claims_yet(self):
        got = conflicts(
            self.declared(r"HKLM:\SOFTWARE\Policies\Contoso\App", "Mode", "strict"),
            self.IMPOSED)
        assert got["conflict_count"] == 0
        assert len(got["in_gp_scope"]) == 1
        assert "next policy refresh can claim it" in got["in_gp_scope"][0]["explanation"]

    def test_a_normal_declaration_is_counted_not_listed(self):
        got = conflicts(self.declared(r"HKLM:\SOFTWARE\Contoso\App", "Mode", "strict"), self.IMPOSED)
        assert got == {**got, "ours_alone": 1, "conflict_count": 0}
        assert got["overridden"] == [] and got["in_gp_scope"] == []

    def test_the_comparison_is_case_insensitive_like_windows(self):
        got = conflicts(
            self.declared(r"hklm:\software\policies\microsoft\tpm", "osmanagedauthlevel", 9),
            self.IMPOSED)
        assert got["conflict_count"] == 1, "a case difference must not hide a real conflict"

    def test_a_dword_3_and_the_string_3_are_not_reported_as_a_conflict(self):
        # Both sides report a string; claiming a type conflict on that basis would produce findings that are
        # not real, and this report's credibility is its only feature.
        got = conflicts(
            self.declared(r"HKLM:\SOFTWARE\Policies\Microsoft\TPM", "OSManagedAuthLevel", "5", typ="string"),
            self.IMPOSED)
        assert got["conflict_count"] == 0 and len(got["same_value"]) == 1

    def test_nothing_declared_reports_nothing_rather_than_success(self):
        got = conflicts([], self.IMPOSED)
        assert got["declared_total"] == 0 and got["conflict_count"] == 0
        assert got["imposed_total"] == 2, "the imposed count must still be visible: zero conflicts against " \
                                          "zero declarations is not good news, it is no question asked"
