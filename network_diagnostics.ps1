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
.PARAMETER Wait
    Wait indefinitely for the other machine instead of timing out after 15 seconds.
    Useful when both machines start the diagnostic at very different times.
.EXAMPLE
    .\network_diagnostics.ps1                           # prompts for both
    .\network_diagnostics.ps1 192.168.1.50 CLIENT
    .\network_diagnostics.ps1 192.168.1.50 SERVER
    .\network_diagnostics.ps1 192.168.1.50 SERVER -Wait
#>

param([string]$SenderIP, [string]$Machine, [switch]$Wait)

# -- Ports --------------------------------------------------------------------
$CONTROLLER_PORT = 5005   # server binds (controller data from client)
$VIDEO_PORT      = 5006   # client binds (video from server)
$ACK_PORT        = 5007   # server binds (latency ACKs from client)
# UDP test timeout: 15s normally; -Wait makes it effectively unlimited (~24 days).
$TIMEOUT_MS   = if ($Wait) { [Int32]::MaxValue } else { 15000 }
$timeoutLabel = if ($Wait) { 'unlimited' }       else { '15s'  }

# -- Issue flags --------------------------------------------------------------
$pingFailed = $false   # true only when host is completely unreachable (not just slow)
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
        private static readonly object _lock = new object();
        private static readonly System.Collections.Generic.List<DotPrinter> _active
            = new System.Collections.Generic.List<DotPrinter>();
        private static bool _hookSet = false;
        private System.Threading.Timer _t;
        private volatile bool _on;
        public DotPrinter() {
            lock (_lock) {
                if (!_hookSet) {
                    System.Console.CancelKeyPress += (s, e) => { StopAll(); };
                    _hookSet = true;
                }
                _on = true;
                _active.Add(this);
            }
            _t = new System.Threading.Timer(_ => { if (_on) System.Console.Write('.'); },
                                            null, 500, 500);
        }
        public void Stop() {
            _on = false; _t.Change(-1, -1); _t.Dispose();
            lock (_lock) { _active.Remove(this); }
        }
        public static void StopAll() {
            lock (_lock) { foreach (var d in _active) d._on = false; }
        }
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

# -- UDP test scriptblocks at script scope so both Start-UDPJobs (early start)
# and Invoke-UDPTest (summary re-run) share them without re-definition. -------

# Job: bind $port, echo PONG to the first DIAG probe that arrives.
$receiveScript = {
    param([int]$port, [int]$timeout)
    $pong = [System.Text.Encoding]::ASCII.GetBytes("PONG")
    $s    = $null
    try {
        $s = New-Object System.Net.Sockets.UdpClient
        $s.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port))
        $s.Client.ReceiveTimeout = 2000
        $ep       = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeout)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $null = $s.Receive([ref]$ep)
                $s.Send($pong, $pong.Length, $ep) | Out-Null
                return $true
            } catch { }
        }
    } catch { }
    finally { if ($s) { $s.Close() } }
    return $false
}

# Job: send DIAG to $ip:$port every 2s, return $true when PONG is received.
$probeScript = {
    param([string]$ip, [int]$port, [int]$timeout)
    $diag = [System.Text.Encoding]::ASCII.GetBytes("DIAG")
    $s    = $null
    try {
        $s = New-Object System.Net.Sockets.UdpClient
        $s.Client.ReceiveTimeout = 2000
        $ep       = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeout)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $s.Send($diag, $diag.Length, $ip, $port) | Out-Null
                $null = $s.Receive([ref]$ep)
                return $true
            } catch { }
        }
    } catch { }
    finally { if ($s) { $s.Close() } }
    return $false
}

# Starts the 3 UDP port background jobs. For SERVER, also prints the "run on
# CLIENT" banner so the operator can start the CLIENT while sections 1-3 run.
# Returns @{ j5005; j5006; j5007 }.
function Start-UDPJobs {
    if ($Machine -eq "SERVER") {
        $thisIP = if ($localAddresses) { $localAddresses[0].IPAddress } else { "?" }
        Write-Host ""
        Write-Host "  --> Run this on the CLIENT machine now:" -ForegroundColor Yellow
        Write-Host "      .\network_diagnostics.ps1 $thisIP CLIENT" -ForegroundColor White
        Write-Host ""
        return @{
            j5005 = Start-Job $receiveScript -ArgumentList $CONTROLLER_PORT, $TIMEOUT_MS
            j5007 = Start-Job $receiveScript -ArgumentList $ACK_PORT,        $TIMEOUT_MS
            j5006 = Start-Job $probeScript   -ArgumentList $SenderIP, $VIDEO_PORT, $TIMEOUT_MS
        }
    } else {
        return @{
            j5006 = Start-Job $receiveScript -ArgumentList $VIDEO_PORT, $TIMEOUT_MS
            j5005 = Start-Job $probeScript   -ArgumentList $SenderIP, $CONTROLLER_PORT, $TIMEOUT_MS
            j5007 = Start-Job $probeScript   -ArgumentList $SenderIP, $ACK_PORT,        $TIMEOUT_MS
        }
    }
}

