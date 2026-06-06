#Requires -Version 5.1
<#
.SYNOPSIS
    Network diagnostics for RemoteGamepad. Run on BOTH machines at the same time.
.DESCRIPTION
    Machine roles:
      CLIENT  -- your local PC    -- video_receiver.py + controller_udp_sender.py
      SERVER  -- remote/gaming PC -- video_udp_sender.py + controller_udp_receiver.py

    Run the SERVER script first. It prints its IP and waits.
    Then run the CLIENT script pointing at that IP.
    Both machines perform live UDP connectivity tests on all three ports.
.PARAMETER SenderIP
    IP address of the other machine. If omitted, you will be prompted.
.PARAMETER Machine
    Which machine this is: CLIENT or SERVER. If omitted, you will be prompted.
.EXAMPLE
    .\network_diagnostics.ps1                           # prompts for both
    .\network_diagnostics.ps1 192.168.1.50 CLIENT
    .\network_diagnostics.ps1 192.168.1.50 SERVER
#>

param([string]$SenderIP, [string]$Machine)

# -- Ports --------------------------------------------------------------------
$CONTROLLER_PORT = 5005   # server binds (controller data from client)
$VIDEO_PORT      = 5006   # client binds (video from server)
$ACK_PORT        = 5007   # server binds (latency ACKs from client)

# -- Issue flags --------------------------------------------------------------
$pingIssue  = $false
$mtuIssue   = $false
$routeIssue = $false

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

# -- Firewall helpers (only used when offering to create rules) ---------------
function Find-InboundUDPRule([int]$port) {
    $found = Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Protocol -eq "UDP" -and [string]$_.LocalPort -eq [string]$port } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq "Inbound" -and $_.Action -eq "Allow" -and $_.Enabled -eq $true }
    if ($found) { return @($found)[0].DisplayName }
    return $null
}

function Invoke-CreateFirewallRule([int]$port, [string]$label) {
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
               "Write-Host 'Done.' -ForegroundColor Green; Read-Host 'Press Enter to close'"
        Write-INFO "  Launching elevated PowerShell to create rule..."
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -Command `"$cmd`""
        Write-INFO "  Rule will be created in the elevated window."
    }
}

# -- 0. Collect other machine's IP --------------------------------------------
if (-not $SenderIP) {
    $SenderIP = (Read-Host "Enter the other machine's IP address").Trim()
}
$SenderIP = $SenderIP.Trim()

if ($SenderIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    Write-FAIL "Invalid IP address: '$SenderIP'"
    exit 1
}

# -- 0b. Machine role ---------------------------------------------------------
if ($Machine -notmatch '^(CLIENT|SERVER)$') {
    Write-Host ""
    Write-Host "  Which machine is this?" -ForegroundColor White
    Write-Host "   [C] CLIENT  -- local PC         -- video_receiver.py + controller_udp_sender.py"
    Write-Host "   [S] SERVER  -- remote/gaming PC -- video_udp_sender.py + controller_udp_receiver.py"
    $choice = Read-Host "  Choice"
    $Machine = if ($choice -match '^[Ss]') { "SERVER" } else { "CLIENT" }
}
$Machine = $Machine.ToUpper()

# -- 0c. Identify the interface used to reach the other machine ---------------
$routeInfo       = Find-NetRoute -RemoteIPAddress $SenderIP -ErrorAction SilentlyContinue | Select-Object -First 1
$relevantIfIndex = if ($routeInfo) { $routeInfo.InterfaceIndex } else { $null }

Write-Host ""
Write-Host " RemoteGamepad -- Network Diagnostics ($Machine) " -ForegroundColor White -BackgroundColor DarkBlue
if ($Machine -eq "CLIENT") {
    Write-Host "  This machine (CLIENT) : video_receiver.py + controller_udp_sender.py"
    Write-Host "  Server machine at     : $SenderIP"
} else {
    Write-Host "  This machine (SERVER) : video_udp_sender.py + controller_udp_receiver.py"
    Write-Host "  Client machine at     : $SenderIP"
}

