#!/usr/bin/env bash
#
# Register an Entra ID application that reads Microsoft Graph with a certificate,
# with no interactive sign-in at run time.
#
# Why this exists
#   Unattended reporting and inventory jobs otherwise keep a signed-in browser
#   profile or a stored password on disk. Both are weaker than a read-only
#   application credential, and both break when Conditional Access changes.
#
# What it does
#   1. Creates (or reuses) an application registration
#   2. Attaches an existing certificate as a credential
#   3. Creates the service principal
#   4. Assigns the requested Microsoft Graph application permissions and, because
#      appRoleAssignments are written directly, grants admin consent in the same step
#
# What it does NOT do
#   - It does not create the certificate. Generate it first (see README.md).
#   - It does not remove permissions. Re-running only adds.
#
# This writes to the directory. Confirm the target tenant and obtain the tenant
# owner's approval before running it.
#
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  New-GraphReadOnlyApp.sh --display-name NAME --certificate PATH.crt
                          [--app-id APP_ID]
                          [--azure-config-dir DIR]
                          [--permission Graph.Permission.Name]...
                          [--dry-run]

Options:
  --display-name      Display name for a NEW application.
  --app-id            Update this existing application instead of creating one.
                      Required to touch anything that already exists: this script
                      never adopts an application found by display name.
  --certificate       Public certificate (.crt/.cer) already generated.
  --azure-config-dir  AZURE_CONFIG_DIR for an isolated Azure CLI login.
  --permission        Graph application permission. Repeatable.
                      Must be a read form (.Read, .Read.All, .ReadBasic,
                      .ReadBasic.All). Defaults to a read-only tenant health set.
  --dry-run           Print the planned actions and exit.

The signed-in Azure CLI identity must be able to create applications and grant
application permissions (Global Administrator or Privileged Role Administrator).
USAGE
  exit 2
}

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

DISPLAY_NAME=""
CERTIFICATE=""
APP_ID=""
DRY_RUN="false"
PERMISSIONS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --app-id) APP_ID="${2:-}"; shift 2 ;;
    --certificate) CERTIFICATE="${2:-}"; shift 2 ;;
    --azure-config-dir) export AZURE_CONFIG_DIR="${2:-}"; shift 2 ;;
    --permission) PERMISSIONS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [ -z "$DISPLAY_NAME" ] && [ -z "$APP_ID" ]; then
  usage
fi
[ -n "$CERTIFICATE" ] || usage

if [ ! -f "$CERTIFICATE" ]; then
  echo "Certificate not found: $CERTIFICATE" >&2
  exit 1
fi

