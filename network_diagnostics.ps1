#Requires -Version 5.1
<#
.SYNOPSIS
    Network diagnostics for RemoteGamepad — run on the RECEIVER machine.
.PARAMETER SenderIP
    IP address of the sender machine. If omitted, you will be prompted.
.EXAMPLE
    .\network_diagnostics.ps1
    .\network_diagnostics.ps1 192.168.1.50
#>

param([string]$SenderIP)

# ── Ports ─────────────────────────────────────────────────────────────────────
$CONTROLLER_PORT = 5005   # receiver binds (inbound from sender)
$VIDEO_PORT      = 5006   # receiver binds (inbound from sender)
$ACK_PORT        = 5007   # receiver sends ACKs to sender (outbound); sender binds this

# ── Console helpers ───────────────────────────────────────────────────────────
function Write-Section([string]$title) {
    $line = "─" * [Math]::Max(2, 62 - $title.Length)
    Write-Host ""
    Write-Host "  $title $line" -ForegroundColor Cyan
}
function Write-OK([string]$msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green  }
function Write-WARN([string]$msg) { Write-Host "  [!]   $msg" -ForegroundColor Yellow }
function Write-FAIL([string]$msg) { Write-Host "  [X]   $msg" -ForegroundColor Red    }
function Write-INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor Gray   }

# ── 0. Collect sender IP ──────────────────────────────────────────────────────
if (-not $SenderIP) {
    $SenderIP = (Read-Host "Enter the SENDER machine's IP address").Trim()
}
$SenderIP = $SenderIP.Trim()

if ($SenderIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    Write-FAIL "Invalid IP address: '$SenderIP'"
    exit 1
}

Write-Host ""
Write-Host " RemoteGamepad — Network Diagnostics (RECEIVER side) " -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "  Sender IP : $SenderIP"
Write-Host "  Ports     : $CONTROLLER_PORT/UDP (controller)  $VIDEO_PORT/UDP (video)  $ACK_PORT/UDP (ACK out)"

# ─────────────────────────────────────────────────────────────────────────────
# 1. PING
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "1. Ping"

$pings = Test-Connection -ComputerName $SenderIP -Count 6 -ErrorAction SilentlyContinue
if (-not $pings) {
    Write-FAIL "Ping failed — host unreachable or ICMP blocked on the path"
    Write-INFO "  UDP may still work if only ICMP is blocked, but connectivity is uncertain."
} else {
    $rtts = $pings | ForEach-Object { $_.ResponseTime }
    $avg  = [Math]::Round(($rtts | Measure-Object -Average).Average, 1)
    $min  = ($rtts | Measure-Object -Minimum).Minimum
    $max  = ($rtts | Measure-Object -Maximum).Maximum
    $recv = $pings.Count

    Write-OK "Host reachable — $recv/6 replies"
    Write-INFO "  RTT  min=${min}ms   avg=${avg}ms   max=${max}ms"

    if ($recv -lt 6) {
        Write-WARN "Packet loss: $(6 - $recv)/6 pings dropped — unstable path"
    }
    if ($avg -le 5)       { Write-OK   "  Latency looks excellent (LAN-grade)" }
    elseif ($avg -le 30)  { Write-WARN "  Moderate latency — input feel may vary" }
    else                  { Write-FAIL "  High latency (${avg}ms avg) — expect noticeable input lag" }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. LOCAL NETWORK INTERFACE
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "2. Local Network Interface"

$localAddresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }

foreach ($addr in $localAddresses) {
    $adapter     = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex -ErrorAction SilentlyContinue
    $adapterName = if ($adapter) { $adapter.Name }      else { "?" }
    $status      = if ($adapter) { $adapter.LinkSpeed } else { "?" }
    Write-INFO "  [$adapterName]  $($addr.IPAddress)/$($addr.PrefixLength)   $status"
}

# Same-subnet heuristic (works for /24 and /16)
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
    Write-WARN "Sender appears to be on a different subnet — NAT/routing will be involved"
    Write-INFO "  Make sure port forwarding or DMZ is configured on the sender's router."
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. MTU / JUMBO FRAMES
# ─────────────────────────────────────────────────────────────────────────────
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
Write-INFO "  MJPEG frames at 480p are typically 10–50 KB — well within the limit"

# Optional: test path MTU using ping with Don't-Fragment
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
    Write-WARN "  Path MTU may be less than 1028 bytes — fragmentation likely"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. WINDOWS FIREWALL — INBOUND RULES
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "4. Windows Firewall — Inbound Rules"

