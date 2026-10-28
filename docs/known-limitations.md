# Known limitations discovered during initial review

These observations are from static review, not live-domain or tenant execution.

- `ActiveDirectory/Find-OldObjects/Find-OldUsers.ps1` uses a replicated timestamp
  filter and fixed account-name exclusions. It does not query every DC's lastLogon,
  establish coverage for users without that attribute, or justify disabling accounts.
  Treat output as candidates for investigation. Before expanding this script, test
  recent activity on one DC, missing logon history and failed DC queries.
- `ActiveDirectory/Invoke-ADStaleInventory/Invoke-ADStaleInventory.ps1` suppresses
  several query failures with SilentlyContinue. An empty output is not proof of a
  clean or completely enumerated environment. README permission claims have not
  been independently validated for least privilege.
- `All/Generate-M365InventoryReport.ps1` can reuse Graph and Exchange sessions and
  connects the services independently. Verify their actual target contexts before
  use. A successful Azure CLI tenant check alone is insufficient.
- Legacy permissions and dependency lists are not fully audited. Catalogue status
  remains legacy-unverified until evidence for the actual artifact is recorded.

Sam Erde's collection is a reference, not imported code. A previous static review
of Get-InactiveADUser.ps1 at commit 786225096078651d0fcbc535136d074b4c500698 found a
potential mismatch between the initial inactivity filter and the condition guarding
all-DC verification. Review the current upstream implementation before selecting it;
do not treat the repository's general quality as proof of every individual script.
- `Intune/Remediations/WingetUserPackages` uses the Microsoft.WinGet.Client module,
  which talks to the WinGet COM server. On one Windows Insider build (10.0.26340)
  detection stopped at `Failed to create instance: -2147023174` (0x800706BA, RPC
  server unavailable) before any package was checked, so nothing was installed.
  The same script passed on 10.0.26200. Running `Repair-WinGetPackageManager -Force
  -Latest` once in Windows PowerShell 5.1 on the device cleared it; the next runs
  installed packages. On that device `OpenAI.Codex` still failed to install while
  the other packages succeeded; Intune does not return remediation output, so the
  cause has to be read on the device.
