# Reads this session's saved transcript and lists its Webflow tool activity, so the change scope
# survives compaction and very large contexts. Reads line by line and prints a short JSON summary.
param(
    [string]$SessionId,
    [string]$TranscriptPath,
    [string]$ProjectDir = (Get-Location).Path,
    [string]$Since,
    [string]$CheckpointFile = (Join-Path $env:USERPROFILE '.site-guard\state\checkpoints.json')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
$json = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$json.MaxJsonLength = [int]::MaxValue

function Done($obj) { $obj | ConvertTo-Json -Depth 6; exit 0 }

$sessionCertain = $true
$recentOthers = 0
$configRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$projectsDir = Join-Path $configRoot 'projects'
if (-not $TranscriptPath -and $SessionId -match '^[0-9a-fA-F-]{36}$') {
    # The session ID names the transcript file, so find it in whichever project folder holds it.
    # This works from any session, whatever folder the session started in or the shell is in now.
    $TranscriptPath = Join-Path (Join-Path $projectsDir ($ProjectDir -replace '[^A-Za-z0-9]', '-')) "$SessionId.jsonl"
    if (-not (Test-Path $TranscriptPath)) {
        $found = @(Get-ChildItem $projectsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "$SessionId.jsonl" } | Where-Object { Test-Path $_ })
        if ($found.Count -eq 0) { Done ([pscustomobject]@{ ok = $false; error = "No saved transcript for session $SessionId under $projectsDir." }) }
        $TranscriptPath = $found[0]
    }
}
if (-not $TranscriptPath) {
    $encoded = $ProjectDir -replace '[^A-Za-z0-9]', '-'
    $dir = Join-Path $projectsDir $encoded
    if (-not (Test-Path $dir)) { Done ([pscustomobject]@{ ok = $false; error = "No transcript folder at $dir. Run from the folder where this session started." }) }
    else {
        # No session ID: assume the newest transcript, but say so if another session was active too.
        $all = @(Get-ChildItem $dir -Filter *.jsonl | Sort-Object LastWriteTime -Descending)
        if ($all.Count -eq 0) { Done ([pscustomobject]@{ ok = $false; error = "No transcripts in $dir." }) }
        $TranscriptPath = $all[0].FullName
        $recentOthers = @($all | Select-Object -Skip 1 | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) }).Count
        $sessionCertain = ($recentOthers -eq 0)
    }
}
if (-not (Test-Path $TranscriptPath)) { Done ([pscustomobject]@{ ok = $false; error = "No transcript at $TranscriptPath." }) }

