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
    if (-not $node) { Write-Output 'Node.js (MSI) not installed.'; exit 0 }
    $installed = [version]$node.DisplayVersion
    $latest = Get-LatestInLine $installed.Major
    $ver = $latest.version
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $file = "node-$ver-$arch.msi"
    $base = "https://nodejs.org/dist/$ver"
    $dir = Join-Path $env:ProgramData 'NodeLtsUpdate'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $msi = Join-Path $dir $file
    Invoke-WebRequest -Uri "$base/$file" -OutFile $msi -UseBasicParsing -TimeoutSec 600
    $sums = (Invoke-WebRequest -Uri "$base/SHASUMS256.txt" -UseBasicParsing -TimeoutSec 60).Content
    $line = ($sums -split "`n") | Where-Object { $_ -match "\s$([regex]::Escape($file))$" } | Select-Object -First 1
    if (-not $line) { throw "SHASUMS256.txt has no entry for $file" }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Path $msi -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { throw "SHA-256 mismatch for $file" }
    $sig = Get-AuthenticodeSignature -FilePath $msi
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'OpenJS Foundation') {
        throw "Signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit code $($p.ExitCode)" }
    Write-Output "Node.js $installed -> $ver (msiexec $($p.ExitCode))."
    exit 0
}
catch { Write-Output "Remediation error: $($_.Exception.Message)"; exit 1 }
