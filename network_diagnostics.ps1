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
$TIMEOUT_MS      = 60000  # 1 minute for all UDP connectivity tests
$DIAG = [System.Text.Encoding]::ASCII.GetBytes("DIAG")
$PONG = [System.Text.Encoding]::ASCII.GetBytes("PONG")

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

# -- Dot-printer helpers ------------------------------------------------------
# A System.Timers.Timer with a PS scriptblock callback cannot fire while the
# main thread is blocked on a .NET call, because the scriptblock needs the PS
# runspace which the blocked thread is holding.
# Fix: compile a tiny C# class whose timer callback is a pure .NET lambda --
# no PS runspace needed, fires reliably even during UdpClient.Receive etc.
if (-not ([System.Management.Automation.PSTypeName]'RemoteGamepad.DotPrinter').Type) {
    Add-Type -Namespace RemoteGamepad -Name DotPrinter -MemberDefinition @'
        private System.Threading.Timer _t;
        private volatile bool _on;
        public DotPrinter() {
            _on = true;
            _t = new System.Threading.Timer(_ => { if (_on) System.Console.Write('.'); },
                                            null, 500, 500);
        }
        public void Stop() { _on = false; _t.Change(-1, -1); _t.Dispose(); }
'@
}

function Start-Dots([string]$msg) {
    Write-Host -NoNewline "  $msg" -ForegroundColor Gray
    return [RemoteGamepad.DotPrinter]::new()
}

# Stop dots. Does NOT print a newline -- caller appends the result on the same line.
function Stop-Dots($dp) { $dp.Stop() }

# -- Firewall helpers (only for optional rule creation in summary) ------------
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
    if ($existing) { Write-OK "Rule already exists: $existing  (no action taken)"; return $true }
    $displayName = "RemoteGamepad $label UDP $port"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        try {
            New-NetFirewallRule -DisplayName $displayName `
                -Direction Inbound -Protocol UDP -LocalPort $port `
                -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-OK "Rule created: $displayName"
            return $true
        } catch { Write-FAIL "Could not create rule: $($_.Exception.Message)"; return $false }
    } else {
        $cmd = "New-NetFirewallRule -DisplayName '$displayName' " +
               "-Direction Inbound -Protocol UDP -LocalPort $port -Action Allow -Profile Any | Out-Null; " +
               "Write-Host 'Done.' -ForegroundColor Green; Read-Host 'Press Enter to close'"
        Write-INFO "  Launching elevated PowerShell to create rule..."
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -Command `"$cmd`""
        Write-INFO "  Waiting for elevated window to finish..."
        Start-Sleep -Seconds 4   # give the elevated process time to create the rule
        return $true             # optimistic: assume it was created
    }
}

