"""Offline guard checks; these do not establish Windows execution success."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest


SCRIPT = (Path(__file__).resolve().parents[1] / 'Intune' / 'Remediations'
          / 'TargetedExposureBaseline' / 'Invoke-Baseline.ps1')


@unittest.skipUnless(shutil.which('pwsh'), 'PowerShell is required')
class TargetGuardTests(unittest.TestCase):
    def test_wrong_device_aborts_before_registry_access(self) -> None:
        result = subprocess.run(
            ['pwsh', '-NoLogo', '-NoProfile', '-File', str(SCRIPT),
             '-ExpectedComputerName', 'different-device', '-Mode', 'Remediate'],
            env={**os.environ, 'COMPUTERNAME': 'test-device'},
            capture_output=True, text=True, check=False, timeout=30,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), 'Target guard failed; no changes made.')
        self.assertEqual(result.stderr, '')

    @unittest.skipIf(os.name == 'nt', 'This check requires a non-Windows host')
    def test_matching_name_on_non_windows_still_aborts(self) -> None:
        result = subprocess.run(
            ['pwsh', '-NoLogo', '-NoProfile', '-File', str(SCRIPT),
             '-ExpectedComputerName', 'test-device', '-Mode', 'Remediate'],
            env={**os.environ, 'COMPUTERNAME': 'test-device'},
            capture_output=True, text=True, check=False, timeout=30,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), '64-bit Windows PowerShell is required.')
        self.assertEqual(result.stderr, '')


class WindowsPowerShell51PatternTests(unittest.TestCase):
    """Static checks for 5.1-specific pitfalls that pwsh 7 cannot reproduce."""

    def setUp(self) -> None:
        self.text = SCRIPT.read_text(encoding='utf-8-sig')

    def test_backup_array_is_enumerated_before_counting(self) -> None:
        self.assertIn('ConvertFrom-Json | ForEach-Object { $_ })', self.text)
        self.assertNotRegex(self.text, r'@\([^)]*ConvertFrom-Json\)')

    def test_existing_registry_keys_are_not_recreated(self) -> None:
        for line in self.text.splitlines():
            if 'New-Item -Path $s.Path' in line:
                self.assertIn('if (-not (Test-Path -LiteralPath $s.Path))', line)

    def test_failure_is_reported_on_stderr(self) -> None:
        self.assertIn('[Console]::Error.WriteLine($message)', self.text)