# =============================================================================
# 1. PING
# =============================================================================
Write-Section "1. Ping"

$pings = Test-Connection -ComputerName $SenderIP -Count 6 -ErrorAction SilentlyContinue
if (-not $pings) {
    Write-FAIL "Ping failed -- host unreachable or ICMP blocked on the path"
    Write-INFO "  UDP may still work if only ICMP is blocked."
    $pingIssue = $true
} else {
    $rtts = $pings | ForEach-Object { $_.ResponseTime }
    $avg  = [Math]::Round(($rtts | Measure-Object -Average).Average, 1)
    $min  = ($rtts | Measure-Object -Minimum).Minimum
    $max  = ($rtts | Measure-Object -Maximum).Maximum
    $recv = $pings.Count

    Write-OK "Host reachable -- $recv/6 replies"
    Write-INFO "  RTT  min=${min}ms   avg=${avg}ms   max=${max}ms"

    if ($recv -lt 6)      { Write-WARN "Packet loss: $(6 - $recv)/6 pings dropped"; $pingIssue = $true }
    if ($avg -le 5)       { Write-OK   "  Latency looks excellent (LAN-grade)" }
    elseif ($avg -le 30)  { Write-WARN "  Moderate latency (${avg}ms avg)"; $pingIssue = $true }
    else                  { Write-FAIL "  High latency (${avg}ms avg) -- expect noticeable input lag"; $pingIssue = $true }
}

# =============================================================================
# 2. LOCAL NETWORK INTERFACE
# =============================================================================
Write-Section "2. Local Network Interface"

$allLocalAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }

if ($relevantIfIndex) {
    $localAddresses = @($allLocalAddresses | Where-Object { $_.InterfaceIndex -eq $relevantIfIndex })
    if (-not $localAddresses) { $localAddresses = $allLocalAddresses }
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

$senderOctets = $SenderIP.Split(".")
$onSameLAN = $false
foreach ($addr in $localAddresses) {
    $localOctets = $addr.IPAddress.Split(".")
    $sharedBytes = [Math]::Floor($addr.PrefixLength / 8)
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

# =============================================================================
# 3. MTU / JUMBO FRAMES
# =============================================================================
Write-Section "3. MTU / Jumbo Frames"

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
        if ($mtu -ge 9000) { Write-OK   "[$($adapter.Name)] MTU = $mtu  (jumbo frames ENABLED)" }
        elseif ($mtu -ge 1500) { Write-INFO "  [$($adapter.Name)] MTU = $mtu  (standard Ethernet)" }
    }
}

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

# =============================================================================
# 4. UDP CONNECTIVITY TEST
# =============================================================================
Write-Section "4. UDP Connectivity Test"

$DIAG = [System.Text.Encoding]::ASCII.GetBytes("DIAG")
$PONG = [System.Text.Encoding]::ASCII.GetBytes("PONG")

$result5005 = $false
$result5006 = $false
$result5007 = $false

