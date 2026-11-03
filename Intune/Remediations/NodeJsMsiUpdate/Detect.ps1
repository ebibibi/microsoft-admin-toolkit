# shared by Detect.ps1 and Remediate.ps1 (inlined at build time)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Get-InstalledNode {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Node.js' -and $_.DisplayVersion } |
        Sort-Object { [version]$_.DisplayVersion } -Descending | Select-Object -First 1
}
function Get-LatestInLine([int]$Major) {
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing -TimeoutSec 60
    $index | Where-Object { $_.version -match "^v$Major\.\d+\.\d+$" } |
        Sort-Object { [version]$_.version.TrimStart('v') } -Descending | Select-Object -First 1
}
try {
    $node = Get-InstalledNode
    if (-not $node) { Write-Output 'Node.js (MSI) not installed - nothing to update.'; exit 0 }
    $installed = [version]$node.DisplayVersion
    $latest = Get-LatestInLine $installed.Major
    if (-not $latest) { Write-Output "No release found for Node.js $($installed.Major).x"; exit 0 }
    $target = [version]$latest.version.TrimStart('v')
    if ($installed -lt $target) { Write-Output "Node.js $installed is older than $target."; exit 1 }
    Write-Output "Node.js $installed is the latest $($installed.Major).x."
    exit 0
}
catch { Write-Output "Detection error: $($_.Exception.Message)"; exit 1 }
