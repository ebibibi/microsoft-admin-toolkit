"""Offline checks for EntraID/GraphReadOnlyApp/New-GraphReadOnlyApp.sh.

Only the argument and permission validation is exercised. Those run before the
script contacts Azure, so they are testable without a tenant. Nothing here proves
the script works against a directory; see the evidence record for that.

The display-name collision guard is not covered here because it needs a directory
to query; it is recorded in the evidence file instead.
"""
import os
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "EntraID", "GraphReadOnlyApp", "New-GraphReadOnlyApp.sh")


class GraphReadOnlyAppScriptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temp = tempfile.NamedTemporaryFile(suffix=".crt", delete=False)
        cls._temp.write(b"not a real certificate")
        cls._temp.close()
        cls.certificate = cls._temp.name

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.certificate)

    def run_script(self, *args):
        return subprocess.run(
            ["bash", SCRIPT, *args],
            capture_output=True,
            text=True,
            env={**os.environ, "AZURE_CONFIG_DIR": "/nonexistent-azure-config"},
        )

    def test_script_is_syntactically_valid(self):
        result = subprocess.run(["bash", "-n", SCRIPT], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_required_arguments_exit_with_usage(self):
        result = self.run_script("--display-name", "Example")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)

    def test_missing_certificate_file_is_reported(self):
        result = self.run_script(
            "--display-name", "Example", "--certificate", "/nonexistent/cert.crt"
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Certificate not found", result.stderr)

    def test_write_permission_without_write_in_the_name_is_refused(self):
        """Mail.Send grants write access but matches no write-looking substring."""
        result = self.run_script(
            "--display-name", "Example",
            "--certificate", self.certificate,
            "--permission", "Mail.Send",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("not a recognised read form", result.stderr)

    def test_readbasic_permissions_are_allowed(self):
        result = self.run_script(
            "--display-name", "Example",
            "--certificate", self.certificate,
            "--permission", "Mail.ReadBasic.All",
            "--dry-run",
        )
        self.assertNotIn("Refusing permission", result.stderr)

    def test_unknown_app_id_is_reported(self):
        """Naming a non-existent application must fail before any credential write."""
        result = self.run_script(
            "--app-id", "00000000-0000-0000-0000-000000000000",
            "--certificate", self.certificate,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_readwrite_permission_is_refused(self):
        result = self.run_script(
            "--display-name", "Example",
            "--certificate", self.certificate,
            "--permission", "Directory.ReadWrite.All",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing permission", result.stderr)

    def test_full_control_permission_is_refused(self):
        result = self.run_script(
            "--display-name", "Example",
            "--certificate", self.certificate,
            "--permission", "Sites.FullControl.All",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 1)

    def test_read_permissions_containing_management_are_allowed(self):
        """DeviceManagementManagedDevices.Read.All must not trip the filter."""
        result = self.run_script(
            "--display-name", "Example",
            "--certificate", self.certificate,
            "--permission", "DeviceManagementManagedDevices.Read.All",
            "--dry-run",
        )
        self.assertNotIn("Refusing permission", result.stderr)


if __name__ == "__main__":
    unittest.main()
