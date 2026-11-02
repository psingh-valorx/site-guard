# Reports what this laptop has available. Prints JSON. Never prints secret values.
param(
    [string]$EnvPath = (Join-Path $env:USERPROFILE '.site-guard\.env'),
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.site-guard\site-guard.yml')
)

$ErrorActionPreference = 'Stop'

function Find-Browser {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$home_dir = Join-Path $env:USERPROFILE '.site-guard'
foreach ($d in @($home_dir, (Join-Path $home_dir 'reports'), (Join-Path $home_dir 'state'), (Join-Path $home_dir 'runs'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$names = @()
if (Test-Path $EnvPath) {
    $names = @(Get-Content $EnvPath | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*=.+' } | ForEach-Object { ($_ -split '=', 2)[0].Trim() })
}
$required = @('MARKETO_BASE_URL', 'MARKETO_CLIENT_ID', 'MARKETO_CLIENT_SECRET')
$missing = @($required | Where-Object { $names -notcontains $_ })

$browser = Find-Browser
[pscustomobject]@{
    config_path       = $ConfigPath
    config_found      = [bool](Test-Path $ConfigPath)
    pdf_browser       = $browser
    pdf_available     = [bool]$browser
    env_path          = $EnvPath
    env_found         = [bool](Test-Path $EnvPath)
    env_missing       = $missing
    marketo_available = ((Test-Path $EnvPath) -and $missing.Count -eq 0)
    env_in_onedrive   = ($EnvPath -match 'OneDrive')
    data_dir          = $home_dir
    run_dir           = (Join-Path $home_dir 'runs')
    reports_dir       = (Join-Path $home_dir 'reports')
    checkpoints_file  = (Join-Path $home_dir 'state\checkpoints.json')
} | ConvertTo-Json