if [ ${#PERMISSIONS[@]} -eq 0 ]; then
  # Read-only tenant health set. Every entry is a Read permission.
  PERMISSIONS=(
    ServiceHealth.Read.All
    ServiceMessage.Read.All
    Reports.Read.All
    ReportSettings.Read.All
    SecurityEvents.Read.All
    SecurityIncident.Read.All
    DeviceManagementManagedDevices.Read.All
    DeviceManagementServiceConfig.Read.All
    AttackSimulation.Read.All
    AuditLog.Read.All
    Organization.Read.All
    Sites.Read.All
  )
fi

# Accept only read forms. This is deliberately an allowlist.
#
# A denylist of write-looking substrings does not hold: Microsoft Graph has
# permissions that grant write access without containing "ReadWrite" or ".Write."
# anywhere in the name. Mail.Send is the obvious one. Enumerating what is allowed
# is the only filter that stays correct as Microsoft adds permissions.
#
# Recognised read forms: Foo.Read, Foo.Read.All, Foo.ReadBasic, Foo.ReadBasic.All.
# A legitimate read permission in an unusual shape must be added here deliberately
# rather than being let through by a pattern that happens not to match.
READ_PERMISSION_PATTERN='^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)*\.Read(Basic)?(\.All)?$'
for permission in "${PERMISSIONS[@]}"; do
  if ! printf '%s' "$permission" | grep -Eq "$READ_PERMISSION_PATTERN"; then
    echo "Refusing permission that is not a recognised read form: $permission" >&2
    echo "Allowed shapes: Foo.Read, Foo.Read.All, Foo.ReadBasic, Foo.ReadBasic.All." >&2
    echo "Write access belongs in a separate application with its own approval." >&2
    exit 1
  fi
done

TENANT_ID="$(az account show --query tenantId -o tsv)"
SIGNED_IN="$(az account show --query user.name -o tsv)"
echo "Tenant:   $TENANT_ID"
echo "Identity: $SIGNED_IN"
if [ -n "$APP_ID" ]; then
  echo "App:      $APP_ID (existing, named explicitly)"
else
  echo "App:      $DISPLAY_NAME (to be created)"
fi
echo "Permissions (${#PERMISSIONS[@]}):"
printf '  - %s\n' "${PERMISSIONS[@]}"

if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run: no changes made."
  exit 0
fi

if [ -n "$APP_ID" ]; then
  # The caller named the application. Confirm it exists and print what is being
  # modified, so an id typo does not silently credential a different application.
  EXISTING_NAME="$(az ad app show --id "$APP_ID" --query displayName -o tsv 2>/dev/null || true)"
  if [ -z "$EXISTING_NAME" ]; then
    echo "Application not found in this tenant: $APP_ID" >&2
    exit 1
  fi
  echo "Updating existing application: $EXISTING_NAME ($APP_ID)"
else
  # Never adopt an application found by display name. Display names are not unique,
  # and where members may register applications anyone can pre-create one with the
  # expected name. Adopting it would attach this certificate to an application
  # somebody else owns and grant it tenant-wide read permissions with admin consent.
  COLLISIONS="$(az ad app list --display-name "$DISPLAY_NAME" --query "[].appId" -o tsv)"
  if [ -n "$COLLISIONS" ]; then
    echo "An application with this display name already exists:" >&2
    printf '  %s\n' $COLLISIONS >&2
    echo "Display names are not unique and do not prove ownership." >&2
    echo "Verify who owns it, then re-run with --app-id <appId> to update it," >&2
    echo "or choose a different --display-name." >&2
    exit 1
  fi
  APP_ID="$(az ad app create --display-name "$DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  echo "Created application: $APP_ID"
fi

az ad app credential reset --id "$APP_ID" --cert "@$CERTIFICATE" --append \
  --only-show-errors -o none
echo "Certificate attached."

SP_ID="$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
if [ -z "$SP_ID" ]; then
  SP_ID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
  echo "Created service principal: $SP_ID"
else
  echo "Reusing service principal: $SP_ID"
fi

GRAPH_SP_ID="$(az ad sp list --filter "appId eq '$GRAPH_APP_ID'" --query "[0].id" -o tsv)"
if [ -z "$GRAPH_SP_ID" ]; then
  echo "Microsoft Graph service principal not found in this tenant." >&2
  exit 1
fi

ROLES_JSON="$(az ad sp show --id "$GRAPH_SP_ID" --query "appRoles[].{value:value,id:id}" -o json)"

failed=0
for permission in "${PERMISSIONS[@]}"; do
  role_id="$(printf '%s' "$ROLES_JSON" | python3 -c '
import json, sys
wanted = sys.argv[1]
for role in json.load(sys.stdin):
    if role["value"] == wanted:
        print(role["id"])
        break
' "$permission")"
  if [ -z "$role_id" ]; then
    echo "  ! $permission — not offered by Microsoft Graph in this tenant" >&2
    failed=1
    continue
  fi
  if az rest --method POST \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
      --headers "Content-Type=application/json" \
      --body "{\"principalId\":\"$SP_ID\",\"resourceId\":\"$GRAPH_SP_ID\",\"appRoleId\":\"$role_id\"}" \
      -o none 2>/dev/null; then
    echo "  + $permission"
  else
    # Already assigned is the common case on re-run; anything else is a real failure.
    if az rest --method GET \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments" \
        --query "[?appRoleId=='$role_id'] | [0].id" -o tsv 2>/dev/null | grep -q .; then
      echo "  = $permission (already assigned)"
    else
      echo "  ! $permission — assignment failed" >&2
      failed=1
    fi
  fi
done

echo
echo "tenant_id: $TENANT_ID"
echo "client_id: $APP_ID"

if [ "$failed" -ne 0 ]; then
  echo "One or more permissions were not assigned." >&2
  exit 1
fi
