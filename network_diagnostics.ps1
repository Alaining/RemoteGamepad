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

# -- Async helpers ------------------------------------------------------------
# Runs $block in a background runspace, printing dots every 500ms while it runs.
# Does NOT print a trailing newline so the caller can append the result on the same line.
# Returns the first object yielded by the scriptblock, or $null on error.
function Invoke-WithDots([string]$msg, [scriptblock]$block, [object[]]$arguments = @()) {
    Write-Host -NoNewline "  $msg" -ForegroundColor Gray
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($block) | Out-Null
    foreach ($a in $arguments) { $ps.AddArgument($a) | Out-Null }
    $handle = $ps.BeginInvoke()
    while (-not $handle.IsCompleted) {
        Write-Host -NoNewline '.' -ForegroundColor Gray
        Start-Sleep -Milliseconds 500
    }
    try { $col = $ps.EndInvoke($handle) } catch { $col = $null }
    $rs.Close(); $ps.Dispose()
    return $col
}

# Starts a runspace immediately (without waiting) so the port/resource is
# acquired early. Call Complete-AsyncTask later to collect the result with dots.
function New-AsyncTask([scriptblock]$block, [object[]]$arguments = @()) {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($block) | Out-Null
    foreach ($a in $arguments) { $ps.AddArgument($a) | Out-Null }
    return @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

# Waits for a task started with New-AsyncTask, printing dots until done.
# Does NOT print a trailing newline.
function Complete-AsyncTask($task, [string]$msg) {
    Write-Host -NoNewline "  $msg" -ForegroundColor Gray
    while (-not $task.Handle.IsCompleted) {
        Write-Host -NoNewline '.' -ForegroundColor Gray
        Start-Sleep -Milliseconds 500
    }
    try { $col = $task.PS.EndInvoke($task.Handle) } catch { $col = $null }
    $task.RS.Close(); $task.PS.Dispose()
    return $col
}

# Unwraps the first element from a runspace result collection.
function Get-TaskResult($col, [hashtable]$fallback = @{ OK = $false }) {
    if ($col -and $col.Count -gt 0) { return $col[0] }
    return $fallback
}

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
    if ($existing) { Write-OK "Rule already exists: $existing  (no action taken)"; return }
    $displayName = "RemoteGamepad $label UDP $port"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        try {
            New-NetFirewallRule -DisplayName $displayName `
                -Direction Inbound -Protocol UDP -LocalPort $port `
                -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Write-OK "Rule created: $displayName"
        } catch { Write-FAIL "Could not create rule: $($_.Exception.Message)" }
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
    Write-FAIL "Invalid IP address: '$SenderIP'"; exit 1
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

$pingCol = Invoke-WithDots "Pinging $SenderIP (6 packets)" {
    param($ip)
    Test-Connection -ComputerName $ip -Count 6 -ErrorAction SilentlyContinue
} @($SenderIP)
Write-Host ""

$pings = $pingCol   # Collection[psobject] works like an array for ForEach / Measure-Object
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
$onSameLAN = $false
foreach ($addr in $localAddresses) {
    $localOctets = $addr.IPAddress.Split(".")
    $sharedBytes = [Math]::Floor($addr.PrefixLength / 8)
    if ($sharedBytes -ge 2 -and
        ($localOctets[0..($sharedBytes-1)] -join ".") -eq ($senderOctets[0..($sharedBytes-1)] -join ".")) {
        Write-OK "Other machine is on the same LAN subnet"
        $onSameLAN = $true; break
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
        if ($mtu -ge 9000)    { Write-OK   "[$($adapter.Name)] MTU = $mtu  (jumbo frames ENABLED)" }
        elseif ($mtu -ge 1500){ Write-INFO "  [$($adapter.Name)] MTU = $mtu  (standard Ethernet)" }
    }
}

Write-Host -NoNewline "  Testing path MTU" -ForegroundColor Gray
$pmtuOk = $false
foreach ($size in @(1472, 1400, 1000)) {
    Write-Host -NoNewline '.' -ForegroundColor Gray
    $pingOut = ping.exe -n 1 -f -l $size $SenderIP
    if ($pingOut -match "Reply from") { $pmtuOk = $true; break }
}
if ($pmtuOk) { Write-Host " OK  (>= $($size + 28) bytes)" -ForegroundColor Green }
else         { Write-Host " low (< 1028 bytes)" -ForegroundColor Yellow; $mtuIssue = $true }

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
    $thisIP = if ($localAddresses) { $localAddresses[0].IPAddress } else { "?" }
    Write-Host ""
    Write-Host "  --> Run this on the CLIENT machine now:" -ForegroundColor Yellow
    Write-Host "      .\network_diagnostics.ps1 $thisIP CLIENT" -ForegroundColor White
    Write-Host ""

    # Wait for 5005 probe from client
    $col5005 = Invoke-WithDots "Waiting for client probe on UDP $CONTROLLER_PORT (2 min timeout)" {
        param($port, $pong)
        $s = New-Object System.Net.Sockets.UdpClient
        try { $s.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port)) }
        catch { return @{ OK = $false; Error = "bind_failed" } }
        $s.Client.ReceiveTimeout = 120000
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $null = $s.Receive([ref]$ep)
            $s.Send($pong, $pong.Length, $ep) | Out-Null
            @{ OK = $true; IP = $ep.Address.ToString() }
        } catch { @{ OK = $false; Error = "timeout" } }
        finally { $s.Close() }
    } @($CONTROLLER_PORT, $PONG)
    $r5005 = Get-TaskResult $col5005
    if     ($r5005.OK)                    { Write-Host " [OK]  probe from $($r5005.IP)" -ForegroundColor Green; $result5005 = $true; $clientIP = $r5005.IP }
    elseif ($r5005.Error -eq "bind_failed"){ Write-Host " port busy (controller_udp_receiver.py running?)" -ForegroundColor Yellow }
    else                                  { Write-Host " [TIMEOUT]" -ForegroundColor Red }

    $clientIP = if ($clientIP) { $clientIP } else { $SenderIP }

    # Wait for 5007 probe from client
    $col5007 = Invoke-WithDots "Waiting for client probe on UDP $ACK_PORT (30s timeout)" {
        param($port, $pong)
        $s = New-Object System.Net.Sockets.UdpClient
        try { $s.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port)) }
        catch { return @{ OK = $false; Error = "bind_failed" } }
        $s.Client.ReceiveTimeout = 30000
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $null = $s.Receive([ref]$ep)
            $s.Send($pong, $pong.Length, $ep) | Out-Null
            @{ OK = $true }
        } catch { @{ OK = $false; Error = "timeout" } }
        finally { $s.Close() }
    } @($ACK_PORT, $PONG)
    $r5007 = Get-TaskResult $col5007
    if     ($r5007.OK)                     { Write-Host " [OK]" -ForegroundColor Green; $result5007 = $true }
    elseif ($r5007.Error -eq "bind_failed") { Write-Host " port busy" -ForegroundColor Yellow }
    else                                   { Write-Host " [TIMEOUT]" -ForegroundColor Red }

    # Probe client's 5006
    $col5006 = Invoke-WithDots "Probing client UDP $VIDEO_PORT at $clientIP (15s timeout)" {
        param($ip, $port, $diag)
        $s = New-Object System.Net.Sockets.UdpClient
        $s.Client.ReceiveTimeout = 15000
        try {
            $s.Send($diag, $diag.Length, $ip, $port) | Out-Null
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $s.Receive([ref]$ep)
            @{ OK = $true; IP = $ep.Address.ToString() }
        } catch { @{ OK = $false } }
        finally { $s.Close() }
    } @($clientIP, $VIDEO_PORT, $DIAG)
    $r5006 = Get-TaskResult $col5006
    if ($r5006.OK) { Write-Host " [OK]  client replied" -ForegroundColor Green; $result5006 = $true }
    else           { Write-Host " [TIMEOUT]" -ForegroundColor Red }

} else {
    # CLIENT
    Write-INFO "  Binding to UDP $VIDEO_PORT first, then probing server..."

    # Start 5006 listener BEFORE probing server so port is bound when server probes us back
    $task5006 = New-AsyncTask {
        param($port, $pong)
        $s = New-Object System.Net.Sockets.UdpClient
        try { $s.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port)) }
        catch { return @{ OK = $false; Error = "bind_failed" } }
        $s.Client.ReceiveTimeout = 30000
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        try {
            $null = $s.Receive([ref]$ep)
            $s.Send($pong, $pong.Length, $ep) | Out-Null
            @{ OK = $true; IP = $ep.Address.ToString() }
        } catch { @{ OK = $false; Error = "timeout" } }
        finally { $s.Close() }
    } @($VIDEO_PORT, $PONG)

    # Probe server:5005
    $col5005 = Invoke-WithDots "Probing server UDP $CONTROLLER_PORT at $SenderIP (10s timeout)" {
        param($ip, $port, $diag)
        $s = New-Object System.Net.Sockets.UdpClient
        $s.Client.ReceiveTimeout = 10000
        try {
            $s.Send($diag, $diag.Length, $ip, $port) | Out-Null
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $s.Receive([ref]$ep)
            @{ OK = $true; IP = $ep.Address.ToString() }
        } catch { @{ OK = $false } }
        finally { $s.Close() }
    } @($SenderIP, $CONTROLLER_PORT, $DIAG)
    $r5005 = Get-TaskResult $col5005
    if ($r5005.OK) { Write-Host " [OK]  server $($r5005.IP) replied" -ForegroundColor Green; $result5005 = $true }
    else           { Write-Host " [TIMEOUT]" -ForegroundColor Red }

    # Probe server:5007
    $col5007 = Invoke-WithDots "Probing server UDP $ACK_PORT at $SenderIP (10s timeout)" {
        param($ip, $port, $diag)
        $s = New-Object System.Net.Sockets.UdpClient
        $s.Client.ReceiveTimeout = 10000
        try {
            $s.Send($diag, $diag.Length, $ip, $port) | Out-Null
            $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $null = $s.Receive([ref]$ep)
            @{ OK = $true; IP = $ep.Address.ToString() }
        } catch { @{ OK = $false } }
        finally { $s.Close() }
    } @($SenderIP, $ACK_PORT, $DIAG)
    $r5007 = Get-TaskResult $col5007
    if ($r5007.OK) { Write-Host " [OK]  server $($r5007.IP) replied" -ForegroundColor Green; $result5007 = $true }
    else           { Write-Host " [TIMEOUT]" -ForegroundColor Red }

    # Collect 5006 result (task was already running)
    $col5006 = Complete-AsyncTask $task5006 "Waiting for server probe on UDP $VIDEO_PORT (30s timeout)"
    $r5006 = Get-TaskResult $col5006
    if     ($r5006.OK)                     { Write-Host " [OK]  probe from $($r5006.IP)" -ForegroundColor Green; $result5006 = $true }
    elseif ($r5006.Error -eq "bind_failed") { Write-Host " port busy (video_receiver.py running?)" -ForegroundColor Yellow }
    else                                   { Write-Host " [TIMEOUT]" -ForegroundColor Red }
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
            try { $sock = New-Object System.Net.Sockets.UdpClient($port); $sock.Close()
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

$traceCol = Invoke-WithDots "Tracing route to $SenderIP" {
    param($ip)
    try { Test-NetConnection -ComputerName $ip -TraceRoute -Hops 10 -WarningAction SilentlyContinue -ErrorAction Stop }
    catch { $null }
} @($SenderIP)
Write-Host ""

$trace = if ($traceCol) { $traceCol[0] } else { $null }
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
        if ((Read-Host "  Choice") -match "^[Yy]") { Invoke-CreateFirewallRule -port $VIDEO_PORT -label "Video Stream" }
    }
    if (-not $result5005 -or -not $result5007) {
        $failedServer = @()
        if (-not $result5005) { $failedServer += "UDP $CONTROLLER_PORT" }
        if (-not $result5007) { $failedServer += "UDP $ACK_PORT" }
        Write-WARN "$($failedServer -join " and ") did not pass -- the SERVER may need inbound rules for those ports."
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
                $lbl = if ($p -eq $CONTROLLER_PORT) { "Controller Data" } else { "Latency ACKs" }
                Invoke-CreateFirewallRule -port $p -label $lbl
            }
        }
    }
    if (-not $result5006) { Write-WARN "UDP $VIDEO_PORT (video) did not reach the client -- the CLIENT may need an inbound rule." }
    if ($result5005 -and $result5006 -and $result5007) { Write-OK "All three ports passed end-to-end." }
}

$tips = @()
if ($pingIssue -or $routeIssue) { $tips += "High latency / many hops  -> prefer wired Ethernet or same LAN" }
if ($mtuIssue)                  { $tips += "MTU issues -> run setup_jumbo_frames.ps1 on both machines (LAN only)" }
if ($tips.Count -gt 0) {
    Write-Host ""
    Write-Host "  Tips:" -ForegroundColor White
    foreach ($tip in $tips) { Write-Host "    * $tip" }
}

Write-Host ""
