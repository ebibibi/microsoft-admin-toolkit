"""Static checks for Intune/Remediations/NodeJsMsiUpdate (scripts are never executed)."""
import unittest
from pathlib import Path

FOLDER = Path(__file__).resolve().parents[1] / "Intune" / "Remediations" / "NodeJsMsiUpdate"


class NodeJsMsiUpdateTests(unittest.TestCase):
    def setUp(self):
        self.detect = (FOLDER / "Detect.ps1").read_text(encoding="utf-8-sig")
        self.remediate = (FOLDER / "Remediate.ps1").read_text(encoding="utf-8-sig")

    def test_stays_in_installed_major_line(self):
        for text in (self.detect, self.remediate):
            self.assertIn("https://nodejs.org/dist/index.json", text)
            self.assertIn('"^v$Major\\.\\d+\\.\\d+$"', text)
            self.assertIn("Get-LatestInLine $installed.Major", text)

    def test_remediation_verifies_hash_and_signature(self):
        self.assertIn("SHASUMS256.txt", self.remediate)
        self.assertIn("Get-FileHash", self.remediate)
        self.assertIn("OpenJS Foundation", self.remediate)

    def test_does_not_install_when_absent(self):
        self.assertIn("if (-not $node) { Write-Output 'Node.js (MSI) not installed.'; exit 0 }", self.remediate)
        self.assertIn("not installed - nothing to update.'; exit 0 }", self.detect)

    def test_scripts_are_ascii(self):
        for text in (self.detect, self.remediate):
            text.encode("ascii")


if __name__ == "__main__":
    unittest.main()
