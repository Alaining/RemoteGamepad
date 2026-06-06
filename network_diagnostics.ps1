#Requires -Version 5.1
<#
.SYNOPSIS
    Network diagnostics for RemoteGamepad -- run on the RECEIVER machine.
.DESCRIPTION
    Machine roles:
      RECEIVER  -- your local PC  -- runs video_receiver.py + controller_udp_sender.py
      SENDER    -- remote/gaming PC -- runs video_udp_sender.py + controller_udp_receiver.py

    Port layout from the RECEIVER's perspective:
      5005/UDP  controller data  -- RECEIVER sends OUT to sender  (no inbound rule needed here)
      5006/UDP  video frames     -- RECEIVER listens IN from sender (inbound rule required here)
      5007/UDP  latency ACKs     -- RECEIVER sends OUT to sender  (no inbound rule needed here)
.PARAMETER SenderIP
    IP address of the sender machine. If omitted, you will be prompted.
.EXAMPLE
    .\network_diagnostics.ps1
    .\network_diagnostics.ps1 192.168.1.50
#>

param([string]$SenderIP)

# -- Ports --------------------------------------------------------------------
$CONTROLLER_PORT = 5005   # receiver sends OUT to sender (sender binds this)
$VIDEO_PORT      = 5006   # receiver binds IN (video from sender)
$ACK_PORT        = 5007   # receiver sends OUT to sender (sender binds this)

# -- Console helpers ----------------------------------------------------------
function Write-Section([string]$title) {
    $line = "-" * [Math]::Max(2, 62 - $title.Length)
    Write-Host ""
    Write-Host "  $title $line" -ForegroundColor Cyan
}
function Write-OK([string]$msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-WARN([string]$msg) { Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function Write-FAIL([string]$msg) { Write-Host "  [X]   $msg" -ForegroundColor Red    }
function Write-INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor Gray   }

# -- 0. Collect sender IP -----------------------------------------------------
if (-not $SenderIP) {
    $SenderIP = (Read-Host "Enter the SENDER machine's IP address").Trim()
}
$SenderIP = $SenderIP.Trim()

if ($SenderIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    Write-FAIL "Invalid IP address: '$SenderIP'"
    exit 1
}

Write-Host ""
Write-Host " RemoteGamepad -- Network Diagnostics (RECEIVER side) " -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "  Sender IP : $SenderIP"
Write-Host "  This machine (RECEIVER) : video_receiver.py + controller_udp_sender.py"
Write-Host "  Sender machine          : video_udp_sender.py + controller_udp_receiver.py"

# -----------------------------------------------------------------------------
# 1. PING
# -----------------------------------------------------------------------------
Write-Section "1. Ping"

$pings = Test-Connection -ComputerName $SenderIP -Count 6 -ErrorAction SilentlyContinue
if (-not $pings) {
    Write-FAIL "Ping failed -- host unreachable or ICMP blocked on the path"
    Write-INFO "  UDP may still work if only ICMP is blocked, but connectivity is uncertain."
} else {
    $rtts = $pings | ForEach-Object { $_.ResponseTime }
    $avg  = [Math]::Round(($rtts | Measure-Object -Average).Average, 1)
    $min  = ($rtts | Measure-Object -Minimum).Minimum
    $max  = ($rtts | Measure-Object -Maximum).Maximum
    $recv = $pings.Count

    Write-OK "Host reachable -- $recv/6 replies"
    Write-INFO "  RTT  min=${min}ms   avg=${avg}ms   max=${max}ms"

    if ($recv -lt 6) {
        Write-WARN "Packet loss: $(6 - $recv)/6 pings dropped -- unstable path"
    }
    if ($avg -le 5)       { Write-OK   "  Latency looks excellent (LAN-grade)" }
    elseif ($avg -le 30)  { Write-WARN "  Moderate latency -- input feel may vary" }
    else                  { Write-FAIL "  High latency (${avg}ms avg) -- expect noticeable input lag" }
}

# -----------------------------------------------------------------------------
# 2. LOCAL NETWORK INTERFACE
# -----------------------------------------------------------------------------
Write-Section "2. Local Network Interface"

$localAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }

foreach ($addr in $localAddresses) {
    $adapter     = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction SilentlyContinue
    $adapterName = if ($adapter) { $adapter.Name }      else { "?" }
    $status      = if ($adapter) { $adapter.LinkSpeed } else { "?" }
    Write-INFO "  [$adapterName]  $($addr.IPAddress)/$($addr.PrefixLength)   $status"
}

