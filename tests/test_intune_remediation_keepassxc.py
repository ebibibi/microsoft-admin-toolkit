"""Offline checks for Intune/Remediations/KeePassXCUpdate.

The release selection logic runs under pwsh when available. Installing, the
signature check and the startup task need Windows and are recorded in evidence.
"""
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

FOLDER = Path(__file__).resolve().parents[1] / "Intune" / "Remediations" / "KeePassXCUpdate"
PWSH = shutil.which("pwsh")
SHA = "a" * 64


def release(tag, published, label="x64", digest=f"sha256:{SHA}", **extra):
    asset = {"name": f"KeePassXC-{tag}-{label}.msi", "browser_download_url": f"https://example.invalid/{tag}"}
    if digest:
        asset["digest"] = digest
    return {"tag_name": tag, "published_at": published, "draft": False, "prerelease": False,
            "assets": [asset], **extra}


def select(releases, arch="AMD64", now="2026-11-05T00:00:00Z", min_age=3):
    script = FOLDER / "Detect.ps1"
    command = (
        f"$ast = [System.Management.Automation.Language.Parser]::ParseFile('{script}', [ref]$null, [ref]$null);"
        "$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]"
        " -and $n.Name -eq 'Select-TargetRelease' }, $true);"
        ". ([scriptblock]::Create($fn.Extent.Text));"
        "$r = @($input | Out-String | ConvertFrom-Json -NoEnumerate);"
        f"$t = Select-TargetRelease -Releases $r[0] -Arch '{arch}' -Now ([datetime]'{now}') -MinAgeDays {min_age};"
        "if ($t) { '{0}|{1}|{2}' -f $t.Version, $t.Name, $t.Sha256 } else { 'none' }"
    )
    result = subprocess.run([PWSH, "-NoProfile", "-Command", command], input=json.dumps(releases),
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    return result.stdout.strip()


@unittest.skipUnless(PWSH, "pwsh not installed")
class SelectTargetReleaseTests(unittest.TestCase):
    def test_picks_newest_old_enough_release(self):
        out = select([release("2.8.0", "2026-10-21T00:00:00Z"), release("2.7.12", "2026-03-01T00:00:00Z", "Win64")])
        self.assertEqual(out, f"2.8.0|KeePassXC-2.8.0-x64.msi|{SHA}")

    def test_compares_versions_numerically(self):
        out = select([release("2.7.9", "2026-01-01T00:00:00Z"), release("2.7.12", "2026-03-01T00:00:00Z")])
        self.assertTrue(out.startswith("2.7.12|"))

    def test_release_inside_soak_period_falls_back(self):
        out = select([release("2.8.1", "2026-11-04T00:00:00Z"), release("2.8.0", "2026-10-21T00:00:00Z")])
        self.assertTrue(out.startswith("2.8.0|"))

    def test_skips_prerelease_draft_and_odd_tags(self):
        out = select([
            release("2.9.0", "2026-10-01T00:00:00Z", prerelease=True),
            {**release("2.8.5", "2026-10-01T00:00:00Z"), "draft": True},
            release("2.8.4-beta1", "2026-10-01T00:00:00Z"),
            release("2.8.0", "2026-09-01T00:00:00Z"),
        ])
        self.assertTrue(out.startswith("2.8.0|"))

    def test_skips_release_without_a_valid_digest(self):
        for digest in (None, "md5:abc", "sha256:xyz"):
            out = select([release("2.8.0", "2026-10-21T00:00:00Z", digest=digest)])
            self.assertEqual(out, "none", digest)

    def test_uses_the_asset_for_the_architecture(self):
        arm = release("2.8.0", "2026-10-21T00:00:00Z", "ARM64")
        self.assertEqual(select([arm], arch="AMD64"), "none")
        self.assertTrue(select([arm], arch="ARM64").startswith("2.8.0|KeePassXC-2.8.0-ARM64.msi"))

    def test_accepts_the_legacy_win64_asset_name(self):
        out = select([release("2.7.12", "2026-03-01T00:00:00Z", "Win64")])
        self.assertIn("KeePassXC-2.7.12-Win64.msi", out)


class ScriptTextTests(unittest.TestCase):
    def setUp(self):
        self.detect = (FOLDER / "Detect.ps1").read_text(encoding="utf-8")
        self.remediate = (FOLDER / "Remediate.ps1").read_text(encoding="utf-8")

    @staticmethod
    def block(text, name):
        match = re.search(rf"^function {name} \{{.*?^\}}", text, re.S | re.M)
        assert match, name
        return match.group(0)

    def test_shared_code_is_identical(self):
        for name in ("Get-InstalledVersion", "Select-TargetRelease"):
            self.assertEqual(self.block(self.detect, name), self.block(self.remediate, name))
        for constant in (r"\$ReleasesApi = .*", r"\$MinReleaseAgeDays = .*"):
            self.assertEqual(re.search(constant, self.detect).group(0), re.search(constant, self.remediate).group(0))

    def test_never_closes_a_running_app(self):
        self.assertNotIn("Stop-Process", self.remediate)
        self.assertNotIn("taskkill", self.remediate.lower())

    def test_treats_browser_proxy_as_running(self):
        self.assertIn("keepassxc-proxy", self.remediate)

    def test_checks_before_any_install(self):
        self.assertIn("DroidMonkey Apps, LLC", self.remediate)
        body = self.remediate[self.remediate.index("\ntry {"):]
        self.assertLess(body.index("Assert-VcRuntime"), body.index("Get-CheckedMsi"))
        self.assertLess(body.index("Get-CheckedMsi"), body.index("Start-Process msiexec"))
        self.assertLess(body.index("Get-CheckedMsi"), body.index("Register-StartupInstall"))

    def test_work_folder_is_locked_down(self):
        block = self.block(self.remediate, "Initialize-WorkDir")
        self.assertIn("SetAccessRuleProtection($true, $false)", block)
        self.assertIn("'S-1-5-18', 'S-1-5-32-544'", block)

    def test_startup_task_runs_on_battery_and_cleans_up(self):
        block = self.block(self.remediate, "Register-StartupInstall")
        self.assertIn("-AllowStartIfOnBatteries", block)
        self.assertIn("schtasks.exe /Delete", block)
        self.assertIn('del /q', block)

    def test_scripts_are_ascii(self):
        self.detect.encode("ascii")
        self.remediate.encode("ascii")


if __name__ == "__main__":
    unittest.main()
