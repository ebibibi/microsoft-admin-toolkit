# Intune Remediations: personal workstation setup

Detection/remediation script pairs for Intune Remediations (`deviceHealthScripts`).
Each folder holds `Detect.ps1` (exit 0 = compliant, 1 = run remediation) and
`Remediate.ps1`. `remediations.json` lists them for the deploy tool.

| Folder | Runs as | What it does |
|---|---|---|
| `KeyboardScancodeSwap` | system | Writes the machine-wide `Scancode Map` so CapsLock sends Right Ctrl (one-way: Right Ctrl is unchanged and no key sends CapsLock). Needs a restart. Affects every user of the device. |
| `VCRedistX64` | system | Installs the Visual C++ 2015-2022 x64 runtime (needed by Keyhac 1.83) after checking the installer is Microsoft-signed. |
| `KeyhacFakeymacs` | user | Installs [Keyhac](https://github.com/crftwr/keyhac-win) + [Fakeymacs](https://github.com/smzht/fakeymacs) (Emacs bindings) into `%LOCALAPPDATA%\Programs\Keyhac`, sets `fc.side_of_ctrl_key = "R"`, adds a Startup shortcut and starts it. |
| `PortableToolsFromOneDrive` | user | **Deprecated, not in the manifest.** Copies portable tools (KeePass / KeePassXC) from the personal OneDrive. Do not use: install tools from a managed source instead (Intune *Microsoft Store app (new)*, e.g. KeePassXC Store ID `XP8K2L36VP0QMB`, or `WingetUserPackages`). |
| `WingetUserPackages` | user | Installs (user scope) and upgrades winget packages that are not in the Microsoft Store (default: Git, Claude Code, Codex CLI) through the `Microsoft.WinGet.Client` module, which the remediation installs for the user from PSGallery. Detection treats an available upgrade as non-compliant, so the hourly run keeps them current; an upgrade reported as not applicable is recorded in `%LOCALAPPDATA%\MySetup\winget-skipped-upgrades.json` and ignored until a newer version appears. Do not rely on `winget.exe` exit codes here: on a lab device they reported an upgrade for every package that never cleared. |

With `KeyboardScancodeSwap` and `KeyhacFakeymacs` together, the key next to
`A` acts as an Emacs Ctrl (via Fakeymacs) while Left Ctrl keeps the normal
Windows shortcuts. This is the layout described in the Fakeymacs README.

## Sources and pinning

- `KeyhacFakeymacs` downloads Keyhac `v1.83` (`keyhac_183.zip`, SHA-256 pinned
  in the script) when `keyhac.exe` is missing. It does not read the personal
  OneDrive or any other user-synced folder: whether a consumer OneDrive is
  signed in must not change what runs on a managed device, and `config.py` /
  `config_personal.py` are Python that Keyhac executes.
- `config_personal.py` is created from the Fakeymacs sample when missing; the
  remediation only enforces `fc.side_of_ctrl_key`. Other local edits are kept.
- If `config.py` is not Fakeymacs, it is backed up (`config.py.bak-<time>`) and
  Fakeymacs is taken from commit `f83de826` (archive not hash-pinned; GitHub
  does not guarantee byte-stable archives). Update the constants to upgrade.
- Fakeymacs and Keyhac are not copied into this repository; they are
  downloaded on the device from their upstream repositories.

## Requirements and limits

- Windows 10/11 Enterprise/Education (or Windows E3/E5) licensing for Remediations;
  device Entra-joined or hybrid-joined and Intune-managed.
- User-context scripts run only while the user is signed in.
- Devices already set up by an earlier version keep their existing Keyhac
  folder while detection passes; delete `%LOCALAPPDATA%\Programs\Keyhac` to
  reinstall from the pinned sources.
- Keyhac runs unelevated and cannot remap keys in elevated windows.
- Scripts are ASCII-only so Windows PowerShell 5.1 reads them the same with or
  without a BOM. Keep `$Mappings` / `$Tools` / constants identical between the
  Detect and Remediate script of a pair.

## Deploy

```bash
export GRAPH_ACCESS_TOKEN=...   # delegated or app token, see deploy_remediations.py
python3 Intune/tools/deploy_remediations.py --group-id <entra-group-id> --name-prefix "MySetup - " --dry-run
python3 Intune/tools/deploy_remediations.py --group-id <entra-group-id> --name-prefix "MySetup - "
```

The tool creates or updates each remediation by display name and assigns it to
the group with an hourly schedule (`--hourly-interval`). Graph permission:
`DeviceManagementScripts.ReadWrite.All` (older tenants accept
`DeviceManagementConfiguration.ReadWrite.All`) plus an Intune role that can
manage scripts.

## Tests

`python3 -m unittest tests.test_intune_remediations -v` checks the manifest,
request bodies, ASCII text, PowerShell parsing, the Scancode Map bytes and the
`config_personal.py` rewrite. It does not exercise the registry, OneDrive,
downloads or shortcuts; see the evidence records for device results.