# Same-subnet heuristic (works for /16 and /24)
$senderOctets = $SenderIP.Split(".")
$onSameLAN = $false
foreach ($addr in $localAddresses) {
    $maskBits    = $addr.PrefixLength
    $localOctets = $addr.IPAddress.Split(".")
    $sharedBytes = [Math]::Floor($maskBits / 8)
    if ($sharedBytes -ge 2 -and
        ($localOctets[0..($sharedBytes-1)] -join ".") -eq ($senderOctets[0..($sharedBytes-1)] -join ".")) {
        Write-OK "Sender appears to be on the same LAN subnet ($($addr.IPAddress)/$maskBits)"
        $onSameLAN = $true
        break
    }
}
if (-not $onSameLAN) {
    Write-WARN "Sender appears to be on a different subnet -- NAT/routing will be involved"
    Write-INFO "  Make sure port forwarding is configured on the sender's router for UDP 5005 and 5007."
}

# -----------------------------------------------------------------------------
# 3. MTU / JUMBO FRAMES
# -----------------------------------------------------------------------------
Write-Section "3. MTU / Jumbo Frames"

$upInterfaces = Get-NetIPInterface -AddressFamily IPv4 |
    Where-Object { $_.NlMtu -gt 0 }

foreach ($iface in $upInterfaces) {
    $adapter = Get-NetAdapter -InterfaceIndex $iface.InterfaceIndex -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") {
        $mtu = $iface.NlMtu
        if ($mtu -ge 9000) {
            Write-OK "[$($adapter.Name)] MTU = $mtu  (jumbo frames ENABLED)"
        } elseif ($mtu -ge 1500) {
            Write-INFO "  [$($adapter.Name)] MTU = $mtu  (standard Ethernet)"
        }
    }
}

$udpMax = 65535 - 20 - 8 - 12   # IP - UDP - RemoteGamepad frame header
Write-INFO "  Max usable UDP payload : $udpMax bytes"
Write-INFO "  MJPEG frames at 480p are typically 10-50 KB -- well within the limit"

# Test path MTU using ping with Don't-Fragment bit
Write-INFO "  Testing path MTU to sender (DF-bit ping)..."
$pmtuOk = $false
foreach ($size in @(1472, 1400, 1000)) {
    # -f sets DF bit; -l sets payload size
    $result = ping.exe -n 1 -f -l $size $SenderIP
    if ($result -match "Reply from") {
        Write-OK "  Path MTU >= $($size + 28) bytes (payload $size + 28 IP/UDP overhead)"
        $pmtuOk = $true
        break
    }
}
if (-not $pmtuOk) {
    Write-WARN "  Path MTU may be less than 1028 bytes -- fragmentation likely"
}

# -----------------------------------------------------------------------------
# 4. WINDOWS FIREWALL -- INBOUND RULES (RECEIVER side)
# -----------------------------------------------------------------------------
Write-Section "4. Windows Firewall -- Inbound Rules"

$activeProfiles = Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $true }
if (-not $activeProfiles) {
    Write-WARN "Windows Firewall is disabled on all profiles -- no rules needed, but also no protection"
} else {
    Write-INFO "  Firewall active on: $(($activeProfiles.Name) -join ", ")"
}

Write-INFO "  Only UDP $VIDEO_PORT (video) needs an inbound rule here."
Write-INFO "  UDP $CONTROLLER_PORT and $ACK_PORT are outbound-only from this machine -- no inbound rules needed."

function Find-InboundUDPRule([int]$port) {
    $rules = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue
    foreach ($rule in $rules) {
        $pf = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($pf -and
            ($pf.Protocol -eq "UDP" -or $pf.Protocol -eq "Any") -and
            ($pf.LocalPort -eq "$port" -or $pf.LocalPort -eq "Any")) {
            return $rule.DisplayName
        }
    }
    return $null
}

Write-Host -NoNewline "  Checking UDP $VIDEO_PORT (video frames, inbound)... " -ForegroundColor Gray
$ruleName = Find-InboundUDPRule -port $VIDEO_PORT
if ($ruleName) {
    Write-Host "[OK]  Rule: $ruleName" -ForegroundColor Green
    $missingVideo = $false
} else {
    Write-Host "[MISSING]" -ForegroundColor Red
    $missingVideo = $true
}

