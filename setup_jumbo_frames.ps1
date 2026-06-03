#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enable or revert jumbo frames (MTU 9000) on physical Ethernet adapters.

.PARAMETER Revert
    Restore standard MTU (1514) instead of setting jumbo frames.

.EXAMPLE
    .\setup_jumbo_frames.ps1           # enable jumbo frames
    .\setup_jumbo_frames.ps1 -Revert   # restore standard MTU
#>

param([switch]$Revert)

$JUMBO    = 9014   # 9000-byte payload + 14-byte Ethernet header
$STANDARD = 1514   # 1500-byte payload + 14-byte Ethernet header
$KEYWORD  = "JumboPacket"

$targetValue = if ($Revert) { $STANDARD } else { $JUMBO }
$actionLabel = if ($Revert) { "REVERT to standard MTU ($STANDARD)" } else { "ENABLE jumbo frames ($JUMBO)" }
$color       = if ($Revert) { "Yellow" } else { "Green" }

Write-Host ""
Write-Host "Action: $actionLabel" -ForegroundColor $color
Write-Host ""

# All non-virtual, non-loopback adapters
$adapters = Get-NetAdapter | Where-Object {
    $_.InterfaceDescription -notmatch "Loopback|Hyper-V|Virtual|Bluetooth|Tunnel|WAN"
} | Sort-Object Name

if (-not $adapters) {
    Write-Host "No adapters found." -ForegroundColor Red
    exit 1
}

$changed = 0
foreach ($adapter in $adapters) {
    $name = $adapter.Name
    $desc = $adapter.InterfaceDescription

    # Check if this adapter has a JumboPacket property at all
    $prop = Get-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $KEYWORD -ErrorAction SilentlyContinue
    if (-not $prop) {
        Write-Host "  SKIP  [$name] ($desc) — no JumboPacket support (likely WiFi)" -ForegroundColor DarkGray
        continue
    }

    $current = [int]$prop.RegistryValue
    if ($current -eq $targetValue) {
        Write-Host "  OK    [$name] already at $current — no change" -ForegroundColor DarkGray
        continue
    }

    try {
        Set-NetAdapterAdvancedProperty -Name $name -RegistryKeyword $KEYWORD -RegistryValue $targetValue -ErrorAction Stop
        # Briefly restart the adapter to apply the new MTU
        Restart-NetAdapter -Name $name -Confirm:$false
        Write-Host "  SET   [$name] $current -> $targetValue (adapter restarted)" -ForegroundColor $color
        $changed++
    } catch {
        Write-Host "  FAIL  [$name] $_" -ForegroundColor Red
    }
}

Write-Host ""
if ($changed -gt 0) {
    Write-Host "$changed adapter(s) updated." -ForegroundColor $color
    Write-Host "Run the same script on the OTHER machine too." -ForegroundColor Cyan
} else {
    Write-Host "No adapters were changed." -ForegroundColor DarkGray
}

if (-not $Revert) {
    Write-Host ""
    Write-Host "To revert:  .\setup_jumbo_frames.ps1 -Revert" -ForegroundColor DarkGray
}
Write-Host ""
