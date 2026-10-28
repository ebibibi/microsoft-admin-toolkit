import importlib.util
import json
import unittest
import zipfile
import io
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("deploy_win32_app", ROOT / "Intune/tools/deploy_win32_app.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
MANIFEST = ROOT / "Intune/Win32Apps/CloudflareOneClient/app.json"


class Win32AppTests(unittest.TestCase):
    def test_encrypt_roundtrip_and_layout(self):
        plain = mod.zip_folder({"setup.msi": b"x" * 1000})
        blob, info = mod.encrypt_content(plain)
        self.assertEqual(len(blob), 32 + 16 + ((len(plain) // 16) + 1) * 16)
        self.assertEqual(mod.decrypt_content(blob, info), plain)
        self.assertEqual(info["profileIdentifier"], "ProfileVersion1")
        self.assertEqual(info["fileDigestAlgorithm"], "SHA256")

    def test_tampered_content_is_rejected(self):
        blob, info = mod.encrypt_content(b"hello")
        bad = blob[:-1] + bytes([blob[-1] ^ 1])
        with self.assertRaises(ValueError):
            mod.decrypt_content(bad, info)

    def test_zip_contains_installer_at_root(self):
        plain = mod.zip_folder({"Cloudflare_WARP.msi": b"msi"})
        with zipfile.ZipFile(io.BytesIO(plain)) as z:
            self.assertEqual(z.namelist(), ["Cloudflare_WARP.msi"])

    def test_manifest_and_params(self):
        app = mod.apply_params(mod.load_manifest(MANIFEST), ["ORGANIZATION=example"])
        self.assertIn('ORGANIZATION="example"', app["installCommandLine"])
        with self.assertRaises(ValueError):
            mod.apply_params(mod.load_manifest(MANIFEST), [])
        with self.assertRaises(ValueError):
            mod.apply_params(mod.load_manifest(MANIFEST), ['ORGANIZATION=a" /x'])

    def test_bodies(self):
        app = mod.apply_params(mod.load_manifest(MANIFEST), ["ORGANIZATION=example"])
        body = mod.build_app_body(app, "Cloudflare_WARP.intunewin")
        self.assertEqual(body["@odata.type"], "#microsoft.graph.win32LobApp")
        self.assertEqual(body["setupFilePath"], "Cloudflare_WARP.msi")
        rule = body["detectionRules"][0]
        self.assertEqual(rule["@odata.type"], "#microsoft.graph.win32LobAppFileSystemDetection")
        self.assertEqual(rule["fileOrFolderName"], "warp-svc.exe")
        assign = mod.build_assignment_body("00000000-0000-0000-0000-000000000000", "required")
        self.assertEqual(assign["mobileAppAssignments"][0]["intent"], "required")
        with self.assertRaises(ValueError):
            mod.build_assignment_body("x", "uninstall-everything")


if __name__ == "__main__":
    unittest.main()