# Check if Windows Firewall is active on the active profile
$activeProfiles = Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $true }
if (-not $activeProfiles) {
    Write-WARN "Windows Firewall is disabled on all profiles — no rules needed, but also no protection"
} else {
    Write-INFO "  Firewall active on: $(($activeProfiles.Name) -join ", ")"
}

function Find-InboundUDPRule([int]$port) {
    # Walk enabled, inbound, allow rules and check their port filters
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

$portsToCheck = @(
    @{ Port = $CONTROLLER_PORT; Label = "Controller input" },
    @{ Port = $VIDEO_PORT;      Label = "Video stream"     }
)

$missingPorts = @()
foreach ($p in $portsToCheck) {
    Write-Host -NoNewline "  Checking UDP $($p.Port) ($($p.Label))... " -ForegroundColor Gray
    $ruleName = Find-InboundUDPRule -port $p.Port
    if ($ruleName) {
        Write-Host "[OK]  Rule: $ruleName" -ForegroundColor Green
    } else {
        Write-Host "[MISSING]" -ForegroundColor Red
        $missingPorts += $p
    }
}

# ACK port — outbound only, rarely needs an inbound rule on receiver
Write-INFO "  UDP $ACK_PORT (ACK) — receiver sends outbound; no inbound rule required here"

if ($missingPorts.Count -gt 0) {
    Write-Host ""
    Write-WARN "Missing inbound firewall rules for: $(($missingPorts | ForEach-Object { "UDP $($_.Port)" }) -join ", ")"
    Write-Host ""
    Write-Host "  Create the missing rules now?" -ForegroundColor Yellow
    Write-Host "   [Y] Yes — open an elevated window and create them"
    Write-Host "   [N] No  — skip (you can re-run this script later)"
    $answer = Read-Host "  Choice"

    if ($answer -match "^[Yy]") {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)

        $ruleCmds = ($missingPorts | ForEach-Object {
            "New-NetFirewallRule -DisplayName 'RemoteGamepad $($_.Label) UDP $($_.Port)' " +
            "-Direction Inbound -Protocol UDP -LocalPort $($_.Port) -Action Allow -Profile Any -ErrorAction Stop | Out-Null; " +
            "Write-Host 'Created rule for UDP $($_.Port)' -ForegroundColor Green"
        }) -join "; "
        $pauseCmd = "; Write-Host ''; Write-Host 'Done. Press Enter to close...' -ForegroundColor Cyan; Read-Host"

        if ($isAdmin) {
            foreach ($p in $missingPorts) {
                try {
                    New-NetFirewallRule `
                        -DisplayName "RemoteGamepad $($p.Label) UDP $($p.Port)" `
                        -Direction Inbound -Protocol UDP -LocalPort $p.Port `
                        -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                    Write-OK "Created inbound rule for UDP $($p.Port)"
                } catch {
                    Write-FAIL "Could not create rule for UDP $($p.Port): $($_.Exception.Message)"
                }
            }
        } else {
            Write-INFO "  Launching elevated PowerShell to create rules..."
            Start-Process powershell.exe -Verb RunAs `
                -ArgumentList "-NoProfile -Command `"$ruleCmds$pauseCmd`""
            Write-INFO "  Rules will be created in the elevated window. Re-run this script to verify."
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. PORT AVAILABILITY — IS ANYTHING ALREADY BOUND?
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "5. Port Availability (is anything already listening?)"

$netstatOutput = netstat -an -p UDP

# Check inbound ports the receiver binds
foreach ($port in @($CONTROLLER_PORT, $VIDEO_PORT)) {
    $bound = $netstatOutput | Select-String "[\s:]$port\s"
    if ($bound) {
        Write-OK "UDP $port — already bound (receiver may be running)"
    } else {
        try {
            $sock = New-Object System.Net.Sockets.UdpClient($port)
            $sock.Close()
            Write-INFO "  UDP $port — not bound; ready for receiver to use"
        } catch {
            Write-WARN "UDP $port — bind failed: port already in use by another app"
        }
    }
}

# ACK port is outbound-only on the receiver; just report if something else grabbed it
$abound = $netstatOutput | Select-String "[\s:]$ACK_PORT\s"
if ($abound) {
    Write-WARN "UDP $ACK_PORT — already bound locally (another app may interfere with ACKs)"
} else {
    Write-INFO "  UDP $ACK_PORT — not bound locally (correct — receiver sends ACKs outbound, never binds this port)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. UDP REACHABILITY — PROBE THE SENDER'S ACK PORT
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "6. UDP Reachability — Probe Sender's ACK Port ($ACK_PORT)"
Write-INFO "  Sending a test UDP datagram to ${SenderIP}:${ACK_PORT} and waiting 1 s for a reply..."
Write-INFO "  (A reply only comes if video_udp_sender.py is running on the sender)"

try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = 1000
    $remoteEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($SenderIP), $ACK_PORT)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("DIAG")
    $udp.Send($bytes, $bytes.Length, $remoteEP) | Out-Null

    try {
        $replyEP    = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $replyBytes = $udp.Receive([ref]$replyEP)
        Write-OK "Got a UDP reply from $($replyEP.Address):$($replyEP.Port) — bidirectional path confirmed!"
    } catch [System.Net.Sockets.SocketException] {
        Write-INFO "  No reply received (expected if video_udp_sender.py is not running)"
        Write-INFO "  The packet was sent without error — outbound UDP path looks OK"
    }
    $udp.Close()
} catch {
    Write-FAIL "Failed to send UDP packet: $($_.Exception.Message)"
}

# Bonus: check if sender ACK port responds to a TCP connection attempt (just for info)
Write-INFO "  TCP probe on port $ACK_PORT (for reference — RemoteGamepad uses UDP)..."
$tcpResult = Test-NetConnection -ComputerName $SenderIP -Port $ACK_PORT -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue
if ($tcpResult) {
    Write-INFO "  TCP $ACK_PORT reachable (unrelated to UDP, but indicates no blanket block)"
} else {
    Write-INFO "  TCP $ACK_PORT not reachable (normal — sender uses UDP only)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. ROUTE TRACE
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "7. Route to Sender (up to 10 hops)"

try {
    $trace = Test-NetConnection -ComputerName $SenderIP -TraceRoute -Hops 10 `
        -WarningAction SilentlyContinue -ErrorAction Stop
    $hops = $trace.TraceRoute | Where-Object { $_ -ne "0.0.0.0" -and $_ -ne "::" }
    if ($hops) {
        $n = 1
        foreach ($h in $hops) { Write-INFO "  Hop $n : $h"; $n++ }
        $hopCount = @($hops).Count
        if ($hopCount -eq 1)      { Write-OK   "Direct connection ($hopCount hop) — same LAN or VPN tunnel" }
        elseif ($hopCount -le 3)  { Write-OK   "Short route ($hopCount hops)" }
        elseif ($hopCount -le 6)  { Write-WARN "Medium route ($hopCount hops) — may introduce jitter" }
        else                      { Write-FAIL "Long route ($hopCount hops) — high jitter risk for real-time input" }
    } else {
        Write-INFO "  Route data not available (hops may be blocking ICMP TTL-exceeded)"
    }
} catch {
    Write-INFO "  Traceroute failed or timed out: $($_.Exception.Message)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. DNS RESOLUTION CHECK
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "8. DNS / Reverse Lookup"
try {
    $reverse = [System.Net.Dns]::GetHostEntry($SenderIP)
    Write-INFO "  Reverse DNS: $SenderIP → $($reverse.HostName)"
} catch {
    Write-INFO "  No reverse DNS record for $SenderIP (normal for LAN IPs)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. SUMMARY TABLE
# ─────────────────────────────────────────────────────────────────────────────
Write-Section "9. Summary"
Write-Host ""
Write-Host "  Port layout:" -ForegroundColor White
Write-Host "    5005/UDP  Controller   Receiver LISTENS  ← inbound firewall rule required HERE"
Write-Host "    5006/UDP  Video        Receiver LISTENS  ← inbound firewall rule required HERE"
Write-Host "    5007/UDP  Latency ACK  Receiver SENDS →  sender must allow inbound 5007"
Write-Host ""
Write-Host "  If any tests failed:" -ForegroundColor White
Write-Host "    • Missing inbound rules  → re-run this script and choose Y when prompted"
Write-Host "    • Sender side (5007)     → run this script on the SENDER machine too"
Write-Host "    • High latency / hops    → prefer wired Ethernet or same LAN for low latency"
Write-Host "    • MTU issues             → run setup_jumbo_frames.ps1 on both machines (LAN only)"
Write-Host "    • Bind failure on 5005/6 → stop any running receiver process first"
Write-Host ""