# Runs the UDP connectivity test. Returns @{ p5005; p5006; p5007 } booleans.
# Can be called from step 4 and again from the summary after rule creation.
function Invoke-UDPTest {
    $p5005 = $false; $p5006 = $false; $p5007 = $false
    $cIP   = $SenderIP   # overwritten on SERVER once first packet arrives

    if ($Machine -eq "SERVER") {
        $thisIP = if ($localAddresses) { $localAddresses[0].IPAddress } else { "?" }
        Write-Host ""
        Write-Host "  --> Run this on the CLIENT machine now:" -ForegroundColor Yellow
        Write-Host "      .\network_diagnostics.ps1 $thisIP CLIENT" -ForegroundColor White
        Write-Host ""

        $s5005 = $null
        try {
            $s5005 = New-Object System.Net.Sockets.UdpClient
            $s5005.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $CONTROLLER_PORT))
            $s5005.Client.ReceiveTimeout = $TIMEOUT_MS
        } catch { Write-WARN "Cannot bind UDP $CONTROLLER_PORT -- controller_udp_receiver.py may be running" }

        $s5007 = $null
        try {
            $s5007 = New-Object System.Net.Sockets.UdpClient
            $s5007.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $ACK_PORT))
            $s5007.Client.ReceiveTimeout = $TIMEOUT_MS
        } catch { Write-WARN "Cannot bind UDP $ACK_PORT -- port may already be in use" }

        if ($s5005) {
            $dt = Start-Dots "Waiting for client probe on UDP $CONTROLLER_PORT (1 min)"
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            try {
                $null = $s5005.Receive([ref]$ep); $cIP = $ep.Address.ToString()
                $s5005.Send($PONG, $PONG.Length, $ep) | Out-Null
                Stop-Dots $dt; Write-Host " [OK]  probe from $cIP" -ForegroundColor Green; $p5005 = $true
            } catch { Stop-Dots $dt; Write-Host " [TIMEOUT]" -ForegroundColor Red }
            $s5005.Close()
        }

        if ($s5007) {
            $dt = Start-Dots "Waiting for client probe on UDP $ACK_PORT (1 min)"
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            try {
                $null = $s5007.Receive([ref]$ep)
                $s5007.Send($PONG, $PONG.Length, $ep) | Out-Null
                Stop-Dots $dt; Write-Host " [OK]" -ForegroundColor Green; $p5007 = $true
            } catch { Stop-Dots $dt; Write-Host " [TIMEOUT]" -ForegroundColor Red }
            $s5007.Close()
        }

        $dt   = Start-Dots "Probing client UDP $VIDEO_PORT at $cIP (1 min)"
        $sock = New-Object System.Net.Sockets.UdpClient
        $sock.Client.ReceiveTimeout = $TIMEOUT_MS
        $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $sock.Send($DIAG, $DIAG.Length, $cIP, $VIDEO_PORT) | Out-Null
            $null = $sock.Receive([ref]$ep)
            Stop-Dots $dt; Write-Host " [OK]  client replied" -ForegroundColor Green; $p5006 = $true
        } catch { Stop-Dots $dt; Write-Host " [TIMEOUT]" -ForegroundColor Red }
        $sock.Close()

    } else {
        $s5006 = $null
        try {
            $s5006 = New-Object System.Net.Sockets.UdpClient
            $s5006.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $VIDEO_PORT))
            $s5006.Client.ReceiveTimeout = $TIMEOUT_MS
        } catch { Write-WARN "Cannot bind UDP $VIDEO_PORT -- video_receiver.py may already be running" }

        $dt   = Start-Dots "Probing server UDP $CONTROLLER_PORT at $SenderIP (1 min)"
        $sock = New-Object System.Net.Sockets.UdpClient
        $sock.Client.ReceiveTimeout = $TIMEOUT_MS
        $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $sock.Send($DIAG, $DIAG.Length, $SenderIP, $CONTROLLER_PORT) | Out-Null
            $null = $sock.Receive([ref]$ep)
            Stop-Dots $dt; Write-Host " [OK]  server $($ep.Address) replied" -ForegroundColor Green; $p5005 = $true
        } catch { Stop-Dots $dt; Write-Host " [TIMEOUT]" -ForegroundColor Red }
        $sock.Close()

        $dt   = Start-Dots "Probing server UDP $ACK_PORT at $SenderIP (1 min)"
        $sock = New-Object System.Net.Sockets.UdpClient
        $sock.Client.ReceiveTimeout = $TIMEOUT_MS
        $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $sock.Send($DIAG, $DIAG.Length, $SenderIP, $ACK_PORT) | Out-Null
            $null = $sock.Receive([ref]$ep)
            Stop-Dots $dt; Write-Host " [OK]  server $($ep.Address) replied" -ForegroundColor Green; $p5007 = $true
        } catch { Stop-Dots $dt; Write-Host " [TIMEOUT]" -ForegroundColor Red }
        $sock.Close()

        if ($s5006) {
            $dt = Start-Dots "Waiting for server probe on UDP $VIDEO_PORT (1 min)"
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            try {
                $null = $s5006.Receive([ref]$ep)
                $s5006.Send($PONG, $PONG.Length, $ep) | Out-Null
                Stop-Dots $dt; Write-Host " [OK]  probe from $($ep.Address)" -ForegroundColor Green; $p5006 = $true
            } catch { Stop-Dots $dt; Write-Host " [TIMEOUT]" -ForegroundColor Red }
            $s5006.Close()
        }
    }

    return @{ p5005 = $p5005; p5006 = $p5006; p5007 = $p5007 }
}

# -- 0. Collect other machine's IP --------------------------------------------
if (-not $SenderIP) { $SenderIP = (Read-Host "Enter the other machine's IP address").Trim() }
$SenderIP = $SenderIP.Trim()
if ($SenderIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Write-FAIL "Invalid IP: '$SenderIP'"; exit 1 }