if ($Machine -eq "SERVER") {
    # -- Print this machine's IP so the user can copy it to the client --------
    $thisIP = if ($localAddresses) { $localAddresses[0].IPAddress } else { "?" }
    Write-Host ""
    Write-Host "  --> Run this on the CLIENT machine now:" -ForegroundColor Yellow
    Write-Host "      .\network_diagnostics.ps1 $thisIP CLIENT" -ForegroundColor White
    Write-Host ""

    # Bind inbound sockets
    $sock5005 = $null;  $bind5005Ok = $false
    $sock5007 = $null;  $bind5007Ok = $false

    try {
        $sock5005 = New-Object System.Net.Sockets.UdpClient
        $sock5005.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $CONTROLLER_PORT))
        $sock5005.Client.ReceiveTimeout = 120000
        $bind5005Ok = $true
    } catch {
        Write-WARN "Cannot bind UDP $CONTROLLER_PORT -- controller_udp_receiver.py may already be running"
    }

    try {
        $sock5007 = New-Object System.Net.Sockets.UdpClient
        $sock5007.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $ACK_PORT))
        $sock5007.Client.ReceiveTimeout = 30000
        $bind5007Ok = $true
    } catch {
        Write-WARN "Cannot bind UDP $ACK_PORT -- port may already be in use"
    }

    # Socket used to probe client's 5006 and receive its reply
    $sock5006probe = New-Object System.Net.Sockets.UdpClient
    $sock5006probe.Client.ReceiveTimeout = 15000

    $clientIP = $SenderIP  # overwritten once a packet arrives

    # Wait for client probe on 5005
    if ($bind5005Ok) {
        Write-Host -NoNewline "  Waiting for client probe on UDP $CONTROLLER_PORT (2 min timeout)... " -ForegroundColor Gray
        try {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $sock5005.Receive([ref]$ep)
            $clientIP = $ep.Address.ToString()
            $sock5005.Send($PONG, $PONG.Length, $ep) | Out-Null
            Write-Host "[OK]  probe from $clientIP" -ForegroundColor Green
            $result5005 = $true
        } catch {
            Write-Host "[TIMEOUT]" -ForegroundColor Red
        }
        $sock5005.Close()
    }

    # Wait for client probe on 5007
    if ($bind5007Ok) {
        Write-Host -NoNewline "  Waiting for client probe on UDP $ACK_PORT (30s timeout)... " -ForegroundColor Gray
        try {
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $sock5007.Receive([ref]$ep)
            $sock5007.Send($PONG, $PONG.Length, $ep) | Out-Null
            Write-Host "[OK]  probe from $($ep.Address)" -ForegroundColor Green
            $result5007 = $true
        } catch {
            Write-Host "[TIMEOUT]" -ForegroundColor Red
        }
        $sock5007.Close()
    }

    # Probe client's 5006
    Write-Host -NoNewline "  Probing client UDP $VIDEO_PORT at $clientIP (15s timeout)... " -ForegroundColor Gray
    try {
        $sock5006probe.Send($DIAG, $DIAG.Length, $clientIP, $VIDEO_PORT) | Out-Null
        $ep6 = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $null = $sock5006probe.Receive([ref]$ep6)
        Write-Host "[OK]  client $($ep6.Address) replied" -ForegroundColor Green
        $result5006 = $true
    } catch {
        Write-Host "[TIMEOUT] -- client's UDP $VIDEO_PORT did not reply" -ForegroundColor Red
    }
    $sock5006probe.Close()

} else {
    # CLIENT
    Write-INFO "  Binding to UDP $VIDEO_PORT, then probing server..."

    # Bind 5006 BEFORE probing server so we are ready when server probes us back
    $sock5006 = $null; $bind5006Ok = $false
    try {
        $sock5006 = New-Object System.Net.Sockets.UdpClient
        $sock5006.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $VIDEO_PORT))
        $sock5006.Client.ReceiveTimeout = 30000
        $bind5006Ok = $true
    } catch {
        Write-WARN "Cannot bind UDP $VIDEO_PORT -- video_receiver.py may already be running"
    }

    # Probe server:5005
    Write-Host -NoNewline "  Probing server UDP $CONTROLLER_PORT at $SenderIP (10s timeout)... " -ForegroundColor Gray
    $sock_a = New-Object System.Net.Sockets.UdpClient
    $sock_a.Client.ReceiveTimeout = 10000
    try {
        $sock_a.Send($DIAG, $DIAG.Length, $SenderIP, $CONTROLLER_PORT) | Out-Null
        $ep_a = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $null = $sock_a.Receive([ref]$ep_a)
        Write-Host "[OK]  server $($ep_a.Address) replied" -ForegroundColor Green
        $result5005 = $true
    } catch {
        Write-Host "[TIMEOUT] -- server's UDP $CONTROLLER_PORT did not reply" -ForegroundColor Red
    }
    $sock_a.Close()

    # Probe server:5007
    Write-Host -NoNewline "  Probing server UDP $ACK_PORT at $SenderIP (10s timeout)... " -ForegroundColor Gray
    $sock_b = New-Object System.Net.Sockets.UdpClient
    $sock_b.Client.ReceiveTimeout = 10000
    try {
        $sock_b.Send($DIAG, $DIAG.Length, $SenderIP, $ACK_PORT) | Out-Null
        $ep_b = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $null = $sock_b.Receive([ref]$ep_b)
        Write-Host "[OK]  server $($ep_b.Address) replied" -ForegroundColor Green
        $result5007 = $true
    } catch {
        Write-Host "[TIMEOUT] -- server's UDP $ACK_PORT did not reply" -ForegroundColor Red
    }
    $sock_b.Close()

    # Wait for server probe on 5006
    if ($bind5006Ok) {
        Write-Host -NoNewline "  Waiting for server probe on UDP $VIDEO_PORT (30s timeout)... " -ForegroundColor Gray
        try {
            $ep6 = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $sock5006.Receive([ref]$ep6)
            $sock5006.Send($PONG, $PONG.Length, $ep6) | Out-Null
            Write-Host "[OK]  probe from $($ep6.Address)" -ForegroundColor Green
            $result5006 = $true
        } catch {
            Write-Host "[TIMEOUT] -- no probe from server on UDP $VIDEO_PORT" -ForegroundColor Red
        }
        $sock5006.Close()
    }
}

