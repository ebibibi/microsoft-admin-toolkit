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
