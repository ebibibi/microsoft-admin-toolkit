# Graph read-only application for unattended reporting

Register an Entra ID application that reads Microsoft Graph with a certificate and
no interactive sign-in, so scheduled reporting and inventory jobs can run unattended.

## When to use this

A job needs tenant data on a schedule, and today it depends on one of:

- a signed-in browser profile kept alive on disk
- a stored user password, or a TOTP seed stored next to it
- a person running a command every month

All three fail when Conditional Access changes, and all three grant far more than
read access. A certificate-backed application with read-only Graph permissions does
not expire on a sign-in policy change and cannot modify the tenant.

## What this is not

This does not bypass Conditional Access for interactive users, and it does not help
with portal pages that have no Graph API. Microsoft 365 Adoption Score, for example,
has no programmatic access at the time of writing.

## Prerequisites

- Azure CLI signed in to the target tenant as Global Administrator or
  Privileged Role Administrator (creating the application and granting application
  permissions both require directory write access)
- A certificate generated beforehand

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
  -keyout ~/.certs/<name>.key -out ~/.certs/<name>.crt \
  -subj "/CN=<Name>-Collector/O=<Org>"
openssl pkcs12 -export -out ~/.certs/<name>.pfx \
  -inkey ~/.certs/<name>.key -in ~/.certs/<name>.crt -passout pass:
chmod 600 ~/.certs/<name>.*
```

Record the certificate expiry. When it passes, every job using it stops at
authentication, not at a later step.

## Usage

```bash
./New-GraphReadOnlyApp.sh \
  --azure-config-dir ~/.azure-<tenant> \
  --display-name "M365 Health Report Collector" \
  --certificate ~/.certs/<name>.crt \
  --dry-run
```

Remove `--dry-run` to apply. The script prints `tenant_id` and `client_id` on success.

Override the permission set with repeated `--permission` flags. The default set
covers tenant health reporting:

| Permission | Covers |
|---|---|
| `ServiceHealth.Read.All` | Service health overview |
| `ServiceMessage.Read.All` | Incidents and advisories |
| `Reports.Read.All` | Usage reports, SharePoint storage |
| `ReportSettings.Read.All` | Whether report names are concealed |
| `SecurityEvents.Read.All` | Secure Score |
| `SecurityIncident.Read.All` | Defender incidents |
| `DeviceManagementManagedDevices.Read.All` | Device compliance |
| `DeviceManagementServiceConfig.Read.All` | Apple MDM push certificate, ABM tokens |
| `AttackSimulation.Read.All` | Attack simulation training |
| `AuditLog.Read.All` | Sign-in logs |
| `Organization.Read.All` | Subscribed SKUs |
| `Sites.Read.All` | Resolving SharePoint site names |

## Behaviour worth knowing

- **Write permissions are refused.** Anything matching `ReadWrite`, `.Write.`,
  `.AccessAsUser.` or `.FullControl.` exits non-zero before any change is made.
  Write access belongs in a separate application with its own approval.
- **Admin consent is granted in the same step.** Permissions are written directly as
  `appRoleAssignments` on the service principal, so there is no separate consent action.
- **Re-running is additive.** An existing application and service principal are reused,
  already-assigned permissions are reported as `=`, and nothing is removed.
- **Partial failure exits non-zero.** A permission that Microsoft Graph does not offer
  in the tenant is reported and fails the run rather than being skipped quietly.

## Acquiring a token afterwards

```python
import msal
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, pkcs12,
)

key, cert, _ = pkcs12.load_key_and_certificates(open("cert.pfx", "rb").read(), b"")
app = msal.ConfidentialClientApplication(
    CLIENT_ID,
    authority=f"https://login.microsoftonline.com/{TENANT_ID}",
    client_credential={
        "private_key": key.private_bytes(
            Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()
        ).decode(),
        "thumbprint": cert.fingerprint(hashes.SHA1()).hex(),
    },
)
token = app.acquire_token_for_client(["https://graph.microsoft.com/.default"])["access_token"]
```

## Known limitations

- Application permissions are tenant-wide. There is no per-site or per-group scoping
  for most of the reporting permissions above. `Sites.Read.All` in particular grants
  read access to every site collection.
- Graph usage reports return concealed user and site names when the tenant has
  `displayConcealedNames` enabled. Check `/beta/admin/reportSettings` before assuming
  identifiers will be present.
- `getSharePointSiteUsageDetail` returns an empty `Site URL` column. Resolve site names
  through `/v1.0/sites/{siteId}` instead.
