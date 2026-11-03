# NodeJsMsiUpdate (Intune Remediation, SYSTEM)

Keeps an existing Node.js MSI install on the newest release of its **current major line**
(for example 22.x), using `https://nodejs.org/dist/index.json`.

- Before `msiexec /i ... /qn /norestart` the MSI is checked against the release's
  `SHASUMS256.txt` and must carry a valid Authenticode signature from the OpenJS Foundation.
- Never installs Node.js on a device that does not have it, and never moves to a new major
  version (change majors deliberately, outside this remediation).
- Detection treats a newer patch/minor in the same line as non-compliant, so the hourly
  Remediation run keeps the device current. Exit codes 0 and 3010 from msiexec count as success.
- Both scripts carry the shared functions inline; the first comment line is a build note.
- Use case: Defender Vulnerability Management flagged an exploitable Node.js CVE on MSI
  installs that no other updater (Store, Windows Update, winget user scope) maintains.

Deploy with `Intune/tools/deploy_remediations.py --only NodeJsMsiUpdate ...`.
