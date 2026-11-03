# Creates one double-click setup file for teammates from your local site-guard.yml.
# By default it holds no secrets, so it can be shared like any file.
# With -IncludeMarketo it also holds your Marketo credentials: share that version only privately.
param(
    [string]$SourceDir = (Join-Path $env:USERPROFILE '.site-guard'),
    [string]$OutFile = (Join-Path $env:USERPROFILE '.site-guard\Site-Guard-Setup.cmd'),
    [string]$Marketplace = 'psingh-valorx/site-guard',
    [string]$Plugin = 'site-guard@valorx-tools',
    [switch]$IncludeMarketo
)

$ErrorActionPreference = 'Stop'

$configFile = Join-Path $SourceDir 'site-guard.yml'
$envFile = Join-Path $SourceDir '.env'
if (-not (Test-Path $configFile)) { throw "Missing $configFile" }
if ($IncludeMarketo -and -not (Test-Path $envFile)) { throw "Missing $envFile" }

$configB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
$envB64 = ''
if ($IncludeMarketo) { $envB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($envFile)) }

# The .cmd part opens on double-click, copies the PowerShell part below the marker to a temp file,
# runs it, and keeps the window open so the result can be read.
$launcher = @'
@echo off
setlocal
set "SG_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $t = [IO.File]::ReadAllText($env:SG_SELF); $m = '#' + 'PS' + 'START'; $s = $t.Substring($t.IndexOf($m) + $m.Length); $p = Join-Path $env:TEMP ('site-guard-setup-' + [guid]::NewGuid().ToString('N') + '.ps1'); [IO.File]::WriteAllText($p, $s); & powershell -NoProfile -ExecutionPolicy Bypass -File $p; Remove-Item $p -ErrorAction SilentlyContinue }"
echo.
pause
exit /b
#PSSTART
'@

$template = @'
# Site Guard setup. Double-click Site-Guard-Setup.cmd to run it.
param(
    [string]$TargetDir = $(if ($env:SITE_GUARD_TARGET) { $env:SITE_GUARD_TARGET } else { Join-Path $env:USERPROFILE '.site-guard' }),
    [string]$Marketplace = '__MARKETPLACE__',
    [string]$Plugin = '__PLUGIN__'
)

$ErrorActionPreference = 'Stop'
$configB64 = '__CONFIG__'
$envB64 = '__ENV__'
$problems = New-Object System.Collections.ArrayList

function Say($ok, $msg) {
    if ($ok) { Write-Host "  OK      $msg" -ForegroundColor Green }
    else { Write-Host "  TO DO   $msg" -ForegroundColor Yellow; [void]$problems.Add($msg) }
}

Write-Host "`nSetting up Site Guard. This takes about a minute.`n"

# 1. Settings
if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
$configPath = Join-Path $TargetDir 'site-guard.yml'
if (Test-Path $configPath) { Copy-Item $configPath "$configPath.bak" -Force }
[IO.File]::WriteAllBytes($configPath, [Convert]::FromBase64String($configB64))
$envPath = Join-Path $TargetDir '.env'
if ($envB64) {
    if (Test-Path $envPath) { & icacls $envPath /reset 2>&1 | Out-Null }
    [IO.File]::WriteAllBytes($envPath, [Convert]::FromBase64String($envB64))
    & icacls $envPath /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
}
Say $true 'Saved the Site Guard settings'

# 2. Claude Code's command line, which installs the plugin
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $local) { $claude = Get-Item $local }
}
if (-not $claude) {
    Write-Host "`n  Claude Code's command line isn't installed. It's needed once, to add the plugin."
    $answer = Read-Host '  Install it now from claude.ai? Type Y and press Enter'
    if ($answer -match '^[Yy]') {
        try {
            Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
            $local = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
            if (Test-Path $local) { $claude = Get-Item $local }
        } catch { Write-Host "  The install didn't finish: $($_.Exception.Message)" }
    }
}

if (-not $claude) {
    Say $false "Install Claude Code from https://code.claude.com/docs, then double-click this file again."
}
else {
    $exe = if ($claude.Source) { $claude.Source } else { $claude.FullName }
    $ErrorActionPreference = 'Continue'
    $log = (& $exe plugin marketplace add $Marketplace 2>&1 | Out-String)
    $log += (& $exe plugin marketplace update valorx-tools 2>&1 | Out-String)
    $log += (& $exe plugin install $Plugin 2>&1 | Out-String)
    $log += (& $exe plugin update $Plugin 2>&1 | Out-String)
    $ErrorActionPreference = 'Stop'
    $configRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $installed = Get-ChildItem (Join-Path $configRoot 'plugins\cache') -Recurse -Filter 'marketo-lookup.ps1' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'site-guard' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($installed) { Say $true 'Installed the Site Guard plugin' }
    else {
        Say $false 'The plugin did not install. Check your internet connection, then double-click this file again.'
        Write-Host ($log -replace '(?m)^\s*$\r?\n', '')
    }

    if ($installed -and $envB64) {
        $yml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($configB64))
        $m = [regex]::Match($yml, '(?m)^\s*test_email:\s*([^\s#]+)')
        if ($m.Success) {
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $installed.FullName -Email $m.Groups[1].Value -AllowedEmail $m.Groups[1].Value -EnvPath $envPath | ConvertFrom-Json
            if ($result.ok) { Say $true 'Connected to Marketo' } else { Say $false "Marketo did not connect: $($result.error)" }
        }
    }
}

# 3. Browser for the PDF
$browsers = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
)
if ($browsers | Where-Object { $_ -and (Test-Path $_) }) { Say $true 'Found Chrome or Edge for the PDF report' }
else { Say $false 'Install Google Chrome, which creates the PDF report.' }

Write-Host "`nIn the Claude desktop app, do these once if you haven't:"
Write-Host '  1. Settings > Customize > Connectors: turn on Claude in Chrome, and install the Chrome extension if asked'
Write-Host '  2. Settings > Customize > Connectors: connect Webflow'

if ($problems.Count -gt 0) { Write-Host "`nAlmost there. Do the TO DO items above, then double-click this file again." -ForegroundColor Yellow; exit 1 }
Write-Host "`nAll set. Restart the Claude desktop app. After you publish work to dev, type /site-guard:check in that chat." -ForegroundColor Green
'@

$ps = $template.Replace('__CONFIG__', $configB64).Replace('__ENV__', $envB64).Replace('__MARKETPLACE__', $Marketplace).Replace('__PLUGIN__', $Plugin)
$out = ($launcher + "`r`n" + $ps) -replace "(?<!`r)`n", "`r`n"
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, $out, (New-Object System.Text.UTF8Encoding($false)))

[pscustomobject]@{ ok = $true; setup_file = $OutFile; contains_secret = [bool]$IncludeMarketo } | ConvertTo-Json
