# Windows PowerShell equivalent of scripts/check-local-ui.sh
# Produces local-ui-check.txt in the project root.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/check-local-ui.ps1 [-Open]

param(
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ReportFile = Join-Path $RootDir 'local-ui-check.txt'
$UiUrl = 'http://127.0.0.1:14242/ui/'

$lines = New-Object System.Collections.Generic.List[string]
function Add-Line([string]$t) { $script:lines.Add($t) | Out-Null }

$nowLocal = Get-Date
$offset = [TimeZoneInfo]::Local.GetUtcOffset($nowLocal)
$sign = if ($offset.TotalHours -ge 0) { '+' } else { '-' }
$oh = [int][math]::Abs([math]::Truncate($offset.TotalHours))
$om = [int][math]::Abs($offset.Minutes)
$localIso = $nowLocal.ToString('yyyy-MM-ddTHH:mm:ss') + ('{0}{1:00}:{2:00}' -f $sign, $oh, $om)
$utcIso = $nowLocal.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$os = Get-CimInstance Win32_OperatingSystem

Add-Line 'AI Learning Assistant Local Web Interface Check'
Add-Line "Time (local): $localIso"
Add-Line "Time (UTC): $utcIso"
Add-Line "Machine: $($env:COMPUTERNAME)"
Add-Line "Operating system: Windows $($os.Version) ($($os.Caption.Trim()))"
Add-Line "CPU architecture: $($env:PROCESSOR_ARCHITECTURE)"
Add-Line "Working directory: $RootDir"
Add-Line "Report file: $ReportFile"
Add-Line "Tested URL: $UiUrl"
Add-Line 'Execution location: terminal on the machine named above'
Add-Line "Target: this machine's loopback port 14242 (possibly forwarded by an SSH tunnel)"
Add-Line 'Browser verification: HTTP checks do not prove that the page rendered in a browser'
Add-Line ''

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curl) {
    Add-Line 'Result: FAIL - curl.exe is not installed.'
    $lines | Set-Content -Path $ReportFile -Encoding utf8
    exit 1
}

$statusLine = & curl.exe --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 15 --output NUL --write-out '%{http_code}' $UiUrl 2>&1
$curlExit = $LASTEXITCODE
$httpStatus = ($statusLine | Out-String).Trim()

Add-Line "HTTP status: $httpStatus"
Add-Line "curl exit code: $curlExit"

if ($curlExit -ne 0 -or $httpStatus -ne '200') {
    Add-Line 'Browser launch: not attempted'
    Add-Line 'Result: FAIL - expected a successful HTTP 200 response.'
    Add-Line 'Check: docker compose -p ai-learning-assistant logs --tail=100 backend'
    $lines | Set-Content -Path $ReportFile -Encoding utf8
    exit 1
}

Add-Line 'Result: PASS - the web-interface URL returned HTTP 200.'
if (-not $Open) {
    Add-Line "Browser launch: not requested; open $UiUrl manually on this machine."
    $lines | Set-Content -Path $ReportFile -Encoding utf8
    exit 0
}

Start-Process $UiUrl
Add-Line 'Browser launch location: default browser in this machine''s desktop session'
Add-Line 'Browser launch command: Start-Process '"$UiUrl"
Add-Line 'Browser launch: request accepted; actual browser rendering remains unverified.'

$lines | Set-Content -Path $ReportFile -Encoding utf8
$lines | ForEach-Object { Write-Output $_ }
