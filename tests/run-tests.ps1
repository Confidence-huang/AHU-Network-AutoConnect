# Offline unit tests for ahu-connect.ps1.
# Runs on Windows PowerShell 5.1 and PowerShell 7. No portal request is sent.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
#   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$enginePath = Join-Path $scriptRoot "ahu-connect.ps1"

$passed = 0
$failed = 0
$failures = @()

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Name
    )
    if ($Condition) {
        $script:passed++
        Write-Host "  PASS  $Name"
    }
    else {
        $script:failed++
        $script:failures += $Name
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

# --- Load engine functions without running the main flow ---
. $enginePath -NoMutex -HomeDirectory (Join-Path $env:TEMP "ahu-connect-test-home")

Write-Host "Host: PowerShell $($PSVersionTable.PSVersion)"
Write-Host ""
Write-Host "[1] Campus IP prefix rules"
Assert-True (Test-CampusIPAddress "172.21.12.248" @("10.", "172.16.", "172.21.")) "legacy prefix match wired campus IP"
Assert-True (Test-CampusIPAddress "10.60.12.9"    @("10.", "172.16."))          "legacy prefix match 10.x"
Assert-True (-not (Test-CampusIPAddress "198.18.0.1" @("10.", "172.16.", "172.21."))) "proxy TUN fake-ip rejected"
Assert-True (-not (Test-CampusIPAddress "192.168.244.1" @("10.", "172.16.", "172.21."))) "VMware subnet rejected"
Assert-True (-not (Test-CampusIPAddress "" @("10.")))  "empty IP rejected"
Assert-True (-not (Test-CampusIPAddress "fe80::1" @("10.")))  "IPv6 rejected"
Assert-True (Test-CampusIPAddress "172.21.99.5" @("172.21.0.0/16")) "CIDR /16 match"
Assert-True (-not (Test-CampusIPAddress "172.20.1.1" @("172.21.0.0/16"))) "CIDR /16 non-match"
Assert-True (Test-CampusIPAddress "10.88.3.4" @("10.0.0.0/8")) "CIDR /8 match"
Assert-True (-not (Test-CampusIPAddress "11.0.0.1" @("10.0.0.0/8"))) "CIDR /8 non-match"

Write-Host ""
Write-Host "[2] Virtual interface rules"
Assert-True (Test-VirtualInterface "Mihomo")                     "alias regex catches Mihomo"
Assert-True (Test-VirtualInterface "vEthernet (WSL)")            "alias regex catches vEthernet"
Assert-True (Test-VirtualInterface "Clash TUN")                  "alias regex catches Clash TUN"
Assert-True (-not (Test-VirtualInterface "以太网"))               "Chinese Ethernet alias is physical"
Assert-True (-not (Test-VirtualInterface "WLAN"))                "WLAN is physical"

Write-Host ""
Write-Host "[3] Portal response classification"
$result = Get-PortalLoginResult 'dr1003({"ret_code":0,"msg":"","error_msg":"ok"});'
Assert-True ($result.Outcome -eq "Success") "ret_code 0 -> Success"
$result = Get-PortalLoginResult 'dr1003({"ret_code":1,"msg":"用户名或密码错误"});'
Assert-True ($result.Outcome -eq "BadCredentials") "ret_code 1 -> BadCredentials"
Assert-True ($result.Message -like "*密码*")        "ret_code 1 message surfaced"
$result = Get-PortalLoginResult 'dr1003({"ret_code":2,"msg":"ip already online"});'
Assert-True ($result.Outcome -eq "AlreadyOnline") "ret_code 2 -> AlreadyOnline"
$result = Get-PortalLoginResult 'dr1003({"ret_code":3,"msg":"busy"});'
Assert-True ($result.Outcome -eq "Retryable") "ret_code 3 -> Retryable"
$result = Get-PortalLoginResult 'dr1003({"ret_code":998,"msg":""});'
Assert-True ($result.Outcome -eq "Retryable") "ret_code 998 -> Retryable"
$result = Get-PortalLoginResult '{"result":"1"}'
Assert-True ($result.Outcome -eq "Success") "result string 1 -> Success"
$result = Get-PortalLoginResult '{"result":1}'
Assert-True ($result.Outcome -eq "Success") "result number 1 -> Success"
$result = Get-PortalLoginResult '<html><body>502 Bad Gateway</body></html>'
Assert-True ($result.Outcome -eq "Retryable") "HTML error page -> Retryable (not success)"
$result = Get-PortalLoginResult ''
Assert-True ($result.Outcome -eq "Retryable") "empty body -> Retryable"
$result = Get-PortalLoginResult 'dr1003({"ret_code":0});'
Assert-True ($result.Outcome -eq "Success") "JSONP without trailing semicolon -> Success"

Write-Host ""
Write-Host "[4] Config list reader"
$script:Config = [pscustomobject]@{
    prefixes_array  = @("10.", "172.16.")
    prefixes_string = "10., 172.16."
}
Assert-True ((Get-ConfigList -Name "prefixes_array" -Fallback @()).Count -eq 2) "JSON array config read back"
$joined = (Get-ConfigList -Name "prefixes_string" -Fallback @()) -join "|"
Assert-True ($joined -eq "10.|172.16.") "comma string split and trimmed"
$fallbackJoined = (Get-ConfigList -Name "missing_key" -Fallback @("fallback")) -join ""
Assert-True ($fallbackJoined -eq "fallback") "missing key falls back"
$script:Config = $null

Write-Host ""
Write-Host "[5] Ping probe works on this host"
$gateway = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1)
if ($gateway) {
    $gatewayAddress = [string]($gateway.IPv4DefaultGateway | Select-Object -First 1).NextHop
    Assert-True (Test-HostAlive $gatewayAddress) "gateway $gatewayAddress answers ping (5.1 regression guard)"
    Assert-True (-not (Test-HostAlive "192.0.2.55" 800)) "TEST-NET address does not answer"
}
else {
    Write-Host "  SKIP  no default gateway on this machine; live ping test not run"
}

Write-Host ""
Write-Host "[6] InspectOnly sends nothing"
$testHome = Join-Path $env:TEMP ("ahu-connect-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $testHome -Force | Out-Null
@{
    campus_user        = "TESTUSER"
    campus_pass        = "TESTPASS"
    portal_base        = "http://172.16.253.3:801/eportal/"
    portal_check_hosts = @("172.16.253.1")
    campus_ip_prefixes = @("10.", "172.16.", "172.21.", "172.29.")
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testHome "config.json") -Encoding UTF8

# Reload the engine against the test home, then wire tripwires into every
# network primitive: InspectOnly must not touch any of them.
. $enginePath -NoMutex -HomeDirectory $testHome
$script:InspectOnly = $true
$script:Visible     = $false
$script:NoMutex     = $true
function Invoke-PortalHttpRequest { throw "TRIPWIRE: network request attempted during InspectOnly" }
function Test-HostAlive           { throw "TRIPWIRE: ping attempted during InspectOnly" }
$inspectExit = Start-AHUCampusLogin
Assert-True ($inspectExit -eq 0 -or $inspectExit -eq 2) "InspectOnly exits 0 (campus found) or 2 (off campus), got $inspectExit"
Remove-Item -LiteralPath $testHome -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================================"
Write-Host "Passed: $passed  Failed: $failed"
if ($failed -gt 0) {
    $failures | ForEach-Object { Write-Host "  failed: $_" -ForegroundColor Red }
    exit 1
}
exit 0