# Waits for pre-started UDP jobs, displays pass/fail per port, removes jobs.
# Returns @{ p5005; p5006; p5007 }.
function Collect-UDPJobs($udpJobs) {
    $j5005 = $udpJobs.j5005; $j5007 = $udpJobs.j5007; $j5006 = $udpJobs.j5006

    $dt = Start-Dots "Testing all 3 UDP ports in parallel ($timeoutLabel)"
    Wait-Job $j5005, $j5007, $j5006 | Out-Null
    Stop-Dots $dt
    Write-Host ""

    $p5005 = [bool](Receive-Job $j5005 -ErrorAction SilentlyContinue)
    $p5007 = [bool](Receive-Job $j5007 -ErrorAction SilentlyContinue)
    $p5006 = [bool](Receive-Job $j5006 -ErrorAction SilentlyContinue)
    Remove-Job $j5005, $j5007, $j5006 -Force -ErrorAction SilentlyContinue

    if ($Machine -eq "SERVER") {
        if ($p5005) { Write-OK   "5005/UDP  controller data  SERVER <-- client" }
        else        { Write-FAIL "5005/UDP  controller data  SERVER <-- client  [TIMEOUT]" }
        if ($p5007) { Write-OK   "5007/UDP  latency ACKs     SERVER <-- client" }
        else        { Write-FAIL "5007/UDP  latency ACKs     SERVER <-- client  [TIMEOUT]" }
        if ($p5006) { Write-OK   "5006/UDP  video frames     SERVER --> client" }
        else        { Write-FAIL "5006/UDP  video frames     SERVER --> client  [TIMEOUT]" }
    } else {
        if ($p5005) { Write-OK   "5005/UDP  controller data  CLIENT --> server" }
        else        { Write-FAIL "5005/UDP  controller data  CLIENT --> server  [TIMEOUT]" }
        if ($p5007) { Write-OK   "5007/UDP  latency ACKs     CLIENT --> server" }
        else        { Write-FAIL "5007/UDP  latency ACKs     CLIENT --> server  [TIMEOUT]" }
        if ($p5006) { Write-OK   "5006/UDP  video frames     CLIENT <-- server" }
        else        { Write-FAIL "5006/UDP  video frames     CLIENT <-- server  [TIMEOUT]" }
    }

    return @{ p5005 = $p5005; p5006 = $p5006; p5007 = $p5007 }
}

# Thin wrapper used by the summary re-run after firewall rule creation.
function Invoke-UDPTest { return Collect-UDPJobs (Start-UDPJobs) }

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

# -- Compute local addresses now (before background jobs) so Start-UDPJobs can
# use them for the SERVER "run on CLIENT" banner that appears before section 1.
$allLocalAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }
if ($relevantIfIndex) {
    $localAddresses = @($allLocalAddresses | Where-Object { $_.InterfaceIndex -eq $relevantIfIndex })
    if (-not $localAddresses) { $localAddresses = $allLocalAddresses }
} else { $localAddresses = $allLocalAddresses }

