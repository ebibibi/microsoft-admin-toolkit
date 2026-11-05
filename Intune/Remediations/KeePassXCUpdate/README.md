# KeePassXCUpdate (Intune Remediation, SYSTEM)

Installs KeePassXC and keeps it on the newest stable release from the upstream
[GitHub releases](https://github.com/keepassxreboot/keepassxc/releases).

Use it instead of the Intune *Microsoft Store app (new)* entry `XP8K2L36VP0QMB`. Intune keeps a
Store app current only with what the Store offers, and that listing lags upstream: it still
offered 2.7.12 fifteen days after 2.8.0 shipped security fixes.

## Behaviour

- **Soak period:** a release becomes eligible 3 days after publication (`$MinReleaseAgeDays`).
  Drafts, prereleases and non `x.y.z` tags are ignored. It never downgrades.
- **Checks before install:** the SHA-256 digest from the GitHub release API and a valid
  Authenticode signature from `DroidMonkey Apps, LLC`. Update `$ExpectedSigner` if upstream
  changes its certificate; until then updates fail visibly rather than install.
- **Never closes the app.** `KeePassXC`, `keepassxc-proxy` (browser integration) or
  `keepassxc-cli` running means the checked MSI waits in `%ProgramData%\KeePassXCUpdate`
  (SYSTEM and Administrators only), and a one-shot SYSTEM startup task installs it at the next
  restart, then deletes itself and the MSI. An hourly run that finds the app closed installs at once.
- **Honest status:** while an update waits, detection stays non-compliant, because the device
  is not updated yet.
- **Visual C++ runtime:** the MSI does not bundle it, and without it the app fails to start
  (exit code `0xC0000135`, observed on `keepassxc-cli`). The remediation refuses to install until `vcruntime140.dll`,
  `vcruntime140_1.dll` and `msvcp140.dll` exist, and retries on the next run. Deploy
  `VCRedistX64` to the same group.

## Migrating from the Store app

Remove the Store app's assignment **before** assigning this remediation. Otherwise Intune can
see the upgraded product as a different version and try to apply the Store's older one. Removing
a required assignment does not uninstall the app. Do not change it to an *uninstall* assignment.

## Limits

- Startup tasks do not run after a shutdown with Fast Startup on, only after a restart or a cold
  boot. A device that keeps KeePassXC open takes the update at its next restart, typically the
  monthly Windows update.
- The GitHub API allows 60 unauthenticated requests per hour per IP. A rate-limited run reports
  an error and the next run retries.
- The digest comes from the same place as the file, so it catches corruption. The signature is
  what establishes the publisher.
- Evidence covers x64 only. The ARM64 branch has only offline tests.

Deploy with `Intune/tools/deploy_remediations.py --only KeePassXCUpdate ...`.