# Find this session's last run, so the next run only looks at newer work.
$thisSession = [IO.Path]::GetFileNameWithoutExtension($TranscriptPath)
$previous = $null
$lastSubmission = $null
if (Test-Path $CheckpointFile) {
    foreach ($run in (Get-Content $CheckpointFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($run.session_id -eq $thisSession) { $previous = $run }
        if ($run.last_real_submission_at) { $lastSubmission = $run.last_real_submission_at }
    }
}
if (-not $Since -and $previous) { $Since = $previous.finished_at }

$sinceTime = $null
if ($Since) { $sinceTime = [datetime]::Parse($Since).ToUniversalTime() }

$idPattern = '"(pageId|page_id|collectionId|collection_id|itemId|item_id|itemIds|item_ids|componentId|component_id|scope_component_id)"\s*:\s*(\[[^\]]*\]|"[^"]+")'
$readAction = '^(list|get|query|read|search|check|describe|find|whoami|ask)'
$ids = @{ page = @{}; collection = @{}; item = @{}; component = @{} }
$writes = @{}
$publishes = New-Object System.Collections.ArrayList
$cmsPublishes = New-Object System.Collections.ArrayList
$toolCalls = 0; $lines = 0; $unparsed = 0; $compactions = 0
$first = $null; $last = $null

$reader = New-Object System.IO.StreamReader($TranscriptPath, [Text.Encoding]::UTF8)
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        $lines++
        if ($line.Contains('"compact_boundary"')) { $compactions++ }
        # Only Claude's own tool calls: tool results also mention these names and can be huge.
        if (-not $line.Contains('"type":"tool_use"') -or -not $line.Contains('"name":"mcp__claude_ai_Webflow__') -or -not $line.Contains('"type":"assistant"')) { continue }
        try { $o = $json.DeserializeObject($line) } catch { $unparsed++; continue }
        if ($o['type'] -ne 'assistant') { continue }
        $ts = $o['timestamp']
        if ($sinceTime -and $ts -and ([datetime]::Parse($ts).ToUniversalTime() -le $sinceTime)) { continue }
        foreach ($block in @($o['message']['content'])) {
            if ($block -isnot [System.Collections.IDictionary] -or $block['type'] -ne 'tool_use') { continue }
            $name = [string]$block['name']
            if (-not $name.StartsWith('mcp__claude_ai_Webflow__')) { continue }
            $toolCalls++
            if (-not $first) { $first = $ts }
            $last = $ts
            $tool = $name -replace '^mcp__claude_ai_Webflow__', ''
            $toolInput = $block['input']
            $text = $json.Serialize($toolInput)
            foreach ($m in [regex]::Matches($text, $idPattern)) {
                $kind = ($m.Groups[1].Value -replace '^scope_', '' -replace '_?[iI]ds?$', '').ToLower()
                if (-not $ids.ContainsKey($kind)) { continue }
                foreach ($v in [regex]::Matches($m.Groups[2].Value, '"([^"]+)"')) {
                    # Page, collection and item IDs are 24 hex characters. Anything else is a failed or test call.
                    if ($kind -ne 'component' -and $v.Groups[1].Value -notmatch '^[0-9a-f]{24}$') { continue }
                    $ids[$kind][$v.Groups[1].Value] = 1
                }
            }
            if ($tool -match '_builder$') {
                if ($writes.ContainsKey($tool)) { $writes[$tool]++ } else { $writes[$tool] = 1 }
            }
            $actions = @()
            if ($toolInput -is [System.Collections.IDictionary] -and $toolInput['actions']) { $actions = @($toolInput['actions']) }
            foreach ($a in $actions) {
                if ($a -isnot [System.Collections.IDictionary]) { continue }
                foreach ($k in @($a.Keys)) {
                    if ($k -eq 'label') { continue }
                    if ($k -eq 'publish_site') {
                        $p = $a[$k]
                        [void]$publishes.Add([pscustomobject]@{ at = $ts; subdomain = $p['publishToWebflowSubdomain']; custom_domains = @($p['customDomains']); page_id = $p['pageId'] })
                    }
                    if ($k -match 'publish.*item') {
                        [void]$cmsPublishes.Add([pscustomobject]@{ at = $ts; action = $k })
                    }
                    # Builder tools mix settings in with the action, so count those as one tool call.
                    if ($tool -match '_builder$') { continue }
                    if ($a[$k] -is [System.Collections.IDictionary] -and $k -notmatch $readAction) {
                        $key = "$tool/$k"
                        if ($writes.ContainsKey($key)) { $writes[$key]++ } else { $writes[$key] = 1 }
                    }
                }
            }
        }
    }
}
finally { $reader.Close() }

$limit = 200
Done ([pscustomobject]@{
    ok                  = $true
    transcript          = $TranscriptPath
    session_id          = [IO.Path]::GetFileNameWithoutExtension($TranscriptPath)
    session_certain     = $sessionCertain
    other_active_sessions = $recentOthers
    previous_run        = $previous
    changes_since       = $Since
    last_real_submission_at = $lastSubmission
    lines_read          = $lines
    unreadable_lines    = $unparsed
    compactions_found   = $compactions
    webflow_tool_calls  = $toolCalls
    first_activity      = $first
    last_activity       = $last
    change_actions      = $writes
    page_ids            = @($ids.page.Keys | Select-Object -First $limit)
    collection_ids      = @($ids.collection.Keys | Select-Object -First $limit)
    item_ids            = @($ids.item.Keys | Select-Object -First $limit)
    component_ids       = @($ids.component.Keys | Select-Object -First $limit)
    publishes           = @($publishes | Select-Object -Last 20)
    cms_item_publishes  = @($cmsPublishes | Select-Object -Last 20)
})
