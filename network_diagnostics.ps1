#Requires -Version 5.1
<#
.SYNOPSIS
    Network diagnostics for RemoteGamepad. Works on both CLIENT and SERVER.
.DESCRIPTION
    Machine roles:
      CLIENT  -- your local PC    -- runs video_receiver.py + controller_udp_sender.py
      SERVER  -- remote/gaming PC -- runs video_udp_sender.py + controller_udp_receiver.py

    Inbound rules required:
      CLIENT needs: UDP 5006 (video frames in)
      SERVER needs: UDP 5005 (controller data in) + UDP 5007 (latency ACKs in)
.PARAMETER SenderIP
    IP address of the other machine. If omitted, you will be prompted.
.PARAMETER Machine
    Which machine this is: CLIENT or SERVER. If omitted, you will be prompted.
.EXAMPLE
    .\network_diagnostics.ps1
    .\network_diagnostics.ps1 192.168.1.50 CLIENT
    .\network_diagnostics.ps1 192.168.1.50 SERVER
#>

param([string]$SenderIP, [string]$Machine)

# -- Ports --------------------------------------------------------------------
$CONTROLLER_PORT = 5005   # server binds (controller data from client)
$VIDEO_PORT      = 5006   # client binds (video from server)
$ACK_PORT        = 5007   # server binds (latency ACKs from client)

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

# -- 0. Collect other machine's IP --------------------------------------------
if (-not $SenderIP) {
    $SenderIP = (Read-Host "Enter the other machine's IP address").Trim()
}
$SenderIP = $SenderIP.Trim()

if ($SenderIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    Write-FAIL "Invalid IP address: '$SenderIP'"
    exit 1
}

# -- 0b. Determine machine role -----------------------------------------------
if ($Machine -notmatch '^(CLIENT|SERVER)$') {
    Write-Host ""
    Write-Host "  Which machine is this?" -ForegroundColor White
    Write-Host "   [C] CLIENT  -- local PC        -- video_receiver.py + controller_udp_sender.py"
    Write-Host "   [S] SERVER  -- remote/gaming PC -- video_udp_sender.py + controller_udp_receiver.py"
    $choice = Read-Host "  Choice"
    $Machine = if ($choice -match '^[Ss]') { "SERVER" } else { "CLIENT" }
}
$Machine = $Machine.ToUpper()

Write-Host ""
Write-Host " RemoteGamepad -- Network Diagnostics ($Machine) " -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "  Other machine IP : $SenderIP"
if ($Machine -eq "CLIENT") {
    Write-Host "  This machine (CLIENT) : video_receiver.py + controller_udp_sender.py"
    Write-Host "  Server machine        : video_udp_sender.py + controller_udp_receiver.py"
} else {
    Write-Host "  This machine (SERVER) : video_udp_sender.py + controller_udp_receiver.py"
    Write-Host "  Client machine        : video_receiver.py + controller_udp_sender.py"
}

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
        Write-OK "Other machine appears to be on the same LAN subnet ($($addr.IPAddress)/$maskBits)"
        $onSameLAN = $true
        break
    }
}
if (-not $onSameLAN) {
    Write-WARN "Other machine appears to be on a different subnet -- NAT/routing will be involved"
    Write-INFO "  Make sure port forwarding is configured on the server's router for UDP 5005 and 5007."
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

Write-INFO "  Testing path MTU to other machine (DF-bit ping)..."
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
# 4. WINDOWS FIREWALL -- INBOUND RULES
# -----------------------------------------------------------------------------
Write-Section "4. Windows Firewall -- Inbound Rules"

$activeProfiles = Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $true }
if (-not $activeProfiles) {
    Write-WARN "Windows Firewall is disabled on all profiles -- no rules needed, but also no protection"
} else {
    Write-INFO "  Firewall active on: $(($activeProfiles.Name) -join ", ")"
}

