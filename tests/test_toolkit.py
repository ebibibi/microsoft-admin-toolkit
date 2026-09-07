"""Regression tests for evidence claims and catalogue discovery."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from tools import toolkit


class ToolkitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "script.ps1").write_text("Get-Something\n")
        (self.root / "README.md").write_text("runbook")
        self.entry = {
            "id": "inventory",
            "title": "Tenant inventory",
            "summary": "棚卸し",
            "path": "script.ps1",
            "runbook": "README.md",
            "permissions": "Read access",
            "areas": ["m365"],
            "tags": [],
            "dependencies": [],
            "tests": [],
            "evidence": [],
            "sources": [],
            "status": "legacy-unverified",
            "effect": "read-only",
        }
        self.save()
        self.write(
            "sources.json",
            {
                "version": 1,
                "sources": [
                    {
                        "id": "azure",
                        "title": "Azure samples",
                        "summary": "reference",
                        "url": "https://example.org/",
                        "license_note": "Review before adoption",
                    }
                ],
            },
        )

    def write(self, name: str, value: object) -> None:
        (self.root / name).write_text(json.dumps(value))

    def save(self) -> None:
        self.write("catalog.json", {"version": 1, "entries": [self.entry]})

    def evidence(self, scope: str = "lab") -> None:
        evidence = toolkit.template(self.root, "inventory", scope)
        evidence["outcome"] = "passed"
        self.write("evidence.json", evidence)
        self.entry["evidence"] = ["evidence.json"]
        self.save()

    def test_search_japanese_and_external_reference(self) -> None:
        self.assertEqual(toolkit.search(self.root, "棚卸し")[0]["id"], "inventory")
        self.assertEqual(toolkit.search(self.root, "azure")[0]["id"], "azure")
        self.assertEqual(toolkit.search(self.root, "no match"), [])

    def test_legacy_is_not_required_to_claim_verification(self) -> None:
        self.assertEqual(toolkit.validate(self.root), ([], []))

    def test_template_never_claims_success(self) -> None:
        self.assertEqual(
            toolkit.template(self.root, "inventory", "lab")["outcome"], "pending"
        )

    def test_offline_pass_cannot_establish_field_verification(self) -> None:
        self.evidence("offline")
        self.entry["status"] = "verified"
        self.save()
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_changed_code_invalidates_verified_claim(self) -> None:
        self.evidence()
        self.entry["status"] = "verified"
        self.save()
        self.assertFalse(toolkit.validate(self.root)[0])
        (self.root / "script.ps1").write_text("Different-Code\n")
        errors, warnings = toolkit.validate(self.root)
        self.assertTrue(errors)
        self.assertTrue(warnings)

    def test_declared_dependency_changes_invalidate_claim(self) -> None:
        (self.root / "helper.txt").write_text("v1")
        self.entry["dependencies"] = ["helper.txt"]
        self.save()
        self.evidence()
        self.entry["status"] = "verified"
        self.save()
        (self.root / "helper.txt").write_text("v2")
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_old_evidence_is_preserved_for_unverified_code(self) -> None:
        self.evidence()
        (self.root / "script.ps1").write_text("new revision")
        errors, warnings = toolkit.validate(self.root)
        self.assertFalse(errors)
        self.assertTrue(warnings)

    def test_missing_or_wrong_entry_evidence_rejected(self) -> None:
        self.evidence()
        e = toolkit.read_json(self.root / "evidence.json")
        e["entry_id"] = "different-entry"
        self.write("evidence.json", e)
        self.assertTrue(toolkit.validate(self.root)[0])
        (self.root / "evidence.json").unlink()
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_traversal_and_symlink_escape_rejected(self) -> None:
        for name in ("../outside", "/etc/passwd"):
            with self.assertRaises(ValueError):
                toolkit.local_file(self.root, name)
        (self.root / "escape").symlink_to("/etc/passwd")
        with self.assertRaises(ValueError):
            toolkit.local_file(self.root, "escape")

    def test_uncatalogued_script_is_detected(self) -> None:
        (self.root / "forgotten.ps1").write_text("Get-Other")
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_unknown_source_and_missing_runbook_rejected(self) -> None:
        self.entry["sources"] = ["missing"]
        self.save()
        self.assertTrue(toolkit.validate(self.root)[0])
        self.entry["sources"] = []
        self.entry["runbook"] = "missing.md"
        self.save()
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_recent_failed_result_revokes_old_verified_claim(self) -> None:
        self.evidence()
        failed = toolkit.read_json(self.root / "evidence.json")
        failed["outcome"] = "failed"
        self.write("failed.json", failed)
        self.entry["evidence"].append("failed.json")
        self.entry["status"] = "verified"
        self.save()
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_changed_runbook_invalidates_verified_claim(self) -> None:
        self.evidence()
        self.entry["status"] = "verified"
        self.save()
        (self.root / "README.md").write_text("changed conditions")
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_missing_id_and_malformed_catalog_are_rejected(self) -> None:
        del self.entry["id"]
        self.save()
        self.assertTrue(toolkit.validate(self.root)[0])
        self.write("catalog.json", [])
        self.assertTrue(toolkit.validate(self.root)[0])

    def test_duplicate_entries_rejected(self) -> None:
        self.write("catalog.json", {"version": 1, "entries": [self.entry, self.entry]})
        self.assertTrue(toolkit.validate(self.root)[0])


if __name__ == "__main__":
    unittest.main()
