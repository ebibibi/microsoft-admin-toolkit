"""Offline checks for Intune/Remediations and Intune/tools/deploy_remediations.py.

PowerShell checks run the helper functions extracted from the scripts with pwsh
(skipped when pwsh is absent). They prove parsing and the pure logic only: the
scripts touch the registry, OneDrive and Windows shell, which need a Windows
device and are recorded in evidence, not here.
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
REMEDIATIONS = REPO_ROOT / "Intune" / "Remediations"
sys.path.insert(0, str(REPO_ROOT / "Intune" / "tools"))

import deploy_remediations as deploy  # noqa: E402

PWSH = shutil.which("pwsh")


def run_function(script: Path, function: str, call: str) -> str:
    """Define one function from a script via the PowerShell AST, then run `call`."""
    command = (
        "$ast = [System.Management.Automation.Language.Parser]::ParseFile("
        f"'{script}', [ref]$null, [ref]$null);"
        "$fn = $ast.Find({ param($n) $n -is "
        "[System.Management.Automation.Language.FunctionDefinitionAst] -and "
        f"$n.Name -eq '{function}' }}, $true);"
        ". ([scriptblock]::Create($fn.Extent.Text));"
        f"{call}"
    )
    result = subprocess.run([PWSH, "-NoProfile", "-Command", command], capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


class ManifestTest(unittest.TestCase):
    def test_manifest_folders_have_script_pairs(self):
        items = deploy.load_manifest(REMEDIATIONS / "remediations.json")
        for item in items:
            for name in ("Detect.ps1", "Remediate.ps1"):
                self.assertTrue((REMEDIATIONS / item["folder"] / name).is_file(), item["folder"])

    def test_rejects_invalid_run_as(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "m.json"
            path.write_text(json.dumps({"remediations": [
                {"folder": "x", "displayName": "x", "description": "x", "runAsAccount": "admin"}]}))
            with self.assertRaises(ValueError):
                deploy.load_manifest(path)

    def test_script_body_encodes_both_scripts(self):
        item = deploy.load_manifest(REMEDIATIONS / "remediations.json")[0]
        body = deploy.build_script_body(item, REMEDIATIONS, "MySetup - ", "me")
        self.assertTrue(body["displayName"].startswith("MySetup - "))
        detect = (REMEDIATIONS / item["folder"] / "Detect.ps1").read_bytes()
        self.assertEqual(base64.b64decode(body["detectionScriptContent"]), detect)
        self.assertFalse(body["runAs32Bit"])

    def test_assignment_body(self):
        body = deploy.build_assignment_body("g1", 4)
        entry = body["deviceHealthScriptAssignments"][0]
        self.assertEqual(entry["target"]["groupId"], "g1")
        self.assertEqual(entry["runSchedule"]["interval"], 4)
        with self.assertRaises(ValueError):
            deploy.build_assignment_body("g1", 0)


class ScriptTextTest(unittest.TestCase):
    def test_scripts_are_ascii(self):
        # Windows PowerShell 5.1 reads BOM-less files as ANSI; keep the text ASCII
        # so the encoding never matters. A UTF-8 BOM is allowed.
        for script in REMEDIATIONS.rglob("*.ps1"):
            script.read_bytes().removeprefix(b"\xef\xbb\xbf").decode("ascii")

    def test_manifest_scripts_do_not_read_personal_onedrive(self):
        # What a managed device runs must not depend on whether a consumer
        # OneDrive happens to be signed in (OneDriveConsumer is set only then).
        for item in deploy.load_manifest(REMEDIATIONS / "remediations.json"):
            for name in ("Detect.ps1", "Remediate.ps1"):
                text = (REMEDIATIONS / item["folder"] / name).read_text(encoding="utf-8-sig")
                self.assertNotIn("OneDriveConsumer", text, f"{item['folder']}/{name}")


@unittest.skipUnless(PWSH, "pwsh not installed")
class PowerShellTest(unittest.TestCase):
    def test_scripts_parse(self):
        for script in REMEDIATIONS.rglob("*.ps1"):
            out = subprocess.run(
                [PWSH, "-NoProfile", "-Command",
                 "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("
                 f"'{script}', [ref]$null, [ref]$e); $e.Count"],
                capture_output=True, text=True)
            self.assertEqual(out.stdout.strip(), "0", f"{script}: {out.stderr}")

    def test_scancode_map_bytes(self):
        for name in ("Detect.ps1", "Remediate.ps1"):
            out = run_function(
                REMEDIATIONS / "KeyboardScancodeSwap" / name, "ConvertTo-ScancodeMap",
                "$m = ConvertTo-ScancodeMap -Map @(@{From=0x003A;To=0xE01D},@{From=0xE01D;To=0x003A}); "
                "($m | ForEach-Object { '{0:x2}' -f $_ }) -join ','")
            self.assertEqual(
                out, "00,00,00,00,00,00,00,00,03,00,00,00,1d,e0,3a,00,3a,00,1d,e0,00,00,00,00", name)

    def test_default_mapping_is_capslock_to_right_ctrl_only(self):
        # Must equal the long-used .reg: hex:00,00,00,00,00,00,00,00,02,00,00,00,1D,E0,3A,00,00,00,00,00
        for name in ("Detect.ps1", "Remediate.ps1"):
            script = REMEDIATIONS / "KeyboardScancodeSwap" / name
            text = script.read_text(encoding="utf-8-sig")
            start = text.index("$Mappings = @(")
            block = text[start:text.index("\n)", start) + 2]
            out = run_function(script, "ConvertTo-ScancodeMap",
                               block + "; $m = ConvertTo-ScancodeMap -Map $Mappings; "
                               "($m | ForEach-Object { '{0:x2}' -f $_ }) -join ','")
            self.assertEqual(out, "00,00,00,00,00,00,00,00,02,00,00,00,1d,e0,3a,00,00,00,00,00", name)

    def _set_ctrl_side(self, text: str) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config_personal.py"
            path.write_text(text, encoding="utf-8")
            run_function(REMEDIATIONS / "KeyhacFakeymacs" / "Remediate.ps1", "Set-CtrlSide",
                         f"[void](Set-CtrlSide -Path '{path}' -Side 'R')")
            result = path.read_text(encoding="utf-8")
            side = run_function(REMEDIATIONS / "KeyhacFakeymacs" / "Detect.ps1", "Get-CtrlSide",
                                f"Get-CtrlSide -Path '{path}'")
            self.assertEqual(side, "R")
            return result

    def test_ctrl_side_replaces_active_assignment_only(self):
        out = self._set_ctrl_side(
            '# [section-base-1] ---\nfc.side_of_ctrl_key = "L"\n# fc.side_of_ctrl_key = "R"\n')
        self.assertIn('\nfc.side_of_ctrl_key = "R"\n# fc.side_of_ctrl_key = "R"\n', out)
        self.assertNotIn('"L"', out)

    def test_ctrl_side_inserted_after_section_header(self):
        out = self._set_ctrl_side("# [section-base-1] ---\nfc.debug = False\n")
        self.assertEqual(out, '# [section-base-1] ---\nfc.side_of_ctrl_key = "R"\nfc.debug = False\n')

    def test_ctrl_side_appends_section_when_missing(self):
        out = self._set_ctrl_side("# [section-init] ---\nprint(1)\n")
        self.assertTrue(out.endswith('# [section-base-1] ---\nfc.side_of_ctrl_key = "R"\n'))

    def test_ctrl_side_preserves_japanese_text(self):
        out = self._set_ctrl_side('# [section-base-1] ---\n# 左右どちら\nfc.side_of_ctrl_key = "L"\n')
        self.assertIn("左右どちら", out)


if __name__ == "__main__":
    unittest.main()