# =============================================================================
# 5. PORT AVAILABILITY
# =============================================================================
Write-Section "5. Port Availability (is anything already listening?)"

$netstatOutput = netstat -an -p UDP

function Test-PortBound([int]$port, [string]$scriptName, [bool]$shouldBind) {
    $bound = $netstatOutput | Select-String "[\s:]$port\s"
    if ($bound) {
        if ($shouldBind) { Write-OK   "UDP $port -- already bound ($scriptName may be running)" }
        else             { Write-WARN "UDP $port -- already bound locally (another app may interfere)" }
    } else {
        if ($shouldBind) {
            try {
                $sock = New-Object System.Net.Sockets.UdpClient($port)
                $sock.Close()
                Write-INFO "  UDP $port -- not bound; ready for $scriptName to use"
            } catch {
                Write-WARN "UDP $port -- bind failed: port already in use"
            }
        } else {
            Write-INFO "  UDP $port -- not bound locally (correct -- outbound only)"
        }
    }
}

if ($Machine -eq "CLIENT") {
    Test-PortBound -port $VIDEO_PORT      -scriptName "video_receiver.py"        -shouldBind $true
    Test-PortBound -port $CONTROLLER_PORT -scriptName "controller_udp_sender.py" -shouldBind $false
    Test-PortBound -port $ACK_PORT        -scriptName "video_receiver.py"        -shouldBind $false
} else {
    Test-PortBound -port $CONTROLLER_PORT -scriptName "controller_udp_receiver.py" -shouldBind $true
    Test-PortBound -port $ACK_PORT        -scriptName "video_udp_sender.py"        -shouldBind $true
    Test-PortBound -port $VIDEO_PORT      -scriptName "video_udp_sender.py"        -shouldBind $false
}

# =============================================================================
# 6. ROUTE TRACE
# =============================================================================
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

# =============================================================================
# 7. SUMMARY
# =============================================================================
Write-Section "7. Summary"
Write-Host ""

