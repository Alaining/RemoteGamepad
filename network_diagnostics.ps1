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

# -- Issue flags (set during checks, used to filter summary tips) -------------
$pingIssue      = $false
$mtuIssue       = $false
$routeIssue     = $false

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

# -- 0c. Identify the network interface used to reach the other machine -------
$routeInfo       = Find-NetRoute -RemoteIPAddress $SenderIP -ErrorAction SilentlyContinue | Select-Object -First 1
$relevantIfIndex = if ($routeInfo) { $routeInfo.InterfaceIndex } else { $null }

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
    $pingIssue = $true
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
        $pingIssue = $true
    }
    if ($avg -le 5)       { Write-OK   "  Latency looks excellent (LAN-grade)" }
    elseif ($avg -le 30)  { Write-WARN "  Moderate latency -- input feel may vary"; $pingIssue = $true }
    else                  { Write-FAIL "  High latency (${avg}ms avg) -- expect noticeable input lag"; $pingIssue = $true }
}

# -----------------------------------------------------------------------------
# 2. LOCAL NETWORK INTERFACE
# -----------------------------------------------------------------------------
Write-Section "2. Local Network Interface"

$allLocalAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }

# Filter to the single interface used to reach the other machine
if ($relevantIfIndex) {
    $localAddresses = @($allLocalAddresses | Where-Object { $_.InterfaceIndex -eq $relevantIfIndex })
    if (-not $localAddresses) { $localAddresses = $allLocalAddresses }  # fallback
} else {
    $localAddresses = $allLocalAddresses
}

foreach ($addr in $localAddresses) {
    $adapter     = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction SilentlyContinue
    $adapterName = if ($adapter) { $adapter.Name }      else { "?" }
    $linkSpeed   = if ($adapter) { $adapter.LinkSpeed } else { "?" }
    Write-OK "[$adapterName]  $($addr.IPAddress)/$($addr.PrefixLength)   $linkSpeed"
    if ($routeInfo -and $routeInfo.NextHop -and $routeInfo.NextHop -ne "0.0.0.0") {
        Write-INFO "  Gateway: $($routeInfo.NextHop)"
    }
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
        Write-OK "Other machine is on the same LAN subnet"
        $onSameLAN = $true
        break
    }
}
if (-not $onSameLAN) {
    Write-WARN "Other machine is on a different subnet -- NAT/routing involved"
    Write-INFO "  Make sure port forwarding is configured on the server's router for UDP 5005 and 5007."
}

# -----------------------------------------------------------------------------
# 3. MTU / JUMBO FRAMES
# -----------------------------------------------------------------------------
Write-Section "3. MTU / Jumbo Frames"

# Show MTU only for the interface being used
$allIfaces = Get-NetIPInterface -AddressFamily IPv4 | Where-Object { $_.NlMtu -gt 0 }
if ($relevantIfIndex) {
    $relevantIfaces = @($allIfaces | Where-Object { $_.InterfaceIndex -eq $relevantIfIndex })
    if (-not $relevantIfaces) { $relevantIfaces = $allIfaces }
} else {
    $relevantIfaces = $allIfaces
}

foreach ($iface in $relevantIfaces) {
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
    $result = ping.exe -n 1 -f -l $size $SenderIP
    if ($result -match "Reply from") {
        Write-OK "  Path MTU >= $($size + 28) bytes"
        $pmtuOk = $true
        break
    }
}
if (-not $pmtuOk) {
    Write-WARN "  Path MTU may be less than 1028 bytes -- fragmentation likely"
    $mtuIssue = $true
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

# Strict match: Protocol must be UDP and LocalPort must be the exact port.
# Catch-all rules (Protocol=Any or LocalPort=Any) are ignored to avoid
# false positives from unrelated Windows rules (e.g. Wi-Fi Direct Spooler).
# One bulk Get-NetFirewallPortFilter call rather than one per rule avoids the
# per-rule CIM overhead that made this slow on systems with many rules.
function Find-InboundUDPRule([int]$port) {
    $found = Get-NetFirewallPortFilter -Protocol UDP -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -eq "$port" } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and $_.Enabled -eq $true }
    if ($found) { return @($found)[0].DisplayName }
    return $null
}