# Strict match: require explicit UDP protocol AND exact port number.
# Broad catch-all rules (Protocol=Any or LocalPort=Any) are intentionally
# ignored -- they produce false positives (e.g. Wi-Fi Direct Spooler) and
# don't confirm that the specific port is intentionally open.
function Find-InboundUDPRule([int]$port) {
    $rules = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue
    foreach ($rule in $rules) {
        $pf = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        if ($pf -and $pf.Protocol -eq "UDP" -and $pf.LocalPort -eq "$port") {
            return $rule.DisplayName
        }
    }
    return $null
}

function Invoke-CreateFirewallRule([int]$port, [string]$label) {
    $displayName = "RemoteGamepad $label UDP $port"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        try {
            New-NetFirewallRule -DisplayName $displayName `
                -Direction Inbound -Protocol UDP -LocalPort $port `
                -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-OK "Rule created: $displayName"
        } catch {
            Write-FAIL "Could not create rule: $($_.Exception.Message)"
        }
    } else {
        $cmd = "New-NetFirewallRule -DisplayName '$displayName' " +
               "-Direction Inbound -Protocol UDP -LocalPort $port -Action Allow -Profile Any | Out-Null; " +
               "Write-Host 'Done.' -ForegroundColor Green; Read-Host"
        Write-INFO "  Launching elevated PowerShell to create rule..."
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -Command `"$cmd`""
        Write-INFO "  Rule will be created in the elevated window."
    }
}

function Test-AndPromptRule([int]$port, [string]$label) {
    Write-Host -NoNewline "  Checking UDP $port ($label, inbound)... " -ForegroundColor Gray
    $ruleName = Find-InboundUDPRule -port $port
    if ($ruleName) {
        Write-Host "[OK]  Rule: $ruleName" -ForegroundColor Green
        return $true
    } else {
        Write-Host "[MISSING]" -ForegroundColor Red
        return $false
    }
}

if ($Machine -eq "CLIENT") {
    Write-INFO "  CLIENT needs inbound: UDP $VIDEO_PORT (video)."
    Write-INFO "  UDP $CONTROLLER_PORT and $ACK_PORT are outbound-only from this machine."
    $rule5006Found = Test-AndPromptRule -port $VIDEO_PORT -label "Video frames"
} else {
    Write-INFO "  SERVER needs inbound: UDP $CONTROLLER_PORT (controller) and UDP $ACK_PORT (ACKs)."
    Write-INFO "  UDP $VIDEO_PORT is outbound-only from this machine (video sent to client)."
    $rule5005Found = Test-AndPromptRule -port $CONTROLLER_PORT -label "Controller data"
    $rule5007Found = Test-AndPromptRule -port $ACK_PORT        -label "Latency ACKs"
}

# -----------------------------------------------------------------------------
# 5. PORT AVAILABILITY -- IS ANYTHING ALREADY BOUND?
# -----------------------------------------------------------------------------
Write-Section "5. Port Availability (is anything already listening?)"

$netstatOutput = netstat -an -p UDP

function Test-PortBound([int]$port, [string]$scriptName, [bool]$shouldBind) {
    $bound = $netstatOutput | Select-String "[\s:]$port\s"
    if ($bound) {
        if ($shouldBind) {
            Write-OK "UDP $port -- already bound ($scriptName may be running)"
        } else {
            Write-WARN "UDP $port -- already bound locally (another app may interfere)"
        }
    } else {
        if ($shouldBind) {
            try {
                $sock = New-Object System.Net.Sockets.UdpClient($port)
                $sock.Close()
                Write-INFO "  UDP $port -- not bound; ready for $scriptName to use"
            } catch {
                Write-WARN "UDP $port -- bind failed: port already in use by another app"
            }
        } else {
            Write-INFO "  UDP $port -- not bound locally (correct -- this machine sends to this port, never binds it)"
        }
    }
}

