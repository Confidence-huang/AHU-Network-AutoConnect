# AHU campus network auto login script - v6
# The script does one job:
# find the real campus client IP, then submit the portal login request.
#
# v6 highlights (over v5):
# - Host-agnostic: every network primitive works on both Windows PowerShell 5.1
#   and PowerShell 7 (.NET Ping, HttpWebRequest; no PS7-only parameters).
# - Portal requests bypass the system proxy on purpose: the portal is a campus
#   internal host, so a system/TUN proxy must never relay the credentials.
# - If a virtual default route (TUN/proxy client) owns 0.0.0.0/0, the
#   route-to-portal probe is skipped and the physical interface fallback runs
#   directly, instead of failing on every run.
# - JSONP responses are unwrapped and parsed as JSON first; ret_code is mapped
#   explicitly. ret_code=1 (bad account/password) fails fast with exit code 4
#   instead of burning all retries.
# - A local mutex prevents the hourly task and the network-event task from
#   logging in concurrently.
# - Daily logs past log_retention_days (default 30) are pruned at startup.
# - campus_ip_prefixes accepts legacy "172.21." strings and CIDR "172.21.0.0/16".
#
# Exit codes: 0 success/already online; 1 config error; 2 no campus IP;
#             3 all retries exhausted; 4 portal rejected every account.
#
# Example (manual diagnosis, no login request is sent):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:APPDATA\ahu-network\ahu-connect.ps1" -InspectOnly
param(
    [switch]$Visible,
    [switch]$InspectOnly,
    [switch]$NoMutex,
    [string]$HomeDirectory = "$env:APPDATA\ahu-network"
)

$ErrorActionPreference = "Stop"                  # Structural errors must stop the script before any login request is sent.

$script:InstallDirectory = $HomeDirectory        # Default install path stays compatible with existing tasks; tests can override it.
$configFile              = Join-Path $script:InstallDirectory "config.json"
$logDirectory            = Join-Path $script:InstallDirectory "logs"

# Dr.COM eportal ret_code glossary (same semantics as the upstream Python tools).
$script:RetCodeMessages = @{
    0   = "成功"
    1   = "账号或密码不对"
    2   = "终端IP已经在线"
    3   = "系统繁忙，请稍后再试"
    4   = "发生未知错误，请稍后再试"
    5   = "REQ_CHALLENGE 失败，请联系AC确认"
    6   = "REQ_CHALLENGE 超时，请联系AC确认"
    7   = "Radius 认证失败"
    8   = "Radius 认证超时"
    9   = "Radius 下线失败"
    10  = "Radius 下线超时"
    11  = "发生其他错误，请稍后再试"
    998 = "Portal协议参数不全"
}


# --- Runtime log ---
function Write-RunLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"  # One timestamp format lets task history and manual runs be compared directly.
    $line      = "[$timestamp] [$Level] $Message"        # Secrets are never written here; logs only contain state and selected IPs.

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
    if ($Visible) {
        Write-Host $line                                 # Visible mode is for manual diagnosis; scheduled runs stay hidden.
    }
}