if ($Machine -eq "CLIENT") {
    Write-Host "  Port results (CLIENT perspective):" -ForegroundColor White
    Write-Host "    5005/UDP  Controller data  CLIENT --> server  " -NoNewline
    if ($result5005) { Write-Host "[OK]"     -ForegroundColor Green  }
    else             { Write-Host "[FAILED]" -ForegroundColor Red    }
    Write-Host "    5006/UDP  Video frames     CLIENT <-- server  " -NoNewline
    if ($result5006) { Write-Host "[OK]"     -ForegroundColor Green  }
    else             { Write-Host "[FAILED]" -ForegroundColor Red    }
    Write-Host "    5007/UDP  Latency ACKs     CLIENT --> server  " -NoNewline
    if ($result5007) { Write-Host "[OK]"     -ForegroundColor Green  }
    else             { Write-Host "[FAILED]" -ForegroundColor Red    }
    Write-Host ""

    if (-not $result5006) {
        Write-WARN "UDP $VIDEO_PORT (video) did not pass -- this machine may need an inbound firewall rule."
        Write-Host "  Create an inbound allow rule for UDP $VIDEO_PORT on this machine? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            Invoke-CreateFirewallRule -port $VIDEO_PORT -label "Video Stream"
        }
    }
    if (-not $result5005 -or -not $result5007) {
        $failedServer = @()
        if (-not $result5005) { $failedServer += "UDP $CONTROLLER_PORT" }
        if (-not $result5007) { $failedServer += "UDP $ACK_PORT" }
        Write-WARN "$($failedServer -join " and ") did not pass -- the SERVER may need inbound rules for those ports."
    }
    if ($result5005 -and $result5006 -and $result5007) {
        Write-OK "All three ports passed end-to-end."
    }
} else {
    Write-Host "  Port results (SERVER perspective):" -ForegroundColor White
    Write-Host "    5005/UDP  Controller data  SERVER <-- client  " -NoNewline
    if ($result5005) { Write-Host "[OK]"     -ForegroundColor Green  }
    else             { Write-Host "[FAILED]" -ForegroundColor Red    }
    Write-Host "    5006/UDP  Video frames     SERVER --> client  " -NoNewline
    if ($result5006) { Write-Host "[OK]"     -ForegroundColor Green  }
    else             { Write-Host "[FAILED]" -ForegroundColor Red    }
    Write-Host "    5007/UDP  Latency ACKs     SERVER <-- client  " -NoNewline
    if ($result5007) { Write-Host "[OK]"     -ForegroundColor Green  }
    else             { Write-Host "[FAILED]" -ForegroundColor Red    }
    Write-Host ""

    $failedLocal = @()
    if (-not $result5005) { $failedLocal += $CONTROLLER_PORT }
    if (-not $result5007) { $failedLocal += $ACK_PORT }
    if ($failedLocal.Count -gt 0) {
        Write-WARN "Ports that failed and are inbound on this machine: UDP $($failedLocal -join ", UDP ")"
        Write-Host "  Create inbound allow rules for the failed ports on this machine? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            foreach ($p in $failedLocal) {
                $lbl = if ($p -eq $CONTROLLER_PORT) { "Controller Data" } else { "Latency ACKs" }
                Invoke-CreateFirewallRule -port $p -label $lbl
            }
        }
    }
    if (-not $result5006) {
        Write-WARN "UDP $VIDEO_PORT (video) did not reach the client -- the CLIENT may need an inbound rule."
    }
    if ($result5005 -and $result5006 -and $result5007) {
        Write-OK "All three ports passed end-to-end."
    }
}

# Only show tips when a relevant issue was detected
$tips = @()
if ($pingIssue -or $routeIssue) { $tips += "High latency / many hops  -> prefer wired Ethernet or same LAN" }
if ($mtuIssue)                  { $tips += "MTU issues -> run setup_jumbo_frames.ps1 on both machines (LAN only)" }
if ($tips.Count -gt 0) {
    Write-Host ""
    Write-Host "  Tips:" -ForegroundColor White
    foreach ($tip in $tips) { Write-Host "    * $tip" }
}

Write-Host ""