if ($Machine -eq "CLIENT") {
    Test-PortBound -port $VIDEO_PORT       -scriptName "video_receiver.py"       -shouldBind $true
    Test-PortBound -port $CONTROLLER_PORT  -scriptName "controller_udp_sender.py" -shouldBind $false
    Test-PortBound -port $ACK_PORT         -scriptName "video_receiver.py"        -shouldBind $false
} else {
    Test-PortBound -port $CONTROLLER_PORT  -scriptName "controller_udp_receiver.py" -shouldBind $true
    Test-PortBound -port $ACK_PORT         -scriptName "video_udp_sender.py"        -shouldBind $true
    Test-PortBound -port $VIDEO_PORT       -scriptName "video_udp_sender.py"        -shouldBind $false
}

# -----------------------------------------------------------------------------
# 6. ROUTE TRACE
# -----------------------------------------------------------------------------
Write-Section "6. Route to Other Machine (up to 10 hops)"

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

if ($Machine -eq "CLIENT") {
    Write-Host "  Port layout (CLIENT perspective):" -ForegroundColor White
    Write-Host "    5005/UDP  Controller data  CLIENT sends --> server  " -NoNewline
    Write-Host "[rule needed on SERVER]" -ForegroundColor Yellow
    Write-Host "    5006/UDP  Video frames     CLIENT listens <-- server " -NoNewline
    if ($rule5006Found) { Write-Host "[OK]" -ForegroundColor Green } else { Write-Host "[MISSING]" -ForegroundColor Red }
    Write-Host "    5007/UDP  Latency ACKs     CLIENT sends --> server  " -NoNewline
    Write-Host "[rule needed on SERVER]" -ForegroundColor Yellow
    Write-Host ""

    if (-not $rule5006Found) {
        Write-WARN "UDP $VIDEO_PORT has no inbound rule -- video stream will not work."
        Write-Host ""
        Write-Host "  Create the inbound rule for UDP $VIDEO_PORT now? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            Invoke-CreateFirewallRule -port $VIDEO_PORT -label "Video Stream"
        }
    } else {
        Write-OK "Firewall is set up correctly for this CLIENT machine."
    }
} else {
    Write-Host "  Port layout (SERVER perspective):" -ForegroundColor White
    Write-Host "    5005/UDP  Controller data  SERVER listens <-- client " -NoNewline
    if ($rule5005Found) { Write-Host "[OK]" -ForegroundColor Green } else { Write-Host "[MISSING]" -ForegroundColor Red }
    Write-Host "    5006/UDP  Video frames     SERVER sends --> client  " -NoNewline
    Write-Host "[rule needed on CLIENT]" -ForegroundColor Yellow
    Write-Host "    5007/UDP  Latency ACKs     SERVER listens <-- client " -NoNewline
    if ($rule5007Found) { Write-Host "[OK]" -ForegroundColor Green } else { Write-Host "[MISSING]" -ForegroundColor Red }
    Write-Host ""

    $anyMissing = (-not $rule5005Found) -or (-not $rule5007Found)
    if ($anyMissing) {
        $missingList = @()
        if (-not $rule5005Found) { $missingList += "UDP $CONTROLLER_PORT (Controller data)" }
        if (-not $rule5007Found) { $missingList += "UDP $ACK_PORT (Latency ACKs)" }
        Write-WARN "Missing inbound rules: $($missingList -join ", ")"
        Write-Host ""
        Write-Host "  Create the missing rules now? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            if (-not $rule5005Found) { Invoke-CreateFirewallRule -port $CONTROLLER_PORT -label "Controller Data" }
            if (-not $rule5007Found) { Invoke-CreateFirewallRule -port $ACK_PORT        -label "Latency ACKs"   }
        }
    } else {
        Write-OK "Firewall is set up correctly for this SERVER machine."
    }
}

Write-Host ""
Write-Host "  Other tips:" -ForegroundColor White
Write-Host "    * Run this script on the other machine too to check its firewall rules"
Write-Host "    * High latency / many hops  -> prefer wired Ethernet or same LAN"
Write-Host "    * MTU issues                -> run setup_jumbo_frames.ps1 on both machines (LAN only)"
Write-Host ""