function Invoke-CreateFirewallRule([int]$port, [string]$label) {
    # Re-check: another rule may already cover this port (e.g. created between
    # the earlier lookup and the user answering the prompt).
    $existing = Find-InboundUDPRule -port $port
    if ($existing) {
        Write-OK "Rule already exists: $existing  (no action taken)"
        return
    }

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

    # Live UDP frame test: try to receive a frame on 5006 for up to 2 seconds.
    # This confirms the firewall rule actually lets traffic through end-to-end.
    # Short timeout so we don't stall if the server is not currently streaming.
    Write-Host -NoNewline "  Live frame test on UDP $VIDEO_PORT (2s timeout)... " -ForegroundColor Gray
    try {
        $liveTest = New-Object System.Net.Sockets.UdpClient($VIDEO_PORT)
        $liveTest.Client.ReceiveTimeout = 2000
        try {
            $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $liveTest.Receive([ref]$ep)
            Write-Host "[OK]  Frame received from $($ep.Address) -- end-to-end confirmed!" -ForegroundColor Green
        } catch [System.Net.Sockets.SocketException] {
            Write-Host "no frames in 2s" -ForegroundColor Yellow
            Write-INFO "  Server may not be streaming yet -- that is fine"
        }
        $liveTest.Close()
    } catch {
        Write-Host "port busy (video_receiver.py may already be running)" -ForegroundColor Yellow
    }
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
            Write-INFO "  UDP $port -- not bound locally (correct -- outbound only)"
        }
    }
}

if ($Machine -eq "CLIENT") {
    Test-PortBound -port $VIDEO_PORT       -scriptName "video_receiver.py"        -shouldBind $true
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
        elseif ($hopCount -le 6)  { Write-WARN "Medium route ($hopCount hops) -- may introduce jitter"; $routeIssue = $true }
        else                      { Write-FAIL "Long route ($hopCount hops) -- high jitter risk"; $routeIssue = $true }
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
        Write-WARN "No inbound rule found for UDP $VIDEO_PORT (video)."
        Write-INFO "  This may block video -- but the server might simply not be streaming yet."
        Write-INFO "  Only create a rule if you are sure one is missing."
        Write-Host ""
        Write-Host "  Create an inbound allow rule for UDP $VIDEO_PORT now? [Y/N]" -ForegroundColor Yellow
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
        if (-not $rule5005Found) { $missingList += "UDP $CONTROLLER_PORT (controller data)" }
        if (-not $rule5007Found) { $missingList += "UDP $ACK_PORT (latency ACKs)" }
        Write-WARN "No inbound rules found for: $($missingList -join ", ")"
        Write-INFO "  Only create rules if you are sure they are missing."
        Write-Host ""
        Write-Host "  Create inbound allow rules for the missing ports now? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            if (-not $rule5005Found) { Invoke-CreateFirewallRule -port $CONTROLLER_PORT -label "Controller Data" }
            if (-not $rule5007Found) { Invoke-CreateFirewallRule -port $ACK_PORT        -label "Latency ACKs"   }
        }
    } else {
        Write-OK "Firewall is set up correctly for this SERVER machine."
    }
}

# Only show tips for issues that actually occurred
$tips = @()
if ($pingIssue -or $routeIssue) { $tips += "High latency / many hops  -> prefer wired Ethernet or same LAN" }
if ($mtuIssue)                  { $tips += "MTU issues -> run setup_jumbo_frames.ps1 on both machines (LAN only)" }

if ($tips.Count -gt 0) {
    Write-Host ""
    Write-Host "  Tips:" -ForegroundColor White
    foreach ($tip in $tips) { Write-Host "    * $tip" }
}

Write-Host ""
