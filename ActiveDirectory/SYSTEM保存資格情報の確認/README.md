# Check domain credentials saved in the SYSTEM vault

`SystemSavedCredential.ps1` lists the Credential Manager entries of `NT AUTHORITY\SYSTEM` through a
temporary scheduled task and flags `Domain:target=` entries that point to a domain controller or to
the domain. Dot-source it from an elevated Windows PowerShell 5.1 session on a domain-joined device.

```powershell
. .\SystemSavedCredential.ps1
$creds = @(Get-SystemSavedCredential)          # throws when the check could not run
$creds | Where-Object PointsToDc               # candidates; review before deleting
Remove-SystemSavedCredential -FullTarget 'Domain:target=dc01'   # explicit delete, re-lists to confirm
```

## Why it matters

A process running as SYSTEM authenticates with a saved domain credential when the connection target
matches. The DC then evaluates the operation as that user, so permissions granted to `SELF` do not
apply. Symptoms include `0x80070005` in the Hybrid Join `join` phase with `userCertificate` left
empty and correct ACLs. A user ticket appears under `klist -li 0x3e7`.

## Failure conditions and limitations

- Do not treat any entry as abnormal. A default `WindowsLive:target=virtualapp/didlogical` entry was observed. Only `Domain:target=` is evaluated.
- `schtasks /Run` and `Start-ScheduledTask` report success even when the task fails, so the helper checks `LastTaskResult` and the output file.
- Failing to reach a DC throws. Callers must not treat that as "no findings".
- Output is decoded with the machine OEM code page. Only the Japanese and English `User` labels are parsed; the user name is blank on other display languages.
- Domain name, NetBIOS name and DC IP targets did not affect a bind to the DC FQDN in the lab, but they are still flagged because the name a real process binds with can differ.
- Not exercised: battery operation, non-Japanese Windows, and `*` / `DOMAIN\*` targets (`cmdkey /add` rejected them).
- `dsregcmd /join` itself was not run. The lab write used `telephoneNumber`, another attribute in the Personal Information property set.
- Requires local administrator rights. Evidence: see `docs/evidence/`.
