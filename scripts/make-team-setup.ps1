# Creates one private setup file for teammates from your local site-guard.yml and .env.
# The output contains your Marketo secret. Share it only through a password manager, and never commit it.
param(
    [string]$SourceDir = (Join-Path $env:USERPROFILE '.site-guard'),
    [string]$OutFile = (Join-Path $env:USERPROFILE '.site-guard\site-guard-team-setup.ps1'),
    [string]$Marketplace = 'psingh-valorx/site-guard',
    [string]$Plugin = 'site-guard@valorx-tools'
)

$ErrorActionPreference = 'Stop'

$configFile = Join-Path $SourceDir 'site-guard.yml'
$envFile = Join-Path $SourceDir '.env'
foreach ($f in $configFile, $envFile) { if (-not (Test-Path $f)) { throw "Missing $f" } }

$configB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configFile))
$envB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($envFile))

$template = @'
# Site Guard team setup. PRIVATE: this file contains credentials.
# Run it once: powershell -ExecutionPolicy Bypass -File .\site-guard-team-setup.ps1
# Then delete it. Never email it, post it in chat, or commit it.
param(
    [string]$TargetDir = (Join-Path $env:USERPROFILE '.site-guard'),
    [string]$Marketplace = '__MARKETPLACE__',
    [string]$Plugin = '__PLUGIN__'
)

$ErrorActionPreference = 'Stop'
$configB64 = '__CONFIG__'
$envB64 = '__ENV__'
$problems = New-Object System.Collections.ArrayList

function Say($ok, $msg) {
    if ($ok) { Write-Host "  OK      $msg" -ForegroundColor Green }
    else { Write-Host "  ACTION  $msg" -ForegroundColor Yellow; [void]$problems.Add($msg) }
}

Write-Host "`nSetting up Site Guard`n"

# 1. Private files
if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
foreach ($item in @(@('site-guard.yml', $configB64), @('.env', $envB64))) {
    $path = Join-Path $TargetDir $item[0]
    # Keep the old settings, but never a second copy of the secret.
    if ($item[0] -ne '.env' -and (Test-Path $path)) { Copy-Item $path "$path.bak" -Force }
    if (Test-Path $path) { & icacls $path /reset 2>&1 | Out-Null }
    [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($item[1]))
}
# Only this Windows user can read the secret.
$envPath = Join-Path $TargetDir '.env'
& icacls $envPath /inheritance:r /grant:r "$($env:USERNAME):F" 2>&1 | Out-Null
Say $true "Saved your settings in $TargetDir"
if ($TargetDir -match 'OneDrive') { Say $false 'Your settings folder is in OneDrive. Move it out, so the secret does not sync to the cloud.' }

# 2. Plugin
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    Say $false 'Install Claude Code from https://code.claude.com/docs, then run this file again.'
}
else {
    $ErrorActionPreference = 'Continue'
    $add = (& claude plugin marketplace add $Marketplace 2>&1 | Out-String)
    $install = (& claude plugin install $Plugin 2>&1 | Out-String)
    $update = (& claude plugin update $Plugin 2>&1 | Out-String)
    $ErrorActionPreference = 'Stop'
    $configRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $installed = Get-ChildItem (Join-Path $configRoot 'plugins\cache') -Recurse -Filter 'marketo-lookup.ps1' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'site-guard' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($installed) { Say $true 'Installed the plugin' }
    else {
        Say $false 'The plugin did not install. Check that you can reach GitHub, then run this file again.'
        Write-Host (($add + $install + $update) -replace '(?m)^\s*$\r?\n', '')
    }

    # 3. Marketo connection, read-only
    if ($installed) {
        $yml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($configB64))
        $m = [regex]::Match($yml, '(?m)^\s*test_email:\s*([^\s#]+)')
        if ($m.Success) {
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $installed.FullName -Email $m.Groups[1].Value -AllowedEmail $m.Groups[1].Value -EnvPath $envPath | ConvertFrom-Json
            if ($result.ok) { Say $true 'Connected to Marketo' } else { Say $false "Marketo did not connect: $($result.error)" }
        }
    }
}

# 4. Browser for the PDF
$browsers = @(
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
)
if ($browsers | Where-Object { $_ -and (Test-Path $_) }) { Say $true 'Found Chrome or Edge for the PDF' }
else { Say $false 'Install Chrome or Edge, which creates the PDF.' }

Write-Host "`nDo these once if you haven't:"
Write-Host '  - Install the Claude in Chrome extension and connect it. In a terminal, start Claude Code with: claude --chrome'
Write-Host '  - Connect the Webflow connector in Claude'

if ($problems.Count -gt 0) { Write-Host "`nNot finished. Fix the ACTION items above, then run this file again.`n" -ForegroundColor Yellow; exit 1 }
Write-Host "`nDone. Delete this file, start a new Claude Code session, and run /site-guard:check after your next dev publish.`n" -ForegroundColor Green
'@

$out = $template.Replace('__CONFIG__', $configB64).Replace('__ENV__', $envB64).Replace('__MARKETPLACE__', $Marketplace).Replace('__PLUGIN__', $Plugin)
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, $out, (New-Object System.Text.UTF8Encoding($false)))

[pscustomobject]@{ ok = $true; setup_file = $OutFile; contains_secret = $true; share_with = 'password manager only' } | ConvertTo-Json
