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