if ($missingVideo) {
    Write-Host ""
    Write-WARN "Missing inbound firewall rule for UDP $VIDEO_PORT"
    Write-Host ""
    Write-Host "  Create the missing rule now?" -ForegroundColor Yellow
    Write-Host "   [Y] Yes -- open an elevated window and create it"
    Write-Host "   [N] No  -- skip (you can re-run this script later)"
    $answer = Read-Host "  Choice"

    if ($answer -match "^[Yy]") {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

        if ($isAdmin) {
            try {
                New-NetFirewallRule `
                    -DisplayName "RemoteGamepad Video Stream UDP $VIDEO_PORT" `
                    -Direction Inbound -Protocol UDP -LocalPort $VIDEO_PORT `
                    -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                Write-OK "Created inbound rule for UDP $VIDEO_PORT"
            } catch {
                Write-FAIL "Could not create rule: $($_.Exception.Message)"
            }
        } else {
            $cmd = "New-NetFirewallRule -DisplayName 'RemoteGamepad Video Stream UDP $VIDEO_PORT' " +
                   "-Direction Inbound -Protocol UDP -LocalPort $VIDEO_PORT -Action Allow -Profile Any | Out-Null; " +
                   "Write-Host 'Done.' -ForegroundColor Green; Read-Host"
            Write-INFO "  Launching elevated PowerShell to create rule..."
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -Command `"$cmd`""
            Write-INFO "  Rule will be created in the elevated window. Re-run this script to verify."
        }
    }
}

Write-Host ""
Write-WARN "Remember: UDP $CONTROLLER_PORT and $ACK_PORT need inbound rules on the SENDER machine, not here."

# -----------------------------------------------------------------------------
# 5. PORT AVAILABILITY -- IS ANYTHING ALREADY BOUND?
# -----------------------------------------------------------------------------
Write-Section "5. Port Availability (is anything already listening?)"

$netstatOutput = netstat -an -p UDP

# UDP 5006 is the only port the receiver binds
$bound = $netstatOutput | Select-String "[\s:]$VIDEO_PORT\s"
if ($bound) {
    Write-OK "UDP $VIDEO_PORT -- already bound (video_receiver.py may be running)"
} else {
    try {
        $sock = New-Object System.Net.Sockets.UdpClient($VIDEO_PORT)
        $sock.Close()
        Write-INFO "  UDP $VIDEO_PORT -- not bound; ready for video_receiver.py to use"
    } catch {
        Write-WARN "UDP $VIDEO_PORT -- bind failed: port already in use by another app"
    }
}

# 5005 and 5007 are outbound -- just check nothing else grabbed them locally
foreach ($port in @($CONTROLLER_PORT, $ACK_PORT)) {
    $abound = $netstatOutput | Select-String "[\s:]$port\s"
    if ($abound) {
        Write-WARN "UDP $port -- already bound locally (another app may interfere with outbound traffic)"
    } else {
        Write-INFO "  UDP $port -- not bound locally (correct -- this machine sends to sender:$port, never binds it)"
    }
}

# -----------------------------------------------------------------------------
# 6. ROUTE TRACE
# -----------------------------------------------------------------------------
Write-Section "6. Route to Sender (up to 10 hops)"

try {
    $trace = Test-NetConnection -ComputerName $SenderIP -TraceRoute -Hops 10 `
        -WarningAction SilentlyContinue -ErrorAction Stop
    $hops = $trace.TraceRoute | Where-Object { $_ -ne "0.0.0.0" -and $_ -ne "::" }
    if ($hops) {
        $n = 1
        foreach ($h in $hops) { Write-INFO "  Hop $n : $h"; $n++ }
        $hopCount = @($hops).Count
        if ($hopCount -eq 1)      { Write-OK   "Direct connection ($hopCount hop) -- same LAN or VPN tunnel" }
        elseif ($hopCount -le 3)  { Write-OK   "Short route ($hopCount hops)" }
        elseif ($hopCount -le 6)  { Write-WARN "Medium route ($hopCount hops) -- may introduce jitter" }
        else                      { Write-FAIL "Long route ($hopCount hops) -- high jitter risk for real-time input" }
    } else {
        Write-INFO "  Route data not available (hops may be blocking ICMP TTL-exceeded)"
    }
} catch {
    Write-INFO "  Traceroute failed or timed out: $($_.Exception.Message)"
}

# -----------------------------------------------------------------------------
# 7. SUMMARY
# -----------------------------------------------------------------------------
Write-Section "7. Summary"
Write-Host ""
Write-Host "  Port layout (RECEIVER perspective):" -ForegroundColor White
Write-Host "    5005/UDP  Controller data  RECEIVER sends --> sender  (inbound rule needed on SENDER)"
Write-Host "    5006/UDP  Video frames     RECEIVER listens <-- sender (inbound rule needed HERE)"
Write-Host "    5007/UDP  Latency ACKs     RECEIVER sends --> sender  (inbound rule needed on SENDER)"
Write-Host ""
Write-Host "  If any tests failed:" -ForegroundColor White
Write-Host "    * Missing inbound rule for 5006  -> re-run this script and choose Y when prompted"
Write-Host "    * Rules for 5005 and 5007        -> run this script on the SENDER machine"
Write-Host "    * High latency / many hops       -> prefer wired Ethernet or same LAN"
Write-Host "    * MTU issues                     -> run setup_jumbo_frames.ps1 on both machines (LAN only)"
Write-Host "    * Bind failure on 5006           -> stop any running video_receiver.py first"
Write-Host ""