# --- Startup state ---
function Initialize-RunState {
    if (-not (Test-Path -LiteralPath $script:InstallDirectory)) {
        New-Item -ItemType Directory -Path $script:InstallDirectory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    $script:LogFile = Join-Path $logDirectory "$(Get-Date -Format 'yyyy-MM-dd').log"  # Daily logs keep long-running task output readable.

    if (-not (Test-Path -LiteralPath $configFile)) {
        Write-RunLog "Missing config: $configFile. Copy config.example.json there and fill in the accounts." "CRITICAL"
        return $false
    }

    try {
        $script:Config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-RunLog "Config file is not valid JSON: $($_.Exception.Message)" "CRITICAL"
        return $false
    }

    $hostVersion = $PSVersionTable.PSVersion.ToString()  # Behavior differences between hosts used to hide bugs; record the host on every run.
    Write-RunLog "ahu-connect v6 starting (PowerShell $hostVersion)" "DEBUG"
    return $true
}


# --- Log retention ---
function Remove-StaleRunLogs {
    $retentionDays = 30
    if ($script:Config -and $script:Config.log_retention_days) {
        try { $retentionDays = [int]$script:Config.log_retention_days } catch { $retentionDays = 30 }
    }
    if ($retentionDays -le 0) {
        return                                           # 0 or negative disables pruning; logs grow unbounded by explicit choice.
    }

    $cutoff = (Get-Date).AddDays(-$retentionDays)
    Get-ChildItem -LiteralPath $logDirectory -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}


# --- Config list reader ---
function Get-ConfigList {
    param(
        [string]$Name,
        [object[]]$Fallback
    )

    $value = $null
    if ($script:Config -and $script:Config.PSObject.Properties[$Name]) {
        $value = $script:Config.$Name                    # Missing optional fields must not force a config migration.
    }
    if (-not $value) {
        return @($Fallback)
    }

    if ($value -is [array]) {
        return @($value)                                 # JSON arrays are the preferred shape for new options.
    }

    return @(([string]$value) -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}


# --- IP in CIDR ---
function Test-IpInCidr {
    param(
        [string]$IPAddress,
        [string]$Cidr
    )

    try {
        $parts = $Cidr -split "/"
        if ($parts.Count -ne 2) {
            return $false
        }

        $addr = [System.Net.IPAddress]::Parse($IPAddress)
        $base = [System.Net.IPAddress]::Parse($parts[0])
        if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
            $base.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $false                                # Campus rules are IPv4; IPv6 link-local noise must not match.
        }

        $prefixLen = [int]$parts[1]
        if ($prefixLen -lt 0 -or $prefixLen -gt 32) {
            return $false
        }

        $addrBytes = $addr.GetAddressBytes()
        $baseBytes = $base.GetAddressBytes()
        for ($i = 0; $i -lt $prefixLen; $i++) {
            $byteIndex = [math]::Floor($i / 8)
            $bitMask   = [math]::Pow(2, 7 - ($i % 8))
            if (($addrBytes[$byteIndex] -band $bitMask) -ne ($baseBytes[$byteIndex] -band $bitMask)) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}


# --- Campus IP rule ---
function Test-CampusIPAddress {
    param(
        [string]$IPAddress,
        [object[]]$CampusPrefixes
    )

    if (-not $IPAddress) {
        return $false                                    # No address means this interface cannot be used for portal auth.
    }

    foreach ($prefix in $CampusPrefixes) {
        $prefixText = [string]$prefix
        if (-not $prefixText) {
            continue
        }
        if ($prefixText.Contains("/")) {
            if (Test-IpInCidr $IPAddress $prefixText) {
                return $true                             # CIDR entries are the precise shape for new subnets.
            }
        }
        elseif ($IPAddress.StartsWith($prefixText)) {
            return $true                                 # Legacy "172.21." style entries keep old configs working.
        }
    }

    return $false
}


# --- Adapter cache ---
function Get-AdapterInfoCache {
    if (-not $script:AdapterCache) {
        $script:AdapterCache = @{}
        try {
            Get-NetAdapter -ErrorAction Stop | ForEach-Object {
                $script:AdapterCache[[int]$_.InterfaceIndex] = $_
            }
        }
        catch {
            $script:AdapterCache = @{}                   # Names alone still work when the adapter cmdlet is unavailable.
        }
    }
    return $script:AdapterCache
}


# --- Virtual interface rule ---
function Test-VirtualInterface {
    param(
        [string]$InterfaceAlias,
        [int]$InterfaceIndex = 0
    )

    $virtualPattern = "Mihomo|Clash|sing-box|singbox|WireGuard|OpenVPN|ZeroTier|Tailscale|TUN|TAP|VMware|vEthernet|Hyper-V|WSL|outline|Loopback|Bluetooth|Npcap|VirtualBox|Virtual"
    if ([string]$InterfaceAlias -match $virtualPattern) {
        return $true                                     # Proxy and VM adapters can have valid IPv4, but they are not portal clients.
    }

    if ($InterfaceIndex -gt 0) {
        $adapter = (Get-AdapterInfoCache)[[int]$InterfaceIndex]
        if ($adapter -and $adapter.Virtual) {
            return $true                                 # The Windows Virtual flag catches renames that defeat the alias regex.
        }
    }

    return $false
}


# --- Virtual default route rule ---
function Test-VirtualDefaultRoute {
    $defaultRoutes = @(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
    if (-not $defaultRoutes) {
        return $false
    }

    $best = $defaultRoutes | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
    if (-not $best) {
        return $false
    }

    return (Test-VirtualInterface ([string]$best.InterfaceAlias) ([int]$best.InterfaceIndex))
}


# --- Portal host list ---
function Get-PortalHostAddresses {
    $hosts = @()                                         # The portal URL and probe hosts describe the AHU side of the login.

    try {
        $portalUri = [uri]([string]$script:Config.portal_base)
        if ($portalUri.Host) {
            $hosts += $portalUri.Host                    # Example: 172.16.253.3 from http://172.16.253.3:801/eportal/.
        }
    }
    catch {
        Write-RunLog "Portal base is not a valid URI; fallback hosts will be used." "WARN"
    }

    $hosts += Get-ConfigList "portal_check_hosts" @("172.16.253.1", "172.16.253.3")
    return @($hosts | Where-Object { $_ } | Select-Object -Unique)
}


# --- Campus connection from portal route ---
function Get-CampusConnectionFromPortalRoute {
    $campusPrefixes   = Get-ConfigList "campus_ip_prefixes" @("10.", "172.16.", "172.21.", "172.29.")
    $preferredAliases = Get-ConfigList "preferred_interfaces" @("Ethernet", "以太网")

    if (Test-VirtualDefaultRoute) {
        Write-RunLog "Default route is owned by a virtual adapter; route probing is skipped for this run." "DEBUG"
        return $null                                     # Find-NetRoute would only answer with the TUN; fall through to interfaces.
    }

    foreach ($portalHost in (Get-PortalHostAddresses)) {
        try {
            $routeObjects  = @(Find-NetRoute -RemoteIPAddress ([string]$portalHost) -ErrorAction Stop)
            $sourceAddress = $routeObjects | Where-Object { $_.CimClass.CimClassName -eq "MSFT_NetIPAddress" } | Select-Object -First 1
            $route         = $routeObjects | Where-Object { $_.CimClass.CimClassName -eq "MSFT_NetRoute" } | Select-Object -First 1

            if (-not $sourceAddress) {
                Write-RunLog "No source IP found for route to portal host $portalHost." "DEBUG"
                continue                                 # A route without a source address cannot build wlan_user_ip.
            }

            $ipAddress      = [string]$sourceAddress.IPAddress
            $interfaceAlias = [string]$sourceAddress.InterfaceAlias
            $interfaceIndex = [int]$sourceAddress.InterfaceIndex
            $gateway        = if ($route -and $route.NextHop -ne "0.0.0.0") { [string]$route.NextHop } else { "" }

            if (-not (Test-CampusIPAddress $ipAddress $campusPrefixes)) {
                Write-RunLog "Reject route to $portalHost via $interfaceAlias/$ipAddress because it is not a campus IP." "DEBUG"
                continue                                 # This rejects Mihomo 198.18.x.x and other proxy tunnel results.
            }

            if (Test-VirtualInterface $interfaceAlias $interfaceIndex) {
                Write-RunLog "Reject route to $portalHost via virtual interface $interfaceAlias." "DEBUG"
                continue                                 # A virtual adapter may reach the host, but it is not the portal client.
            }

            if (-not $gateway) {
                $gateway = (Get-NetIPConfiguration -InterfaceIndex $interfaceIndex).IPv4DefaultGateway.NextHop | Select-Object -First 1
            }

            $adapter     = (Get-AdapterInfoCache)[$interfaceIndex]
            $linkSpeed   = if ($adapter -and $adapter.TransmitLinkSpeed) { [uint64]$adapter.TransmitLinkSpeed } else { [uint64]0 }

            return [pscustomobject]@{
                InterfaceAlias = $interfaceAlias         # This adapter is what Windows would use for the AHU portal host.
                InterfaceIndex = $interfaceIndex
                IPAddress      = $ipAddress              # This becomes wlan_user_ip in the portal login request.
                Gateway        = $gateway
                LinkSpeedBps   = $linkSpeed
                IsCampusIP     = $true
                IsVirtual      = $false
                HasGateway     = [bool]$gateway
                IsPreferred    = [bool]($preferredAliases | Where-Object { $interfaceAlias -like "*$_*" })
                SelectedBy     = "route-to-$portalHost"
            }
        }
        catch {
            Write-RunLog "Route probe failed for portal host ${portalHost}: $($_.Exception.Message)" "DEBUG"
        }
    }

    return $null                                         # The caller will fall back to direct campus-interface selection.
}


# --- Campus connection by interface list ---
function Get-CampusConnectionByInterface {
    $campusPrefixes   = Get-ConfigList "campus_ip_prefixes" @("10.", "172.16.", "172.21.", "172.29.")
    $preferredAliases = Get-ConfigList "preferred_interfaces" @("Ethernet", "以太网")
    $adapterCache     = Get-AdapterInfoCache

    $connections = Get-NetIPConfiguration | ForEach-Object {
        $interfaceAlias = $_.InterfaceAlias
        $interfaceIndex = [int]$_.InterfaceIndex
        $ipAddress      = ($_.IPv4Address | Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" } | Select-Object -First 1).IPAddress
        $gateway        = ($_.IPv4DefaultGateway | Select-Object -First 1).NextHop
        $adapter        = $adapterCache[$interfaceIndex]
        $linkSpeed      = if ($adapter -and $adapter.TransmitLinkSpeed) { [uint64]$adapter.TransmitLinkSpeed } else { [uint64]0 }

        if ($ipAddress) {
            [pscustomobject]@{
                InterfaceAlias = $interfaceAlias         # Human-readable Windows adapter name for diagnosis.
                InterfaceIndex = $interfaceIndex
                IPAddress      = $ipAddress              # This becomes wlan_user_ip in the portal login request.
                Gateway        = $gateway                # A real default gateway strongly indicates the active outlet.
                LinkSpeedBps   = $linkSpeed              # Link speed beats InterfaceIndex as a tiebreak because indexes drift.
                IsCampusIP     = Test-CampusIPAddress $ipAddress $campusPrefixes
                IsVirtual      = Test-VirtualInterface $interfaceAlias $interfaceIndex
                HasGateway     = [bool]$gateway
                IsPreferred    = [bool]($preferredAliases | Where-Object { $interfaceAlias -like "*$_*" })
                SelectedBy     = "interface-fallback"
            }
        }
    }

    $candidate = $connections |
        Where-Object { $_.IsCampusIP -and -not $_.IsVirtual -and $_.HasGateway } |
        Sort-Object @{ Expression = { $_.IsPreferred }; Descending = $true },
                    @{ Expression = { $_.LinkSpeedBps }; Descending = $true },
                    @{ Expression = { $_.InterfaceIndex }; Ascending = $true } |
        Select-Object -First 1

    if ($candidate) {
        return $candidate                                # Best case: campus subnet, physical adapter, and active gateway.
    }

    $candidate = $connections |
        Where-Object { $_.IsCampusIP -and -not $_.IsVirtual } |
        Sort-Object @{ Expression = { $_.IsPreferred }; Descending = $true },
                    @{ Expression = { $_.LinkSpeedBps }; Descending = $true },
                    @{ Expression = { $_.InterfaceIndex }; Ascending = $true } |
        Select-Object -First 1

    if ($candidate) {
        return $candidate                                # Fallback for moments when DHCP is up but the gateway is still settling.
    }

    $seenAddresses = ($connections | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }) -join "; "
    Write-RunLog "No campus interface matched. Seen IPv4: $seenAddresses" "WARN"
    return $null
}


# --- Campus connection discovery ---
function Get-CampusConnection {
    $routeCandidate = Get-CampusConnectionFromPortalRoute
    if ($routeCandidate) {
        return $routeCandidate                           # Route-to-portal wins when it points to a real campus IP.
    }

    return (Get-CampusConnectionByInterface)             # Proxy routes can be misleading, so keep the physical-interface fallback.
}


# --- Campus environment probes ---
function Get-CampusCheckHosts {
    param([object]$CampusConnection)

    if ($script:Config.check_host) {
        return @([string]$script:Config.check_host)      # Old config stays compatible and wins when the user sets it manually.
    }

    $configuredHosts = Get-ConfigList "portal_check_hosts" @("172.16.253.1", "172.16.253.3")
    if ($CampusConnection -and $CampusConnection.Gateway) {
        return @($CampusConnection.Gateway) + $configuredHosts
    }

    return $configuredHosts
}


# --- Single host ping ---
function Test-HostAlive {
    param(
        [string]$HostAddress,
        [int]$TimeoutMilliseconds = 2000
    )

    if (-not $HostAddress) {
        return $false                                    # Empty probe values are ignored instead of becoming noisy errors.
    }

    try {
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $reply  = $pinger.Send($HostAddress, $TimeoutMilliseconds)
        return [bool]($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    }
    catch {
        return $false                                    # Some campus devices block ping; a miss is diagnostic only.
    }
}


# --- HTTP body reader ---
function Read-HttpResponseBody {
    param($Response)

    try {
        $stream = $Response.GetResponseStream()
        if (-not $stream) {
            return ""
        }

        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $body   = $reader.ReadToEnd()
        if ($body -and $body.Length -gt 65536) {
            $body = $body.Substring(0, 65536)            # Portal answers are tiny; cap the read to keep logs and memory sane.
        }
        return $body
    }
    catch {
        return ""
    }
    finally {
        if ($Response) {
            $Response.Close()
        }
    }
}


# --- Portal HTTP request ---
function Invoke-PortalHttpRequest {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 10
    )

    if (-not $Url) {
        throw "Empty request URL."
    }

    $request                 = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method          = "GET"
    $request.Timeout         = [Math]::Max(1, $TimeoutSeconds) * 1000
    $request.ReadWriteTimeout = $request.Timeout
    $request.Proxy           = $null                     # Campus internal host: never let a system proxy relay credentials.
    $request.KeepAlive       = $false
    $request.AllowAutoRedirect = $true
    $request.UserAgent       = "Mozilla/5.0 AHU-Network-AutoConnect"

    try {
        $response = $request.GetResponse()
        return @{
            StatusCode = [int]$response.StatusCode
            Body       = (Read-HttpResponseBody $response)
        }
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            return @{                                    # An HTTP error page still proves the portal answered.
                StatusCode = [int]$response.StatusCode
                Body       = (Read-HttpResponseBody $response)
            }
        }
        throw                                            # No response at all is a transport failure for the caller to log.
    }
}


# --- Portal reachability ---
function Test-PortalReachable {
    try {
        $portalBase = [string]$script:Config.portal_base
        if (-not $portalBase) {
            return $false
        }

        Invoke-PortalHttpRequest -Url $portalBase -TimeoutSeconds 5 | Out-Null
        return $true                                     # Any HTTP response counts; some portals answer 403/404 to probes.
    }
    catch {
        return $false                                    # Transport failure means we should not assume AHU auth is possible now.
    }
}


# --- JSONP/JSON response parser ---
function Get-PortalResponseJson {
    param([string]$Body)

    if (-not $Body) {
        return $null
    }

    $trimmed = $Body.Trim()
    $match   = [regex]::Match($trimmed, '(?is)^\s*[A-Za-z_$][\w$]*\s*\((.*)\)\s*;?\s*$')
    if ($match.Success) {
        $trimmed = $match.Groups[1].Value                # dr1003({...}) -> {...}; greedy stop at the outermost close paren.
    }

    try {
        return ($trimmed | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}


# --- Portal result classification ---
function Get-PortalLoginResult {
    param([string]$Body)

    $json = Get-PortalResponseJson $Body
    if ($json) {
        $retCode  = $null
        $message  = ""
        $jsonProps = @($json.PSObject.Properties | ForEach-Object { $_.Name })

        if ($jsonProps -contains "ret_code") {
            try { $retCode = [int]$json.ret_code } catch { $retCode = -1 }
        }
        if ($jsonProps -contains "msg")        { $message = [string]$json.msg }
        if (-not $message -and $jsonProps -contains "ret_msg") { $message = [string]$json.ret_msg }

        if ($retCode -ne $null) {
            if (-not $message -and $script:RetCodeMessages.ContainsKey($retCode)) {
                $message = [string]$script:RetCodeMessages[$retCode]
            }

            switch ($retCode) {
                0       { return @{ Outcome = "Success";        Message = $message } }
                2       { return @{ Outcome = "AlreadyOnline";  Message = $message } }
                1       { return @{ Outcome = "BadCredentials"; Message = $message } }
                default { return @{ Outcome = "Retryable";      Message = $message } }
            }
        }

        if ($jsonProps -contains "result" -and "$($json.result)" -eq "1") {
            return @{ Outcome = "Success"; Message = $message }
        }

        return @{ Outcome = "Retryable"; Message = $message }   # Parsed JSON without a known verdict: retry, log what we got.
    }

    # Raw fallback for portals that answer in a shape ConvertFrom-Json rejects.
    if ($Body -match '"result"\s*:\s*"?1"?')        { return @{ Outcome = "Success";        Message = "" } }
    if ($Body -match '"ret_code"\s*:\s*"?0"?')      { return @{ Outcome = "Success";        Message = "" } }
    if ($Body -match '"ret_code"\s*:\s*"?2"?')      { return @{ Outcome = "AlreadyOnline";  Message = "" } }
    if ($Body -match '"ret_code"\s*:\s*"?(\d+)"?')  {
        $code = [int]$matches[1]
        $message = ""
        if ($script:RetCodeMessages.ContainsKey($code)) { $message = [string]$script:RetCodeMessages[$code] }
        if ($code -eq 1) { return @{ Outcome = "BadCredentials"; Message = $message } }
        return @{ Outcome = "Retryable"; Message = $message }
    }

    $message = ""
    if ($Body -match '"msg"\s*:\s*"([^"]*)"') {
        $message = $matches[1]
    }
    return @{ Outcome = "Retryable"; Message = $message }
}


# --- Portal login request ---
function Invoke-PortalLogin {
    param(
        [hashtable]$Account,
        [string]$IPAddress
    )

    $baseUrl = [string]$script:Config.portal_base
    $query   = "?c=Portal"
    $query  += "&a=login"
    $query  += "&callback=dr1003"
    $query  += "&login_method=1"
    $query  += "&user_account=$([uri]::EscapeDataString($Account.User))"        # Account names can contain provider suffixes such as @telecom.
    $query  += "&user_password=$([uri]::EscapeDataString($Account.Password))"   # Passwords are encoded and never written to logs.
    $query  += "&wlan_user_ip=$([uri]::EscapeDataString($IPAddress))"           # The selected physical campus IP is the critical field.
    $url     = $baseUrl + $query

    Write-RunLog "[$($Account.Tag)] Login with campus IP $IPAddress" "INFO"

    $body = ""
    try {
        $response = Invoke-PortalHttpRequest -Url $url -TimeoutSeconds 10
        $body     = [string]$response.Body
    }
    catch {
        Write-RunLog "[$($Account.Tag)] Request error: $($_.Exception.Message)" "ERROR"
        return @{ Outcome = "Retryable"; Message = "transport error" }
    }

    $result = Get-PortalLoginResult $body
    switch ($result.Outcome) {
        "Success"        { Write-RunLog "[$($Account.Tag)] Portal accepted the login." "INFO" }
        "AlreadyOnline"  { Write-RunLog "[$($Account.Tag)] Terminal IP is already online." "INFO" }
        "BadCredentials" { Write-RunLog "[$($Account.Tag)] Portal rejected the credentials: $($result.Message)" "ERROR" }
        default          { Write-RunLog "[$($Account.Tag)] Portal answered without success: $($result.Message)" "WARN" }
    }

    return $result
}


# --- Decide whether login is needed ---
function Test-CampusEnvironment {
    param([object]$CampusConnection)

    $campusEvidenceFound = $false
    foreach ($hostAddress in (Get-CampusCheckHosts $CampusConnection)) {
        if (Test-HostAlive $hostAddress) {
            Write-RunLog "Campus environment reachable: $hostAddress" "DEBUG"
            $campusEvidenceFound = $true
        }
    }

    if (Test-PortalReachable) {
        Write-RunLog "Portal is reachable; campus login can be attempted." "DEBUG"
        $campusEvidenceFound = $true
    }
    else {
        Write-RunLog "Portal is not reachable; the selected campus IP is still enough to try login." "DEBUG"
    }

    return $campusEvidenceFound                        # This is context only; portal API response is the login result.
}


# --- Build the configured account list ---
function Get-ConfiguredAccounts {
    $accounts = @()

    if ($script:Config.broadband_user -and $script:Config.broadband_pass) {
        $accounts += @{
            Tag      = "Broadband"
            User     = [string]$script:Config.broadband_user
            Password = [string]$script:Config.broadband_pass
        }
    }

    if ($script:Config.campus_user -and $script:Config.campus_pass) {
        $accounts += @{
            Tag      = "Campus"
            User     = [string]$script:Config.campus_user
            Password = [string]$script:Config.campus_pass
        }
    }

    return $accounts
}


# --- Main flow ---
function Start-AHUCampusLogin {
    $script:AdapterCache = $null

    if (-not (Initialize-RunState)) {
        return 1
    }

    Remove-StaleRunLogs

    $runMutex = $null
    if (-not $NoMutex) {
        $runMutex = New-Object System.Threading.Mutex($false, "Local\AHU-Network-AutoConnect")
        $acquired = $false
        try {
            $acquired = $runMutex.WaitOne(0)             # Another hourly/event run may already be authenticating.
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true                            # The previous holder died; the mutex is ours now.
        }
        if (-not $acquired) {
            Write-RunLog "Another instance is already running; nothing to do." "INFO"
            if ($runMutex) { $runMutex.Dispose() }
            return 0
        }
    }

    try {
        $campusConnection = Get-CampusConnection
        if (-not $campusConnection) {
            Write-RunLog "No campus IP available, skip login." "WARN"
            return 2
        }

        Write-RunLog "Campus interface: $($campusConnection.InterfaceAlias), ip=$($campusConnection.IPAddress), gateway=$($campusConnection.Gateway), selectedBy=$($campusConnection.SelectedBy)" "INFO"

        if ($InspectOnly) {
            $virtualDefault = Test-VirtualDefaultRoute
            $checkHosts     = (Get-CampusCheckHosts $campusConnection) -join ", "
            Write-RunLog "InspectOnly: host version $($PSVersionTable.PSVersion)" "INFO"
            Write-RunLog "InspectOnly: virtual default route = $virtualDefault" "INFO"
            Write-RunLog "InspectOnly: check hosts = $checkHosts" "INFO"
            Write-RunLog "InspectOnly: selected by $($campusConnection.SelectedBy)" "INFO"
            Write-RunLog "InspectOnly: no login request will be sent." "INFO"
            return 0
        }

        $accounts = Get-ConfiguredAccounts
        if (-not $accounts -or $accounts.Count -eq 0) {
            Write-RunLog "No account is configured in config.json; fill in campus_user/campus_pass or broadband_user/broadband_pass." "CRITICAL"
            return 1
        }

        Test-CampusEnvironment $campusConnection | Out-Null
        Write-RunLog "Campus IP is present; start idempotent portal login by portal API only." "INFO"

        $maxRetries = 10
        if ($script:Config.max_retries) {
            try { $maxRetries = [int]$script:Config.max_retries } catch { $maxRetries = 10 }
        }

        $retryIntervalSeconds = 10
        if ($script:Config.retry_interval_sec) {
            try { $retryIntervalSeconds = [int]$script:Config.retry_interval_sec } catch { $retryIntervalSeconds = 10 }
        }

        $disabledAccounts = @{}
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            Write-RunLog "=== Attempt $attempt/$maxRetries ===" "INFO"

            $campusConnection = Get-CampusConnection     # DHCP and route state can change while the retry loop is running.
            if (-not $campusConnection) {
                Write-RunLog "Campus IP disappeared during retry." "WARN"
                break
            }

            foreach ($account in $accounts) {
                if ($disabledAccounts.ContainsKey($account.Tag)) {
                    continue                             # A rejected account stays rejected for the whole run.
                }

                $result = Invoke-PortalLogin $account $campusConnection.IPAddress
                switch ($result.Outcome) {
                    "Success" {
                        Write-RunLog "[$($account.Tag)] login accepted by portal API." "SUCCESS"
                        return 0
                    }
                    "AlreadyOnline" {
                        Write-RunLog "[$($account.Tag)] already online; nothing to do." "SUCCESS"
                        return 0
                    }
                    "BadCredentials" {
                        $disabledAccounts[$account.Tag] = $true
                    }
                    default {
                        # Retryable answers fall through to the next attempt.
                    }
                }
            }

            if ($disabledAccounts.Count -ge $accounts.Count) {
                Write-RunLog "Portal rejected every configured account; stopping retries to protect the accounts." "CRITICAL"
                return 4
            }

            if ($attempt -lt $maxRetries) {
                Write-RunLog "Waiting ${retryIntervalSeconds}s before next retry." "INFO"
                Start-Sleep -Seconds $retryIntervalSeconds
            }
        }

        Write-RunLog "All $maxRetries attempts failed; leaving the computer and network state unchanged." "CRITICAL"
        return 3
    }
    finally {
        if ($runMutex) {
            try { $runMutex.ReleaseMutex() } catch { }
            $runMutex.Dispose()
        }
    }
}


# Run only when executed as a script; dot-sourcing loads the functions for tests.
if ($MyInvocation.InvocationName -ne ".") {
    $script:ExitCode = Start-AHUCampusLogin
    if ($Visible) {
        switch ($script:ExitCode) {
            0       { Write-Host "`n[OK] Network is authenticated." -ForegroundColor Green }
            2       { Write-Host "`n[SKIP] No campus network detected." -ForegroundColor Yellow }
            3       { Write-Host "`n[FAIL] Login did not succeed." -ForegroundColor Red }
            4       { Write-Host "`n[FAIL] Account or password was rejected." -ForegroundColor Red }
            default { Write-Host "`n[ERROR] Exit code $script:ExitCode." -ForegroundColor Red }
        }
    }
    exit $script:ExitCode
}