# -- Start all long-running background jobs before section 1 so ping, MTU,
# traceroute, and UDP tests all run in parallel with each other.
# Results consumed at: section 1 ($pingJob), section 3 ($mtuJob),
# section 4 ($udpJobs), section 6 ($traceJob).
$traceJob = Start-Job -ScriptBlock {
    param($ip)
    try { Test-NetConnection -ComputerName $ip -TraceRoute -Hops 10 `
              -WarningAction SilentlyContinue -ErrorAction Stop }
    catch { $null }
} -ArgumentList $SenderIP

$mtuJob = Start-Job -ScriptBlock {
    param($ip)
    foreach ($size in @(1472, 1000)) {
        if ((ping.exe -n 1 -f -l $size -w 1000 $ip) -match "Reply from") { return $size }
    }
    return 0
} -ArgumentList $SenderIP

$pingJob = Start-Job -ScriptBlock {
    param($ip)
    $pings = Test-Connection -ComputerName $ip -Count 3 -ErrorAction SilentlyContinue
    if (-not $pings -or $pings.Count -eq 0) { return $null }
    $rtts = @($pings | ForEach-Object { $_.ResponseTime })
    return @{
        Count = $pings.Count
        Min   = ($rtts | Measure-Object -Minimum).Minimum
        Max   = ($rtts | Measure-Object -Maximum).Maximum
        Avg   = [Math]::Round(($rtts | Measure-Object -Average).Average, 1)
    }
} -ArgumentList $SenderIP

# Start UDP port jobs. For SERVER, Start-UDPJobs also prints the "run on CLIENT"
# banner right now so the operator can kick off the CLIENT while sections 1-3 run.
$udpJobs = Start-UDPJobs

# =============================================================================
# 1. PING
# =============================================================================
Write-Section "1. Ping"

$dt = Start-Dots "Pinging $SenderIP (3 packets)"
Wait-Job $pingJob | Out-Null
Stop-Dots $dt
Write-Host ""

$pingResult = Receive-Job $pingJob -Wait -AutoRemoveJob -ErrorAction SilentlyContinue

if ($null -eq $pingResult) {
    Write-FAIL "Ping failed -- host unreachable or ICMP blocked on the path"
    Write-INFO "  UDP may still work if only ICMP is blocked."
    $pingFailed = $true
    $pingIssue  = $true
} else {
    Write-OK "Host reachable -- $($pingResult.Count)/3 replies"
    Write-INFO "  RTT  min=$($pingResult.Min)ms   avg=$($pingResult.Avg)ms   max=$($pingResult.Max)ms"

    if ($pingResult.Count -lt 3)    { Write-WARN "Packet loss: $(3 - $pingResult.Count)/3 pings dropped"; $pingIssue = $true }
    if ($pingResult.Avg -le 5)      { Write-OK   "  Latency looks excellent (LAN-grade)" }
    elseif ($pingResult.Avg -le 30) { Write-WARN "  Moderate latency ($($pingResult.Avg)ms avg)"; $pingIssue = $true }
    else                            { Write-FAIL "  High latency ($($pingResult.Avg)ms avg) -- expect noticeable input lag"; $pingIssue = $true }
}

# =============================================================================
# 2. LOCAL NETWORK INTERFACE
# =============================================================================
Write-Section "2. Local Network Interface"

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

$dt = Start-Dots "Testing path MTU"
$pmtuSize = Receive-Job $mtuJob -Wait -AutoRemoveJob -ErrorAction SilentlyContinue
Stop-Dots $dt
if ($pmtuSize -gt 0) { Write-Host " OK  (>= $($pmtuSize + 28) bytes)" -ForegroundColor Green }
else                 { Write-Host " low (< 1028 bytes)" -ForegroundColor Yellow; $mtuIssue = $true }

# =============================================================================
# 4. UDP CONNECTIVITY TEST
# =============================================================================
Write-Section "4. UDP Connectivity Test"
$udp        = Collect-UDPJobs $udpJobs
$result5005 = $udp.p5005
$result5006 = $udp.p5006
$result5007 = $udp.p5007

# -- No-connectivity early warning --------------------------------------------
if ($pingFailed -and -not ($result5005 -or $result5006 -or $result5007)) {
    $target = if ($Machine -eq "CLIENT") { "SERVER" } else { "CLIENT" }
    Write-Host ""
    Write-FAIL "No connectivity to the $target machine at $SenderIP -- ping and all UDP tests failed."
    Write-INFO "  Possible causes: wrong IP, machine is offline, or firewall is blocking everything."
    Write-Host "  Continue to summary anyway? [Y/N]" -ForegroundColor Yellow
    if ((Read-Host "  Choice") -notmatch "^[Yy]") { exit 2 }
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
$trace = Receive-Job $traceJob -Wait -AutoRemoveJob -ErrorAction SilentlyContinue
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

# When ports failed, ask once here so the calling launch script never needs to ask again.
if (-not ($result5005 -and $result5006 -and $result5007)) {
    Write-Host ""
    Write-Host "  Proceed with launch anyway? [Y/N]" -ForegroundColor Yellow
    if ((Read-Host "  Choice") -notmatch "^[Yy]") { exit 2 }
}
