# Targeted exposure baseline

This deliberately small baseline addresses four Defender Vulnerability Management
recommendations: require elevation to change network location, block Office Flash
activation, enable Office automatic updates, and hide the Office update toggle.
Five DWORD values are written; their original existence, type, and values are
saved before changes to `%ProgramData%\TargetedExposureBaseline\original-values.json`.
Retries preserve that first backup. Restore those values (or remove originally
absent values) to undo the change. Empty registry keys may remain after rollback.

This does not fix software CVEs, trigger an Office update, or prove that an update
succeeded. Detection also reports relevant machine installer versions and whether
selected applications are running. Missing installer entries are not proof that
all user profiles are clean. Application bundles must be updated through their
own vendor; do not replace bundled DLLs or delete old profiles to reduce a score.

## Deployment

Requires Windows, 64-bit Windows PowerShell 5.1+, SYSTEM, and existing Intune
Remediations licensing/permissions. Review existing device policy for conflicts.
Use a private copy with `ExpectedComputerName` fixed to the verified target name;
`Mode Detect` is the detection script and `Mode Remediate` is the repair script.
The target guard runs before any reads/writes. Deploy without broad assignments,
then request an on-demand run against the verified single Intune managed device.
Read back both script bodies and the empty assignment list before requesting it.
An accepted API request is not execution evidence: inspect device run states,
post-remediation detection, and later TVM reassessment.

Keep changes to NTLM, RDP authentication, LDAP, firewall rule merging, BitLocker
startup authentication, and account policies out of this package. They need a
separate compatibility/availability assessment.

Sources: Microsoft Graph [on-demand remediation](https://learn.microsoft.com/graph/api/intune-devices-manageddevice-initiateondemandproactiveremediation?view=graph-rest-beta)
and the device's `DeviceTvmSecureConfigurationAssessmentKB.RemediationOptions`.
The registry settings were transcribed from that service knowledge base, not
copied from an external implementation. Status: verified on one Windows 11 device
(Windows PowerShell 5.1, Intune Remediations); rollback and TVM reassessment were not
exercised. See `docs/evidence/intune-targeted-exposure-baseline-lab.json`.