# -- 0b. Machine role ---------------------------------------------------------
if ($Machine -notmatch '^(CLIENT|SERVER)$') {
    Write-Host ""
    Write-Host "  Which machine is this?" -ForegroundColor White
    Write-Host "   [C] CLIENT  -- local PC         -- video_receiver.py + controller_udp_sender.py"
    Write-Host "   [S] SERVER  -- remote/gaming PC -- video_udp_sender.py + controller_udp_receiver.py"
    $choice  = Read-Host "  Choice"
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

$dt = Start-Dots "Pinging $SenderIP (6 packets)"
$pings = Test-Connection -ComputerName $SenderIP -Count 6 -ErrorAction SilentlyContinue
Stop-Dots $dt
Write-Host ""

if (-not $pings -or $pings.Count -eq 0) {
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
} else { $localAddresses = $allLocalAddresses }

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
$onSameLAN    = $false
foreach ($addr in $localAddresses) {
    $localOctets = $addr.IPAddress.Split(".")
    $sharedBytes = [Math]::Floor($addr.PrefixLength / 8)
    if ($sharedBytes -ge 2 -and
        ($localOctets[0..($sharedBytes-1)] -join ".") -eq ($senderOctets[0..($sharedBytes-1)] -join ".")) {
        Write-OK "Other machine is on the same LAN subnet"; $onSameLAN = $true; break
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
} else { $relevantIfaces = $allIfaces }

foreach ($iface in $relevantIfaces) {
    $adapter = Get-NetAdapter -InterfaceIndex $iface.InterfaceIndex -ErrorAction SilentlyContinue
    if ($adapter -and $adapter.Status -eq "Up") {
        $mtu = $iface.NlMtu
        if ($mtu -ge 9000)     { Write-OK   "[$($adapter.Name)] MTU = $mtu  (jumbo frames ENABLED)" }
        elseif ($mtu -ge 1500) { Write-INFO "  [$($adapter.Name)] MTU = $mtu  (standard Ethernet)" }
    }
}

Write-Host -NoNewline "  Testing path MTU" -ForegroundColor Gray
$pmtuOk = $false
foreach ($size in @(1472, 1400, 1000)) {
    Write-Host -NoNewline '.' -ForegroundColor Gray
    if (ping.exe -n 1 -f -l $size $SenderIP | Select-String "Reply from") { $pmtuOk = $true; break }
}
if ($pmtuOk) { Write-Host " OK  (>= $($size + 28) bytes)" -ForegroundColor Green }
else         { Write-Host " low (< 1028 bytes)" -ForegroundColor Yellow; $mtuIssue = $true }

# =============================================================================
# 4. UDP CONNECTIVITY TEST
# =============================================================================
Write-Section "4. UDP Connectivity Test"
$udp          = Invoke-UDPTest
$result5005   = $udp.p5005
$result5006   = $udp.p5006
$result5007   = $udp.p5007

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
            try { $s = New-Object System.Net.Sockets.UdpClient($port); $s.Close()
                  Write-INFO "  UDP $port -- not bound; ready for $scriptName to use"
            } catch { Write-WARN "UDP $port -- bind failed: port already in use" }
        } else { Write-INFO "  UDP $port -- not bound locally (correct -- outbound only)" }
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

$dt    = Start-Dots "Tracing route to $SenderIP"
$trace = $null
try { $trace = Test-NetConnection -ComputerName $SenderIP -TraceRoute -Hops 10 -WarningAction SilentlyContinue -ErrorAction Stop } catch {}
Stop-Dots $dt
Write-Host ""

if ($trace) {
    $hops = $trace.TraceRoute | Where-Object { $_ -ne "0.0.0.0" -and $_ -ne "::" }
    if ($hops) {
        $n = 1; foreach ($h in $hops) { Write-INFO "  Hop $n : $h"; $n++ }
        $hopCount = @($hops).Count
        if ($hopCount -eq 1)     { Write-OK   "Direct connection ($hopCount hop) -- same LAN or VPN tunnel" }
        elseif ($hopCount -le 3) { Write-OK   "Short route ($hopCount hops)" }
        elseif ($hopCount -le 6) { Write-WARN "Medium route ($hopCount hops) -- may introduce jitter"; $routeIssue = $true }
        else                     { Write-FAIL "Long route ($hopCount hops) -- high jitter risk"; $routeIssue = $true }
    } else { Write-INFO "  Route data not available (hops may be blocking ICMP TTL-exceeded)" }
} else { Write-INFO "  Traceroute failed or timed out" }

# =============================================================================
# 7. SUMMARY
# =============================================================================
Write-Section "7. Summary"
Write-Host ""

if ($Machine -eq "CLIENT") {
    Write-Host "  Port results (CLIENT perspective):" -ForegroundColor White
    Write-Host "    5005/UDP  Controller data  CLIENT --> server  " -NoNewline
    if ($result5005) { Write-Host "[OK]"     -ForegroundColor Green } else { Write-Host "[FAILED]" -ForegroundColor Red }
    Write-Host "    5006/UDP  Video frames     CLIENT <-- server  " -NoNewline
    if ($result5006) { Write-Host "[OK]"     -ForegroundColor Green } else { Write-Host "[FAILED]" -ForegroundColor Red }
    Write-Host "    5007/UDP  Latency ACKs     CLIENT --> server  " -NoNewline
    if ($result5007) { Write-Host "[OK]"     -ForegroundColor Green } else { Write-Host "[FAILED]" -ForegroundColor Red }
    Write-Host ""

    if (-not $result5006) {
        Write-WARN "UDP $VIDEO_PORT (video) did not pass -- this machine may need an inbound firewall rule."
        Write-Host "  Create an inbound allow rule for UDP $VIDEO_PORT on this machine? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            Invoke-CreateFirewallRule -port $VIDEO_PORT -label "Video Stream" | Out-Null
            Write-Section "4. UDP Connectivity Test (re-run)"
            $udp        = Invoke-UDPTest
            $result5006 = $udp.p5006
            if ($result5006) { Write-OK  "UDP $VIDEO_PORT now passes -- rule is working." }
            else             { Write-WARN "UDP $VIDEO_PORT still failing -- check router/VPN firewall as well." }
        }
    }
    if (-not $result5005 -or -not $result5007) {
        $fs = @(); if (-not $result5005) { $fs += "UDP $CONTROLLER_PORT" }; if (-not $result5007) { $fs += "UDP $ACK_PORT" }
        Write-WARN "$($fs -join " and ") did not pass -- the SERVER may need inbound rules for those ports."
    }
    if ($result5005 -and $result5006 -and $result5007) { Write-OK "All three ports passed end-to-end." }
} else {
    Write-Host "  Port results (SERVER perspective):" -ForegroundColor White
    Write-Host "    5005/UDP  Controller data  SERVER <-- client  " -NoNewline
    if ($result5005) { Write-Host "[OK]"     -ForegroundColor Green } else { Write-Host "[FAILED]" -ForegroundColor Red }
    Write-Host "    5006/UDP  Video frames     SERVER --> client  " -NoNewline
    if ($result5006) { Write-Host "[OK]"     -ForegroundColor Green } else { Write-Host "[FAILED]" -ForegroundColor Red }
    Write-Host "    5007/UDP  Latency ACKs     SERVER <-- client  " -NoNewline
    if ($result5007) { Write-Host "[OK]"     -ForegroundColor Green } else { Write-Host "[FAILED]" -ForegroundColor Red }
    Write-Host ""

    $failedLocal = @()
    if (-not $result5005) { $failedLocal += $CONTROLLER_PORT }
    if (-not $result5007) { $failedLocal += $ACK_PORT }
    if ($failedLocal.Count -gt 0) {
        Write-WARN "Ports that failed and are inbound on this machine: UDP $($failedLocal -join ", UDP ")"
        Write-Host "  Create inbound allow rules for the failed ports on this machine? [Y/N]" -ForegroundColor Yellow
        if ((Read-Host "  Choice") -match "^[Yy]") {
            foreach ($p in $failedLocal) {
                Invoke-CreateFirewallRule -port $p -label (if ($p -eq $CONTROLLER_PORT) { "Controller Data" } else { "Latency ACKs" }) | Out-Null
            }
            Write-Section "4. UDP Connectivity Test (re-run)"
            $udp        = Invoke-UDPTest
            $result5005 = $udp.p5005
            $result5007 = $udp.p5007
            $allFixed   = ($failedLocal -notcontains $CONTROLLER_PORT -or $result5005) -and
                          ($failedLocal -notcontains $ACK_PORT        -or $result5007)
            if ($allFixed) { Write-OK  "Previously failed ports now pass -- rules are working." }
            else           { Write-WARN "Some ports still failing -- check router/VPN firewall as well." }
        }
    }
    if (-not $result5006) { Write-WARN "UDP $VIDEO_PORT (video) did not reach client -- the CLIENT may need an inbound rule." }
    if ($result5005 -and $result5006 -and $result5007) { Write-OK "All three ports passed end-to-end." }
}

$tips = @()
if ($pingIssue -or $routeIssue) { $tips += "High latency / many hops  -> prefer wired Ethernet or same LAN" }
if ($mtuIssue)                  { $tips += "MTU issues -> run setup_jumbo_frames.ps1 on both machines (LAN only)" }
if ($tips.Count -gt 0) {
    Write-Host ""; Write-Host "  Tips:" -ForegroundColor White
    foreach ($tip in $tips) { Write-Host "    * $tip" }
}
Write-Host ""
