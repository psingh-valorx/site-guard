# Saves a screenshot of a configured dev or production page for the report, using the installed browser
# in a throwaway profile, so no sign-ins are involved. Prints JSON.
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$Width = 1366,
    [int]$Height = 900,
    [Parameter(Mandatory = $true)][string]$AllowedHosts   # comma-separated
)

$ErrorActionPreference = 'Stop'

function Done($ok, $msg) { [pscustomobject]@{ ok = $ok; message = $msg; path = $OutFile } | ConvertTo-Json; exit 0 }

$uri = [uri]$Url
$hosts = @($AllowedHosts -split ',' | ForEach-Object { $_.Trim() })
if ($uri.Scheme -ne 'https' -or $hosts -notcontains $uri.Host) { Done $false "Refused: $($uri.Host) is not an allowed host." }

$browser = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'preflight.ps1') | ConvertFrom-Json).pdf_browser
if (-not $browser) { Done $false 'No Chrome or Edge found.' }

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

$profile_dir = Join-Path $env:TEMP ("site-guard-" + [guid]::NewGuid().ToString('N'))
$browserArgs = @(
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
    "--user-data-dir=`"$profile_dir`"",
    "--window-size=$Width,$Height",
    '--virtual-time-budget=8000',
    "--screenshot=`"$OutFile`"",
    "`"$Url`""
)
$p = Start-Process -FilePath $browser -ArgumentList $browserArgs -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline -and -not ((Test-Path $OutFile) -and $p.HasExited)) { Start-Sleep -Milliseconds 500 }
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Milliseconds 500
try { Remove-Item $profile_dir -Recurse -Force -ErrorAction Stop } catch {}

if (Test-Path $OutFile) { Done $true 'Saved.' } else { Done $false 'The browser did not produce a screenshot within 60 seconds.' }
