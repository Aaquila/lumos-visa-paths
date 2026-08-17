<#
.SYNOPSIS
  Runs the Lumos Flutter web app with the Google OAuth client ID wired in.

.DESCRIPTION
  Reads the client ID from the root .env file (GOOGLE_AUTH_CLIENT_ID), then launches:

    flutter run -d chrome --web-port 7357 --dart-define=GOOGLE_CLIENT_ID=<id>

  Port 7357 is fixed on purpose: it must match the Authorized JavaScript origin
  (http://localhost:7357) registered on the OAuth client in Google Cloud.

.EXAMPLE
  .\scripts\run_web.ps1
  .\scripts\run_web.ps1 -Port 7357 --release
#>
[CmdletBinding()]
param(
    [int]$Port,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

# One clear line, no PowerShell stack trace.
function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = Split-Path -Parent $ScriptDir
$FrontendDir = Join-Path $RepoRoot 'frontend'
$EnvFile     = Join-Path $RepoRoot '.env'

if (-not (Test-Path $EnvFile)) {
    Fail "Missing .env file at '$EnvFile'. Create it with GOOGLE_AUTH_CLIENT_ID=<your-client-id> (see docs/RUNNING.md)."
}

# Parse .env for GOOGLE_AUTH_CLIENT_ID and FRONTEND_PORT.
$ClientId = ''
$ClientIdLine = 0
$ParsedPort = 0
$LineNo = 0
foreach ($raw in (Get-Content -LiteralPath $EnvFile)) {
    $LineNo++
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }

    if ($line -like 'GOOGLE_AUTH_CLIENT_ID=*' -and -not $ClientId) {
        $ClientId = $line.Substring('GOOGLE_AUTH_CLIENT_ID='.Length).Trim('"', '''')
        $ClientIdLine = $LineNo
    }
    if ($line -like 'FRONTEND_PORT=*' -and $ParsedPort -eq 0 -and -not $Port) {
        $portStr = $line.Substring('FRONTEND_PORT='.Length).Trim('"', '''')
        if ([int]::TryParse($portStr, [ref]$ParsedPort)) { }
    }
}

$FinalPort = if ($Port -ne 0) { $Port } elseif ($ParsedPort -ne 0) { $ParsedPort } else { 7357 }
$FoundLine = $ClientIdLine

if ($ClientId -eq '') {
    Fail "GOOGLE_AUTH_CLIENT_ID not found in '$EnvFile'. Add the line: GOOGLE_AUTH_CLIENT_ID=<your-client-id> (see docs/RUNNING.md)."
}
if ($ClientId -like "*YOUR_CLIENT_ID_HERE*" -or $ClientId -like "*PLACEHOLDER*") {
    Fail "Client ID is still a placeholder. Edit '$EnvFile' line $FoundLine and replace the value with your real Google OAuth Web client ID (see docs/RUNNING.md)."
}
if ($ClientId -notlike '*.apps.googleusercontent.com') {
    Fail "'$ClientId' (from '$EnvFile' line $FoundLine) does not look like a Google client ID; it must end in '.apps.googleusercontent.com'."
}

if (-not (Test-Path $FrontendDir)) {
    Fail "Could not find the Flutter app at '$FrontendDir'."
}

Write-Host "Client ID : $ClientId"
Write-Host "Port      : $FinalPort"
Write-Host "Origin    : http://localhost:$FinalPort  (must match the OAuth client's Authorized JavaScript origin)"
Write-Host ''

$FlutterArgs = @(
    'run', '-d', 'chrome',
    '--web-port', "$FinalPort",
    '--web-hostname', 'localhost',
    "--dart-define=GOOGLE_CLIENT_ID=$ClientId"
)
if ($ExtraArgs) { $FlutterArgs += $ExtraArgs }

Push-Location $FrontendDir
try {
    & flutter @FlutterArgs
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $code
