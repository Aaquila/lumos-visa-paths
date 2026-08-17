<#
.SYNOPSIS
  Runs the Lumos backend API server with configuration from .env.

.DESCRIPTION
  Reads BACKEND_HOST and BACKEND_PORT from the root .env file, then launches:

    uvicorn app.main:app --reload --host <host> --port <port>

.EXAMPLE
  .\scripts\run_backend.ps1
  .\scripts\run_backend.ps1 --port 9000
  .\scripts\run_backend.ps1 --bindhost 0.0.0.0
#>
[CmdletBinding()]
param(
    [int]$Port,
    [string]$BindHost,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = Split-Path -Parent $ScriptDir
$BackendDir  = Join-Path $RepoRoot 'backend'
$EnvFile     = Join-Path $RepoRoot '.env'

if (-not (Test-Path $EnvFile)) {
    Fail "Missing .env file at '$EnvFile'. See docs/RUNNING.md."
}

# Parse .env for BACKEND_HOST and BACKEND_PORT if not overridden.
$ParsedHost = ''
$ParsedPort = 0

@(Get-Content -LiteralPath $EnvFile) | ForEach-Object {
    $line = $_.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }

    if ($line -like 'BACKEND_HOST=*' -and -not $BindHost) {
        $ParsedHost = $line.Substring('BACKEND_HOST='.Length).Trim('"', '''').Trim()
    }
    elseif ($line -like 'BACKEND_PORT=*' -and -not $Port) {
        $portStr = $line.Substring('BACKEND_PORT='.Length).Trim('"', '''').Trim()
        $tmp = 0
        if ([int]::TryParse($portStr, [ref]$tmp)) {
            $ParsedPort = $tmp
        }
    }
}

if (-not $BindHost -and -not $ParsedHost) {
    Fail "BACKEND_HOST not found in '$EnvFile'. Add the line: BACKEND_HOST=<host> (see docs/RUNNING.md)."
}
if ($Port -le 0 -and $ParsedPort -eq 0) {
    Fail "BACKEND_PORT not found in '$EnvFile'. Add the line: BACKEND_PORT=<port> (see docs/RUNNING.md)."
}

$FinalHost = if ($BindHost) { $BindHost } else { $ParsedHost }
$FinalPort = if ($Port -gt 0) { $Port } else { $ParsedPort }

Write-Host "Backend   : $FinalHost`:$FinalPort"
Write-Host ''

$UvicornArgs = @(
    'app.main:app',
    '--reload',
    '--host', $FinalHost,
    '--port', "$FinalPort"
)
if ($ExtraArgs) { $UvicornArgs += $ExtraArgs }

Push-Location $BackendDir
try {
    & uvicorn @UvicornArgs
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $code
