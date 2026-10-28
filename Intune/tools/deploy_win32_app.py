#!/usr/bin/env python3
"""Package an installer as an Intune Win32 app, upload it and assign it, from Linux.

Reads an app manifest (Intune/Win32Apps/<App>/app.json), downloads the installer,
verifies its SHA-256, builds the encrypted Intune content in-process (no
IntuneWinAppUtil.exe), creates or updates the win32LobApp, uploads the content
to the Azure Storage URI that Intune issues, commits it and assigns the app to
one Entra group.

The caller supplies a delegated or application Microsoft Graph access token in
GRAPH_ACCESS_TOKEN. Required: an Intune role that can manage apps and
DeviceManagementApps.ReadWrite.All. Use --dry-run to build and verify the
package and print the request bodies without calling Graph.

Content format (what IntuneWinAppUtil produces and Intune decrypts):
  plaintext = ZIP of the source folder
  encrypted = HMAC-SHA256(macKey, iv || ciphertext) || iv || AES-256-CBC-PKCS7(plaintext)
  fileEncryptionInfo carries encryptionKey, macKey, iv, mac and SHA-256(plaintext).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

GRAPH = "https://graph.microsoft.com/beta"
BLOCK = 6 * 1024 * 1024
DETECTION_TYPES = {"file", "msi"}


# ---------- manifest ----------

def load_manifest(path: Path) -> dict:
    app = json.loads(path.read_text(encoding="utf-8"))
    for key in ("displayName", "publisher", "description", "installer", "installCommandLine",
                "uninstallCommandLine", "detection"):
        if not app.get(key):
            raise ValueError(f"manifest missing {key}")
    inst = app["installer"]
    for key in ("url", "fileName", "sha256"):
        if not inst.get(key):
            raise ValueError(f"installer missing {key}")
    if len(inst["sha256"]) != 64:
        raise ValueError("installer.sha256 must be a hex SHA-256")
    det = app["detection"]
    if det.get("type") not in DETECTION_TYPES:
        raise ValueError(f"detection.type must be one of {sorted(DETECTION_TYPES)}")
    if inst["fileName"] not in app["installCommandLine"]:
        raise ValueError("installCommandLine must reference installer.fileName")
    return app


def apply_params(app: dict, params: list[str]) -> dict:
    values = {}
    for p in params:
        key, sep, value = p.partition("=")
        if not sep or not key:
            raise ValueError(f"--param must be KEY=VALUE: {p}")
        if '"' in value:
            raise ValueError("parameter values must not contain double quotes")
        values[key] = value
    out = dict(app)
    for field in ("installCommandLine", "uninstallCommandLine"):
        text = out[field]
        for key, value in values.items():
            text = text.replace("{{" + key + "}}", value)
        if "{{" in text:
            raise ValueError(f"{field} still has unfilled placeholders: {text}")
        out[field] = text
    return out


# ---------- package ----------

def zip_folder(files: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            z.writestr(name, files[name])
    return buf.getvalue()


def encrypt_content(plain: bytes, enc_key: bytes | None = None, mac_key: bytes | None = None,
                    iv: bytes | None = None) -> tuple[bytes, dict]:
    enc_key = enc_key or os.urandom(32)
    mac_key = mac_key or os.urandom(32)
    iv = iv or os.urandom(16)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plain) + padder.finalize()
    enc = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    cipher = enc.update(padded) + enc.finalize()
    mac = hmac.new(mac_key, iv + cipher, hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode("ascii")  # noqa: E731
    info = {
        "encryptionKey": b64(enc_key),
        "macKey": b64(mac_key),
        "initializationVector": b64(iv),
        "mac": b64(mac),
        "profileIdentifier": "ProfileVersion1",
        "fileDigest": b64(hashlib.sha256(plain).digest()),
        "fileDigestAlgorithm": "SHA256",
    }
    return mac + iv + cipher, info


def decrypt_content(blob: bytes, info: dict) -> bytes:
    """Inverse of encrypt_content; used by tests and --dry-run self-checks."""
    mac, iv, cipher = blob[:32], blob[32:48], blob[48:]
    mac_key = base64.b64decode(info["macKey"])
    if not hmac.compare_digest(mac, hmac.new(mac_key, iv + cipher, hashlib.sha256).digest()):
        raise ValueError("HMAC mismatch")
    dec = Cipher(algorithms.AES(base64.b64decode(info["encryptionKey"])), modes.CBC(iv)).decryptor()
    padded = dec.update(cipher) + dec.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    plain = unpadder.update(padded) + unpadder.finalize()
    if base64.b64encode(hashlib.sha256(plain).digest()).decode() != info["fileDigest"]:
        raise ValueError("digest mismatch")
    return plain


# ---------- request bodies ----------

def detection_rule(det: dict) -> dict:
    if det["type"] == "file":
        return {
            "@odata.type": "#microsoft.graph.win32LobAppFileSystemDetection",
            "path": det["path"],
            "fileOrFolderName": det["name"],
            "check32BitOn64System": False,
            "detectionType": "exists",
        }
    return {
        "@odata.type": "#microsoft.graph.win32LobAppProductCodeDetection",
        "productCode": det["productCode"],
        "productVersionOperator": "notConfigured",
    }


def build_app_body(app: dict, intunewin_name: str) -> dict:
    return {
        "@odata.type": "#microsoft.graph.win32LobApp",
        "displayName": app["displayName"],
        "description": app["description"],
        "publisher": app["publisher"],
        "informationUrl": app.get("informationUrl"),
        "fileName": intunewin_name,
        "setupFilePath": app["installer"]["fileName"],
        "installCommandLine": app["installCommandLine"],
        "uninstallCommandLine": app["uninstallCommandLine"],
        "applicableArchitectures": app.get("architectures", "x64"),
        # Graph rejects newer strings such as "21H2" in minimumSupportedWindowsRelease; use the
        # boolean OS flags instead (v10_1607 = Windows 10 1607 or later, which includes Windows 11)
        "minimumSupportedOperatingSystem": {app.get("minimumOperatingSystem", "v10_1607"): True},
        "installExperience": {
            "runAsAccount": app.get("runAsAccount", "system"),
            "deviceRestartBehavior": app.get("restartBehavior", "suppress"),
        },
        "detectionRules": [detection_rule(app["detection"])],
        "returnCodes": [
            {"returnCode": 0, "type": "success"},
            {"returnCode": 1707, "type": "success"},
            {"returnCode": 3010, "type": "softReboot"},
            {"returnCode": 1641, "type": "hardReboot"},
            {"returnCode": 1618, "type": "retry"},
        ],
        "roleScopeTagIds": ["0"],
    }


def build_assignment_body(group_id: str, intent: str) -> dict:
    if intent not in {"required", "available"}:
        raise ValueError("intent must be required or available")
    return {
        "mobileAppAssignments": [{
            "@odata.type": "#microsoft.graph.mobileAppAssignment",
            "intent": intent,
            "target": {"@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": group_id},
            "settings": {
                "@odata.type": "#microsoft.graph.win32LobAppAssignmentSettings",
                "notifications": "showAll",
                "deliveryOptimizationPriority": "notConfigured",
            },
        }]
    }


# ---------- Graph / storage ----------

class Graph:
    def __init__(self, token: str):
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        req = urllib.request.Request(
            f"{GRAPH}/{path}", method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as res:
                raw = res.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:500]
            raise RuntimeError(f"{method} {path} -> {err.code}: {detail}") from err
        return json.loads(raw) if raw else {}

    def wait_state(self, path: str, want: str, timeout: int = 900) -> dict:
        end = time.time() + timeout
        while time.time() < end:
            f = self.call("GET", path)
            state = f.get("uploadState", "")
            if state == want:
                return f
            if state.endswith("Failed") or state.endswith("TimedOut"):
                raise RuntimeError(f"{path}: {state}")
            time.sleep(5)
        raise TimeoutError(f"{path}: still not {want}")


def put_blob(sas: str, data: bytes) -> None:
    ids = []
    for i in range(0, len(data), BLOCK):
        bid = base64.b64encode(f"{i // BLOCK:06d}".encode()).decode()
        ids.append(bid)
        req = urllib.request.Request(f"{sas}&comp=block&blockid={urllib.parse.quote(bid)}", method="PUT",
                                     data=data[i:i + BLOCK], headers={"x-ms-blob-type": "BlockBlob"})
        urllib.request.urlopen(req, timeout=300).read()
    xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>" + "".join(
        f"<Latest>{b}</Latest>" for b in ids) + "</BlockList>"
    req = urllib.request.Request(f"{sas}&comp=blocklist", method="PUT", data=xml.encode())
    urllib.request.urlopen(req, timeout=300).read()


def download(url: str, sha256: str) -> bytes:
    with urllib.request.urlopen(url, timeout=600) as res:
        data = res.read()
    got = hashlib.sha256(data).hexdigest()
    if got.lower() != sha256.lower():
        raise ValueError(f"installer SHA-256 mismatch: {got} (manifest {sha256})")
    return data


# ---------- main ----------

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("manifest", type=Path, help="Intune/Win32Apps/<App>/app.json")
    ap.add_argument("--group-id", required=True, help="Entra group object ID to assign")
    ap.add_argument("--intent", default="required", choices=["required", "available"])
    ap.add_argument("--installer-file", type=Path, help="use a local installer instead of downloading")
    ap.add_argument("--param", action="append", default=[], metavar="KEY=VALUE",
                    help="fill {{KEY}} placeholders in the command lines, e.g. ORGANIZATION=myteam")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    app = apply_params(load_manifest(args.manifest), args.param)
    inst = app["installer"]
    data = args.installer_file.read_bytes() if args.installer_file else download(inst["url"], inst["sha256"])
    if hashlib.sha256(data).hexdigest().lower() != inst["sha256"].lower():
        raise ValueError("installer SHA-256 does not match the manifest")
    plain = zip_folder({inst["fileName"]: data})
    blob, info = encrypt_content(plain)
    assert decrypt_content(blob, info) == plain
    name = Path(inst["fileName"]).stem + ".intunewin"
    body = build_app_body(app, name)
    assignment = build_assignment_body(args.group_id, args.intent)

    if args.dry_run:
        print(json.dumps(body, ensure_ascii=False, indent=1))
        print(json.dumps(assignment))
        print(f"package: plain={len(plain)} encrypted={len(blob)} (self-check ok)")
        return 0

    token = os.environ.get("GRAPH_ACCESS_TOKEN")
    if not token:
        print("GRAPH_ACCESS_TOKEN is not set", file=sys.stderr)
        return 2
    g = Graph(token)
    quoted = urllib.parse.quote(f"displayName eq '{app['displayName'].replace(chr(39), chr(39) * 2)}'")
    found = [a for a in g.call("GET", f"deviceAppManagement/mobileApps?$filter={quoted}").get("value", [])
             if a.get("@odata.type") == "#microsoft.graph.win32LobApp"]
    if len(found) > 1:
        raise RuntimeError("more than one win32LobApp with this displayName")
    if found:
        app_id = found[0]["id"]
        g.call("PATCH", f"deviceAppManagement/mobileApps/{app_id}", body)
        action = "updated"
    else:
        app_id = g.call("POST", "deviceAppManagement/mobileApps", body)["id"]
        action = "created"
    base = f"deviceAppManagement/mobileApps/{app_id}/microsoft.graph.win32LobApp/contentVersions"
    cv = g.call("POST", base, {})["id"]
    f = g.call("POST", f"{base}/{cv}/files", {
        "@odata.type": "#microsoft.graph.mobileAppContentFile", "name": name,
        "size": len(plain), "sizeEncrypted": len(blob), "manifest": None, "isDependency": False,
    })
    fpath = f"{base}/{cv}/files/{f['id']}"
    f = g.wait_state(fpath, "azureStorageUriRequestSuccess")
    put_blob(f["azureStorageUri"], blob)
    g.call("POST", f"{fpath}/commit", {"fileEncryptionInfo": info})
    g.wait_state(fpath, "commitFileSuccess")
    g.call("PATCH", f"deviceAppManagement/mobileApps/{app_id}",
           {"@odata.type": "#microsoft.graph.win32LobApp", "committedContentVersion": cv})
    g.call("POST", f"deviceAppManagement/mobileApps/{app_id}/assign", assignment)
    print(f"{action}, uploaded (content version {cv}) and assigned ({args.intent}): {app['displayName']} ({app_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
