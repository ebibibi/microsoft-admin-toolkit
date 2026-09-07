#!/usr/bin/env python3
"""Search scripts and check revision-bound evidence; never execute scripts."""

from __future__ import annotations

import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
STATES = {"legacy-unverified", "experimental", "verified", "deprecated"}
SCOPES = {"review", "offline", "lab", "production"}


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def local_file(root: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or Path(name).is_absolute():
        raise ValueError("Expected a repository-relative file path")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError(f"Missing or out-of-repository file: {name}")
    return path


def digest(root: Path, name: str) -> str:
    return hashlib.sha256(local_file(root, name).read_bytes()).hexdigest()


def artifacts(entry: dict[str, Any]) -> list[str]:
    return [entry["path"], entry["runbook"], *entry["dependencies"], *entry["tests"]]


def search(root: Path, query: str) -> list[dict[str, Any]]:
    terms = query.casefold().split()
    entries = read_json(root / "catalog.json")["entries"]
    sources = read_json(root / "sources.json")["sources"]
    return [
        item
        for item in [*entries, *sources]
        if all(
            term in json.dumps(item, ensure_ascii=False).casefold() for term in terms
        )
    ]


def template(root: Path, entry_id: str, scope: str) -> dict[str, Any]:
    entry = next(
        (e for e in read_json(root / "catalog.json")["entries"] if e["id"] == entry_id),
        None,
    )
    if entry is None:
        raise ValueError(f"Unknown catalog ID: {entry_id}")
    return {
        "entry_id": entry_id,
        "date": date.today().isoformat(),
        "scope": scope,
        "outcome": "pending",
        "artifacts": {name: digest(root, name) for name in artifacts(entry)},
        "runtime": "Record actual OS, runtime and relevant module versions.",
        "procedure": "Record reproducible commands or review steps; use no tenant identifiers.",
        "expected": "Record expectations before the check.",
        "observed": "Record actual observations after the check.",
        "limitations": ["No execution or verification is implied by this template."],
    }


def validate(root: Path) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    catalog = read_json(root / "catalog.json")
    sources = read_json(root / "sources.json")
    if not isinstance(catalog, dict) or not isinstance(catalog.get("entries"), list):
        return ["Catalog must contain an entries list"], []
    if not isinstance(sources, dict) or not isinstance(sources.get("sources"), list):
        return ["Sources must contain a sources list"], []
    if catalog.get("version") != 1 or sources.get("version") != 1:
        errors.append("Unsupported catalog or sources version")
    source_ids: set[str] = set()
    for source in sources["sources"]:
        try:
            if source["id"] in source_ids:
                raise ValueError("Duplicate source ID")
            if not isinstance(source["id"], str) or not source["id"]:
                raise ValueError("Source needs a non-empty ID")
            source_ids.add(source["id"])
            for key in ("title", "summary", "url", "license_note"):
                if not isinstance(source[key], str) or not source[key].strip():
                    raise ValueError(f"Source needs {key}")
            if not source["url"].startswith("https://"):
                raise ValueError("Source URL must use HTTPS")
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"Source: {exc}")
    ids: set[str] = set()
    paths: set[str] = set()
    for entry in catalog["entries"]:
        if not isinstance(entry, dict):
            errors.append("Entry must be an object")
            continue
        label = entry.get("id")
        try:
            if not isinstance(label, str) or not label or label in ids:
                raise ValueError("Missing or duplicate entry ID")
            ids.add(label)
            for key in ("title", "summary", "path", "runbook", "permissions"):
                if not isinstance(entry[key], str) or not entry[key].strip():
                    raise ValueError(f"Entry needs {key}")
            for key in (
                "areas",
                "tags",
                "dependencies",
                "tests",
                "evidence",
                "sources",
            ):
                if not isinstance(entry[key], list) or any(
                    not isinstance(v, str) for v in entry[key]
                ):
                    raise ValueError(f"{key} must be a list of strings")
            if entry["status"] not in STATES:
                raise ValueError("Unknown status")
            if entry["effect"] not in {"read-only", "changes-state"}:
                raise ValueError("Unknown effect")
            if not set(entry["sources"]).issubset(source_ids):
                raise ValueError("Unknown source ID")
            if entry["path"] in paths:
                raise ValueError("Duplicate script path")
            paths.add(entry["path"])
            local_file(root, entry["runbook"])
            current = {name: digest(root, name) for name in artifacts(entry)}
            field_results: list[tuple[str, int, str]] = []
            for sequence, evidence_path in enumerate(entry["evidence"]):
                evidence = read_json(local_file(root, evidence_path))
                if evidence["entry_id"] != label:
                    raise ValueError("Evidence belongs to another entry")
                if date.fromisoformat(evidence["date"]) > date.today():
                    raise ValueError("Evidence date is in the future")
                if evidence["scope"] not in SCOPES or evidence["outcome"] not in {
                    "pending",
                    "passed",
                    "failed",
                    "inconclusive",
                }:
                    raise ValueError("Unknown evidence scope or outcome")
                for key in ("runtime", "procedure", "expected", "observed"):
                    if not isinstance(evidence[key], str) or not evidence[key].strip():
                        raise ValueError(f"Evidence needs {key}")
                if not isinstance(evidence["limitations"], list) or not all(
                    isinstance(x, str) for x in evidence["limitations"]
                ):
                    raise ValueError("Evidence limitations must be a string list")
                hashes = evidence["artifacts"]
                if not isinstance(hashes, dict) or any(
                    not isinstance(v, str)
                    or len(v) != 64
                    or any(c not in "0123456789abcdef" for c in v)
                    for v in hashes.values()
                ):
                    raise ValueError("Evidence needs SHA-256 artifact hashes")
                fresh = hashes == current
                if not fresh:
                    warnings.append(
                        f"{label}: historical evidence is stale: {evidence_path}"
                    )
                if (
                    fresh
                    and evidence["scope"] in {"lab", "production"}
                    and evidence["outcome"] != "pending"
                ):
                    field_results.append(
                        (evidence["date"], sequence, evidence["outcome"])
                    )
            field_verified = bool(field_results) and max(field_results)[2] == "passed"
            if entry["status"] == "verified" and not field_verified:
                raise ValueError(
                    "Verified requires current passed lab/production evidence for all declared artifacts"
                )
        except (KeyError, TypeError, ValueError, OSError) as exc:
            errors.append(f"{label}: {exc}")
    # Every managed script is discoverable; tooling/tests are not operational scripts.
    unmanaged = {
        str(p.relative_to(root))
        for p in root.rglob("*.ps1")
        if not set(p.relative_to(root).parts) & {".git", "tests", "tools"}
    } - paths
    errors.extend(f"Uncatalogued script: {name}" for name in sorted(unmanaged))
    return errors, warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    find = sub.add_parser("search")
    find.add_argument("query", nargs="?", default="")
    sub.add_parser("validate")
    draft = sub.add_parser("evidence-template")
    draft.add_argument("entry_id")
    draft.add_argument("--scope", choices=sorted(SCOPES), default="review")
    args = parser.parse_args()
    try:
        if args.command == "search":
            print(
                json.dumps(search(args.root, args.query), ensure_ascii=False, indent=2)
            )
        elif args.command == "evidence-template":
            print(
                json.dumps(
                    template(args.root, args.entry_id, args.scope),
                    ensure_ascii=False,
                    indent=2,
                )
            )
        else:
            errors, warnings = validate(args.root)
            for warning in warnings:
                print(f"WARNING: {warning}")
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            if errors:
                return 1
            print(
                "Catalog and evidence structure valid; this does not certify script behavior."
            )
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
