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
                          [--azure-config-dir DIR]
                          [--permission Graph.Permission.Name]...
                          [--dry-run]

Options:
  --display-name      Application display name.
  --certificate       Public certificate (.crt/.cer) already generated.
  --azure-config-dir  AZURE_CONFIG_DIR for an isolated Azure CLI login.
  --permission        Graph application permission. Repeatable.
                      Defaults to a read-only tenant health set.
  --dry-run           Print the planned actions and exit.

The signed-in Azure CLI identity must be able to create applications and grant
application permissions (Global Administrator or Privileged Role Administrator).
USAGE
  exit 2
}

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

DISPLAY_NAME=""
CERTIFICATE=""
DRY_RUN="false"
PERMISSIONS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --display-name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --certificate) CERTIFICATE="${2:-}"; shift 2 ;;
    --azure-config-dir) export AZURE_CONFIG_DIR="${2:-}"; shift 2 ;;
    --permission) PERMISSIONS+=("${2:-}"); shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[ -n "$DISPLAY_NAME" ] || usage
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

# Refuse write scopes. A reporting credential that can change the tenant is a
# different risk class, and it is easy to add one by copy-paste.
for permission in "${PERMISSIONS[@]}"; do
  case "$permission" in
    *ReadWrite*|*.Write.*|*.AccessAsUser.*|*.FullControl.*)
      echo "Refusing non read-only permission: $permission" >&2
      echo "Register write access as a separate application with its own approval." >&2
      exit 1
      ;;
  esac
done

TENANT_ID="$(az account show --query tenantId -o tsv)"
SIGNED_IN="$(az account show --query user.name -o tsv)"
echo "Tenant:   $TENANT_ID"
echo "Identity: $SIGNED_IN"
echo "App:      $DISPLAY_NAME"
echo "Permissions (${#PERMISSIONS[@]}):"
printf '  - %s\n' "${PERMISSIONS[@]}"

if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run: no changes made."
  exit 0
fi

APP_ID="$(az ad app list --display-name "$DISPLAY_NAME" --query "[0].appId" -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  echo "Created application: $APP_ID"
else
  echo "Reusing application: $APP_ID"
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
