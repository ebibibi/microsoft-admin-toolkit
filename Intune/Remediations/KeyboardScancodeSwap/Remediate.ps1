<#
.SYNOPSIS
    Intune Remediation: write the machine-wide Scancode Map.
.DESCRIPTION
    Default mapping sends Right Ctrl from CapsLock (one-way). Run as SYSTEM, 64-bit
    PowerShell. The change applies to every user of the device and needs a
    restart. Keep $Mappings identical in Detect.ps1.
#>
$ErrorActionPreference = 'Stop'

$Mappings = @(
    @{ From = 0x003A; To = 0xE01D }  # CapsLock   -> Right Ctrl
)
$KeyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout'

function ConvertTo-ScancodeMap {
    param([hashtable[]]$Map)
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
    $value = ConvertTo-ScancodeMap -Map $Mappings
    New-ItemProperty -Path $KeyPath -Name 'Scancode Map' -PropertyType Binary -Value $value -Force | Out-Null
    Write-Output 'Scancode Map written. Restart the device to apply.'
    exit 0
}
catch {
    Write-Output "Remediation error: $($_.Exception.Message)"
    exit 1
}
