<#
.SYNOPSIS
    Intune Remediation detection: is the machine-wide Scancode Map set as expected?
.DESCRIPTION
    Default mapping is one-way: the physical CapsLock key sends Right Ctrl (used
    by Fakeymacs with fc.side_of_ctrl_key = "R"). Right Ctrl stays Right Ctrl,
    so no key sends CapsLock. Add entries to $Mappings for a full swap.
    Run as SYSTEM, 64-bit PowerShell. Exit 0 = compliant, 1 = remediation needed.
    Keep $Mappings identical in Remediate.ps1.
#>
$ErrorActionPreference = 'Stop'

# Each entry: physical key scan code (From) -> scan code Windows receives (To).
# Extended keys use the 0xE0 prefix in the high byte (Right Ctrl = 0xE01D).
$Mappings = @(
    @{ From = 0x003A; To = 0xE01D }  # CapsLock   -> Right Ctrl
)
$KeyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'

function ConvertTo-ScancodeMap {
    param([hashtable[]]$Map)
    # Layout: 4-byte version (0), 4-byte flags (0), 4-byte count (entries + null
    # terminator), then 4 bytes per entry (To little-endian, From little-endian),
    # then a 4-byte null terminator.
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.AddRange([byte[]](0, 0, 0, 0, 0, 0, 0, 0))
    $bytes.AddRange([BitConverter]::GetBytes([uint32]($Map.Count + 1)))
    foreach ($m in $Map) {
        $bytes.AddRange([BitConverter]::GetBytes([uint16]$m.To))
        $bytes.AddRange([BitConverter]::GetBytes([uint16]$m.From))
    }
    $bytes.AddRange([byte[]](0, 0, 0, 0))
    return , $bytes.ToArray()
}

try {
    $expected = ConvertTo-ScancodeMap -Map $Mappings
    $current = (Get-ItemProperty -Path $KeyPath -Name 'Scancode Map' -ErrorAction SilentlyContinue).'Scancode Map'
    if ($null -eq $current) {
        Write-Output 'Scancode Map is not set.'
        exit 1
    }
    $expectedHex = ($expected | ForEach-Object { '{0:x2}' -f $_ }) -join ','
    $currentHex = ([byte[]]$current | ForEach-Object { '{0:x2}' -f $_ }) -join ','
    if ($currentHex -ne $expectedHex) {
        Write-Output "Scancode Map differs: $currentHex"
        exit 1
    }
    Write-Output 'Scancode Map matches (applies after a restart).'
    exit 0
}
catch {
    Write-Output "Detection error: $($_.Exception.Message)"
    exit 1
}
