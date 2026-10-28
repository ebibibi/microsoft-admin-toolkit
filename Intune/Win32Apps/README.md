# Intune Win32 apps (from Linux)

`Intune/tools/deploy_win32_app.py` packages one installer as an Intune Win32 app
without IntuneWinAppUtil.exe, uploads it through Microsoft Graph and assigns it.

```bash
export GRAPH_ACCESS_TOKEN=...   # delegated or app token: DeviceManagementApps.ReadWrite.All + an Intune role that manages apps
python3 Intune/tools/deploy_win32_app.py Intune/Win32Apps/<App>/app.json \
  --group-id <Entra group object ID> --param KEY=VALUE [--intent required|available] [--dry-run]
```

- The manifest pins the installer URL and SHA-256. The tool refuses a mismatching download.
- `{{KEY}}` placeholders in the command lines are filled from `--param` (for example a tenant-specific team name). Values containing double quotes are rejected.
- `--dry-run` builds and decrypts the package as a self-check and prints the request bodies. It does not call Graph.
- Re-running with the same displayName updates the app and uploads a new content version.

## Apps

| Folder | App | Notes |
|---|---|---|
| `CloudflareOneClient` | Cloudflare One Client (WARP) | `--param ORGANIZATION=<Zero Trust team>`. File detection (the client self-updates, so the product code changes). |

## Known limitations

- Only single-file installers (the folder holds the installer alone).
- The minimum OS is set with `minimumSupportedOperatingSystem` (default `v10_1607`). Graph returned 400 "Unknown MinimumSupportedWindowsRelease: 21H2" for the string field.
- Graph `beta` endpoints; no app dependency or supersedence support.
