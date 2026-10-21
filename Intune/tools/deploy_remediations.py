#!/usr/bin/env python3
"""Create or update Intune Remediations (deviceHealthScripts) from a manifest.

Reads Intune/Remediations/remediations.json, uploads each folder's Detect.ps1 and
Remediate.ps1, and assigns every script to one Entra group.

The caller supplies a delegated or application Microsoft Graph access token in
the GRAPH_ACCESS_TOKEN environment variable. Required: an Intune role that can
manage scripts and DeviceManagementScripts.ReadWrite.All (older tenants accept
DeviceManagementConfiguration.ReadWrite.All). Use --dry-run to print the
requests without calling Graph.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

GRAPH = "https://graph.microsoft.com/beta"
ROOT = Path(__file__).resolve().parents[1] / "Remediations"
RUN_AS = {"system", "user"}


def load_manifest(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    items = data.get("remediations")
    if not isinstance(items, list) or not items:
        raise ValueError("manifest has no remediations")
    for item in items:
        for key in ("folder", "displayName", "description", "runAsAccount"):
            if not isinstance(item.get(key), str) or not item[key]:
                raise ValueError(f"manifest entry missing {key}: {item}")
        if item["runAsAccount"] not in RUN_AS:
            raise ValueError(f"runAsAccount must be system or user: {item['folder']}")
    return items


def build_script_body(item: dict, root: Path, prefix: str, publisher: str) -> dict:
    folder = root / item["folder"]

    def encoded(name: str) -> str:
        return base64.b64encode((folder / name).read_bytes()).decode("ascii")

    return {
        "displayName": f"{prefix}{item['displayName']}",
        "description": item["description"],
        "publisher": publisher,
        "runAs32Bit": False,
        "runAsAccount": item["runAsAccount"],
        "enforceSignatureCheck": False,
        "detectionScriptContent": encoded("Detect.ps1"),
        "remediationScriptContent": encoded("Remediate.ps1"),
        "roleScopeTagIds": ["0"],
    }


def build_assignment_body(group_id: str, hourly_interval: int) -> dict:
    if not 1 <= hourly_interval <= 23:
        raise ValueError("hourly interval must be 1-23")
    return {
        "deviceHealthScriptAssignments": [
            {
                "target": {
                    "@odata.type": "#microsoft.graph.groupAssignmentTarget",
                    "groupId": group_id,
                },
                "runRemediationScript": True,
                "runSchedule": {
                    "@odata.type": "#microsoft.graph.deviceHealthScriptHourlySchedule",
                    "interval": hourly_interval,
                },
            }
        ]
    }


class Graph:
    def __init__(self, token: str):
        self.token = token

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        req = urllib.request.Request(
            f"{GRAPH}/{path}",
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                raw = res.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:500]
            raise RuntimeError(f"{method} {path} -> {err.code}: {detail}") from err
        return json.loads(raw) if raw else {}

    def find_by_name(self, name: str) -> str | None:
        quoted = name.replace("'", "''")
        query = urllib.parse.quote(f"displayName eq '{quoted}'")
        found = self.call("GET", f"deviceManagement/deviceHealthScripts?$filter={query}&$select=id,displayName")
        matches = [s["id"] for s in found.get("value", []) if s.get("displayName") == name]
        if len(matches) > 1:
            raise RuntimeError(f"more than one remediation named {name!r}")
        return matches[0] if matches else None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--group-id", required=True, help="Entra group object ID to assign")
    ap.add_argument("--manifest", type=Path, default=ROOT / "remediations.json")
    ap.add_argument("--name-prefix", default="", help="prefix for display names, e.g. 'MySetup - '")
    ap.add_argument("--publisher", default="microsoft-admin-toolkit")
    ap.add_argument("--hourly-interval", type=int, default=1)
    ap.add_argument("--only", action="append", help="deploy only these folders")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    items = load_manifest(args.manifest)
    if args.only:
        items = [i for i in items if i["folder"] in set(args.only)]
    root = args.manifest.resolve().parent
    assignment = build_assignment_body(args.group_id, args.hourly_interval)

    if args.dry_run:
        for item in items:
            body = build_script_body(item, root, args.name_prefix, args.publisher)
            print(json.dumps({k: v for k, v in body.items() if not k.endswith("Content")}, ensure_ascii=False))
        print(json.dumps(assignment))
        return 0

    token = os.environ.get("GRAPH_ACCESS_TOKEN")
    if not token:
        print("GRAPH_ACCESS_TOKEN is not set", file=sys.stderr)
        return 2
    graph = Graph(token)
    for item in items:
        body = build_script_body(item, root, args.name_prefix, args.publisher)
        script_id = graph.find_by_name(body["displayName"])
        if script_id:
            graph.call("PATCH", f"deviceManagement/deviceHealthScripts/{script_id}", body)
            action = "updated"
        else:
            script_id = graph.call("POST", "deviceManagement/deviceHealthScripts", body)["id"]
            action = "created"
        graph.call("POST", f"deviceManagement/deviceHealthScripts/{script_id}/assign", assignment)
        print(f"{action} and assigned: {body['displayName']} ({script_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
