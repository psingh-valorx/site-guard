# Creates the Mac version of the team setup: Site-Guard-Setup-Mac.command, zipped so it keeps its
# "can run" permission. Run it on Windows from your local site-guard.yml, like make-team-setup.ps1.
# With -IncludeMarketo it also holds your Marketo credentials: share that version only privately.
param(
    [string]$SourceDir = [IO.Path]::Combine($HOME, '.site-guard'),
    [string]$OutDir = [IO.Path]::Combine($HOME, '.site-guard'),
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

$template = @'
#!/bin/bash
# Site Guard setup for Mac. Double-click to run. The first time, macOS may block it: see the
# instructions that came with this file.
set -u
cd "$HOME" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

TARGET="${SITE_GUARD_TARGET:-$HOME/.site-guard}"
MARKETPLACE='__MARKETPLACE__'
PLUGIN='__PLUGIN__'
CONFIG_B64='__CONFIG__'
ENV_B64='__ENV__'
PROBLEMS=0

ok()   { printf '  \033[32mOK\033[0m      %s\n' "$1"; }
todo() { printf '  \033[33mTO DO\033[0m   %s\n' "$1"; PROBLEMS=$((PROBLEMS + 1)); }

echo
echo "Setting up Site Guard. This can take a few minutes."
echo

# 1. Settings
mkdir -p "$TARGET"
[ -f "$TARGET/site-guard.yml" ] && cp "$TARGET/site-guard.yml" "$TARGET/site-guard.yml.bak"
printf '%s' "$CONFIG_B64" | base64 --decode > "$TARGET/site-guard.yml"
if [ -n "$ENV_B64" ]; then
    printf '%s' "$ENV_B64" | base64 --decode > "$TARGET/.env"
    chmod 600 "$TARGET/.env"
fi
ok "Saved the Site Guard settings"

# 2. PowerShell 7, which runs the plugin's scripts on a Mac
if ! command -v pwsh >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "  Installing PowerShell 7 with Homebrew..."
        brew install --cask powershell >/dev/null 2>&1
    fi
fi
if command -v pwsh >/dev/null 2>&1; then
    ok "PowerShell 7 is installed"
else
    todo "Install PowerShell 7: download the .pkg for your Mac from https://aka.ms/powershell-release?tag=stable , open it, then double-click this file again."
fi

# 3. Claude Code's command line, which installs the plugin
CLAUDE="$(command -v claude 2>/dev/null)"
[ -z "$CLAUDE" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE="$HOME/.local/bin/claude"
if [ -z "$CLAUDE" ]; then
    echo
    echo "  Claude Code's command line isn't installed. It's needed once, to add the plugin."
    printf '  Install it now from claude.ai? Type Y and press Return: '
    read -r ANSWER
    case "$ANSWER" in
        [Yy]*) curl -fsSL https://claude.ai/install.sh | bash ;;
    esac
    CLAUDE="$(command -v claude 2>/dev/null)"
    [ -z "$CLAUDE" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE="$HOME/.local/bin/claude"
fi

INSTALLED=""
if [ -z "$CLAUDE" ]; then
    todo "Install Claude Code from https://code.claude.com/docs , then double-click this file again."
else
    # Claude Code downloads plugins with Git. A Mac without Apple's developer tools has no working Git,
    # so download the plugin as a zip instead and add it as a local marketplace.
    if xcode-select -p >/dev/null 2>&1 || [ -x /opt/homebrew/bin/git ] || [ -x /usr/local/bin/git ]; then
        LOG="$("$CLAUDE" plugin marketplace add "$MARKETPLACE" 2>&1)"
    else
        SRC="$TARGET/plugin-source"
        TMP="$(mktemp -d)"
        if curl -fsSL "https://github.com/$MARKETPLACE/archive/refs/heads/main.zip" -o "$TMP/p.zip" && unzip -q "$TMP/p.zip" -d "$TMP/x"; then
            rm -rf "$SRC"
            mv "$TMP"/x/*/ "$SRC"
            ok "Downloaded the plugin (Git not needed)"
            LOG="$("$CLAUDE" plugin marketplace add "$SRC" 2>&1)"
        else
            LOG="Download of the plugin failed."
        fi
        rm -rf "$TMP"
    fi
    LOG="$LOG
$("$CLAUDE" plugin marketplace update valorx-tools 2>&1)"
    LOG="$LOG
$("$CLAUDE" plugin install "$PLUGIN" 2>&1)"
    LOG="$LOG
$("$CLAUDE" plugin update "$PLUGIN" 2>&1)"
    CONFIG_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    INSTALLED="$(find "$CONFIG_ROOT/plugins/cache" -path '*site-guard*' -name 'marketo-lookup.ps1' 2>/dev/null | sort | tail -n 1)"
    if [ -n "$INSTALLED" ]; then
        ok "Installed the Site Guard plugin"
    else
        todo "The plugin did not install. Send the messages below to the person who gave you this file."
        echo "$LOG"
    fi
fi

# 4. Marketo connection
if [ -n "$INSTALLED" ] && [ -n "$ENV_B64" ] && command -v pwsh >/dev/null 2>&1; then
    EMAIL="$(grep -E '^[[:space:]]*test_email:' "$TARGET/site-guard.yml" | head -n 1 | sed -E 's/^[[:space:]]*test_email:[[:space:]]*//; s/[[:space:]]*(#.*)?$//')"
    if [ -n "$EMAIL" ]; then
        RESULT="$(pwsh -NoProfile -File "$INSTALLED" -Email "$EMAIL" -AllowedEmail "$EMAIL" -EnvPath "$TARGET/.env" 2>&1)"
        if printf '%s' "$RESULT" | grep -Eq '"ok":[[:space:]]*true'; then
            ok "Connected to Marketo"
        else
            todo "Marketo did not connect. Send this to the person who gave you the file: $(printf '%s' "$RESULT" | grep -E '"error"' | head -n 1)"
        fi
    fi
fi

# 5. Browser for the PDF
if [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ] || [ -d "/Applications/Microsoft Edge.app" ]; then
    ok "Found Chrome or Edge for the PDF report"
else
    todo "Install Google Chrome, which creates the PDF report."
fi

echo
echo "In the Claude desktop app, do these once if you haven't:"
echo "  1. Settings > Connectors: turn on Claude in Chrome, and install the Chrome extension if asked"
echo "  2. Settings > Connectors: connect Webflow"
echo
if [ "$PROBLEMS" -gt 0 ]; then
    printf '\033[33mAlmost there. Do the TO DO items above, then double-click this file again.\033[0m\n'
else
    printf '\033[32mAll set. Quit the Claude app (Cmd+Q) and open it again. After you publish work to dev, type /site-guard:check in that chat.\033[0m\n'
fi
echo
read -r -p "Press Return to close this window." _
'@

$sh = $template.Replace('__CONFIG__', $configB64).Replace('__ENV__', $envB64).Replace('__MARKETPLACE__', $Marketplace).Replace('__PLUGIN__', $Plugin)
$sh = $sh -replace "`r`n", "`n"   # a Mac shell script must have Unix line endings

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$commandFile = Join-Path $OutDir 'Site-Guard-Setup-Mac.command'
[IO.File]::WriteAllText($commandFile, $sh, (New-Object System.Text.UTF8Encoding($false)))

# Zip it with Unix "can run" permission (rwxr-xr-x), marked as made on Unix so the Mac honours it.
# Otherwise double-clicking it on the Mac says it has no permission to open.
$zipFile = Join-Path $OutDir 'Site-Guard-Setup-Mac.zip'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $python) { throw 'Python is needed to build the Mac zip with the right permissions.' }
$py = @"
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
info = zipfile.ZipInfo('Site-Guard-Setup-Mac.command')
info.create_system = 3
info.external_attr = (0o100755 << 16)
info.compress_type = zipfile.ZIP_DEFLATED
with zipfile.ZipFile(dst, 'w') as z:
    z.writestr(info, open(src, 'rb').read())
"@
$pyFile = Join-Path ([IO.Path]::GetTempPath()) ("site-guard-zip-" + [guid]::NewGuid().ToString('N') + '.py')
[IO.File]::WriteAllText($pyFile, $py, (New-Object System.Text.UTF8Encoding($false)))
try { & $python.Source -I $pyFile $commandFile $zipFile } finally { Remove-Item $pyFile -ErrorAction SilentlyContinue }

[pscustomobject]@{ ok = (Test-Path $zipFile); setup_file = $commandFile; zip = $zipFile; contains_secret = [bool]$IncludeMarketo } | ConvertTo-Json
