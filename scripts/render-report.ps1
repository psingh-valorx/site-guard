# Turns a results JSON file into a PDF report, works out the verdict, and saves the checkpoint.
# The verdict is computed here, not by Claude, so a check that did not run can never read as a pass.
param(
    [Parameter(Mandatory = $true)][string]$ResultsFile,
    [string]$OutDir = (Join-Path $env:USERPROFILE '.site-guard\reports'),
    [string]$CheckpointFile = (Join-Path $env:USERPROFILE '.site-guard\state\checkpoints.json'),
    [switch]$NoCheckpoint
)

$ErrorActionPreference = 'Stop'

function Arr($x) { if ($null -eq $x) { return @() } return @($x) }
function E($x) { if ($null -eq $x) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$x) }
function OrDash($x) { if ([string]::IsNullOrWhiteSpace([string]$x)) { return '&mdash;' } return ((E ([string]$x).Trim()) -replace "\r?\n", '<br>') }
function When($x) {
    if ([string]::IsNullOrWhiteSpace([string]$x)) { return '&mdash;' }
    try { return ([datetime]::Parse([string]$x).ToUniversalTime().ToString('d MMM yyyy, HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' UTC') }
    catch { return (E $x) }
}
function Pill($status, $text) { return "<span class=`"pill s-$(E $status)`">$(E $text)</span>" }
function ListHtml($items) {
    $items = Arr $items
    if ($items.Count -eq 0) { return '<p class="muted">None.</p>' }
    return '<ul>' + (($items | ForEach-Object { "<li>$(E $_)</li>" }) -join '') + '</ul>'
}

$r = Get-Content $ResultsFile -Raw -Encoding UTF8 | ConvertFrom-Json

# Stamp the finish time here, so the report never carries a guessed time.
$r | Add-Member -NotePropertyName finished_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force

$validStatus = 'pass', 'fail', 'not_verified', 'not_submitted', 'skipped'
$validSeverity = 'breaking', 'warning', 'info'
$checks = @(Arr $r.checks)
foreach ($c in $checks) {
    if ($validStatus -notcontains $c.status) { throw "Check '$($c.name)' has unknown status '$($c.status)'." }
    if ($c.status -eq 'fail' -and $validSeverity -notcontains $c.severity) { throw "Failed check '$($c.name)' needs a severity." }
    # A pass with no evidence is not a pass.
    if ($c.status -eq 'pass' -and [string]::IsNullOrWhiteSpace([string]$c.evidence)) {
        $c.status = 'not_verified'
        $c | Add-Member -NotePropertyName evidence -NotePropertyValue 'Downgraded by the report: reported as a pass with no evidence.' -Force
    }
}

# Every page that had its SEO, image or layout checked needs an image size check. If it's missing,
# add it as not verified, so a skipped size check can't pass unnoticed.
# A check's page can name several pages ("/events, /about") or a group ("/events and its detail pages"),
# so compare the paths inside it. Files such as /sitemap.xml aren't pages and need no image check.
function PagePaths($s) {
    return @([regex]::Matches([string]$s, '(?<![\w.])/[\w\-./]*') | ForEach-Object { $_.Value.TrimEnd('.', '/') } | ForEach-Object { if ($_ -eq '') { '/' } else { $_ } } | Where-Object { $_ -notmatch '\.[a-z0-9]{2,4}$' })
}
$pageAreas = 'seo', 'image', 'layout', 'page'
$checkedPages = @($checks | Where-Object { $pageAreas -contains $_.area -and $_.page } | ForEach-Object { PagePaths $_.page } | Sort-Object -Unique)
$sizedPages = @($checks | Where-Object { $_.name -match '(?i)image size' } | ForEach-Object { PagePaths $_.page } | Sort-Object -Unique)
foreach ($p in $checkedPages) {
    if ($sizedPages -notcontains $p) {
        $checks += [pscustomobject]@{ area = 'image'; name = 'Image sizes'; page = $p; status = 'not_verified'; severity = 'warning'; evidence = 'Added by the report: no image size check was recorded for this page.' }
    }
}
# Every worked page must also be opened in Chrome and its console read. A page skipped there,
# even if noted under limits, is added as not verified, so the run can't read as a full pass.
$consolePages = @($checks | Where-Object { $_.name -match '(?i)console' } | ForEach-Object { PagePaths $_.page } | Sort-Object -Unique)
foreach ($p in @(Arr $r.scope.worked_pages | ForEach-Object { PagePaths $_ } | Sort-Object -Unique)) {
    if ($consolePages -notcontains $p) {
        $checks += [pscustomobject]@{ area = 'page'; name = 'Console errors'; page = $p; status = 'not_verified'; severity = 'warning'; evidence = 'Added by the report: this worked page was not opened in Chrome with its console read.' }
    }
}
$r | Add-Member -NotePropertyName checks -NotePropertyValue $checks -Force

# Issues left open by this session's last run must be accounted for, so none can be forgotten.
$earlierList = New-Object System.Collections.ArrayList
foreach ($x in (Arr $r.earlier_issues)) { [void]$earlierList.Add($x) }
$sinceRun = $null
if (Test-Path $CheckpointFile) {
    foreach ($run in (Get-Content $CheckpointFile -Raw -Encoding UTF8 | ConvertFrom-Json)) { if ($r.session_id -and $run.session_id -eq $r.session_id) { $sinceRun = $run } }
}
$forgotten = 0
if ($sinceRun) {
    foreach ($o in (Arr $sinceRun.open_issues)) {
        if (@($earlierList | Where-Object { $_.name -eq $o.name -and $_.page -eq $o.page }).Count -eq 0) {
            [void]$earlierList.Add([pscustomobject]@{ name = $o.name; page = $o.page; status = 'not_rechecked' })
            $forgotten++
        }
    }
    if ($r.scope -and -not $r.scope.since_checkpoint) { $r.scope | Add-Member -NotePropertyName since_checkpoint -NotePropertyValue $sinceRun.finished_at -Force }
}
$notRechecked = @($earlierList | Where-Object { $_.status -eq 'not_rechecked' }).Count

# --- Verdict ---
# A form that didn't load on a page fails every check on that form there. Otherwise a check that
# only compares form IDs could pass while visitors see no form.
$deadForms = @{}
foreach ($c in $checks) {
    if ($c.form_id -and $c.form_renders -eq $false) { $deadForms["$($c.form_id)|$($c.page)"] = $true }
}
foreach ($c in $checks) {
    if (-not $c.form_id -or -not $deadForms.ContainsKey("$($c.form_id)|$($c.page)")) { continue }
    if ($c.form_renders -eq $false) {
        $c.status = 'fail'
        $c | Add-Member -NotePropertyName severity -NotePropertyValue 'breaking' -Force
        continue
    }
    if ($c.status -eq 'pass' -or $c.status -eq 'not_submitted') {
        $c.status = 'fail'
        $c | Add-Member -NotePropertyName severity -NotePropertyValue 'breaking' -Force
        $c | Add-Member -NotePropertyName evidence -NotePropertyValue ("$($c.evidence) Failed by the report: form $($c.form_id) did not load on this page.").Trim() -Force
    }
    if ($c.attribution -eq 'pre_existing' -or $c.attribution -eq 'intended' -or -not $c.attribution) {
        $c | Add-Member -NotePropertyName attribution -NotePropertyValue 'this_session' -Force
    }
}

# Intended changes and problems production already has do not count against this work.
$notCounted = 'intended', 'pre_existing'
$breaking = @($checks | Where-Object { $_.status -eq 'fail' -and $_.severity -eq 'breaking' -and $notCounted -notcontains $_.attribution })
$warnings = @($checks | Where-Object { $_.status -eq 'fail' -and $_.severity -ne 'breaking' -and $notCounted -notcontains $_.attribution })
$intended = @($checks | Where-Object { $_.status -eq 'fail' -and $_.attribution -eq 'intended' })
$preExisting = @($checks | Where-Object { $_.status -eq 'fail' -and $_.attribution -eq 'pre_existing' })
$unverified = @($checks | Where-Object { $_.status -eq 'not_verified' })
$passed = @($checks | Where-Object { $_.status -eq 'pass' })

$reasons = @()
if ($checks.Count -eq 0) { $reasons += 'No checks ran.' }
if ($unverified.Count -gt 0) { $reasons += "$($unverified.Count) check(s) could not be verified." }
if ($r.scope.confidence -ne 'high') { $reasons += 'The session did not clearly show what changed.' }
if ($notRechecked -gt 0) { $reasons += "$notRechecked issue(s) from the last check were not rechecked." }
if ($r.publish.unpublished_changes -eq $true) { $reasons += 'The site has unpublished edits, so dev may not show the latest work.' }

if ($breaking.Count -gt 0) {
    $verdict = 'BREAKING'; $safe = 'No'
    $why = "$($breaking.Count) breaking issue(s) found."
    if ($reasons.Count -gt 0) { $why += ' ' + ($reasons -join ' ') }
}
elseif ($reasons.Count -gt 0) {
    $verdict = 'INCOMPLETE'; $safe = 'Not fully verified'
    $why = $reasons -join ' '
}
else {
    $verdict = 'PASS'; $safe = 'Yes'
    $why = 'Every check in scope ran, and this work added no issues.'
    if ($preExisting.Count -gt 0) { $why += " $($preExisting.Count) problem(s) that production already has are listed under Other differences." }
}

# --- Content ---
$h = New-Object System.Text.StringBuilder
function Add($s) { [void]$h.Append($s) }

Add "<div class=`"brand`"><b>$(E $r.site_name)</b><span>Site Guard report</span></div>"
Add '<h1>Dev site check</h1>'
if ($r.sample -eq $true) { Add '<div class="note"><b>Sample report.</b> The results below are made up to show the layout. They are not real findings.</div>' }
Add "<p class=`"muted`">Run $(E $r.run_id) &middot; $(E $r.run_by) &middot; $(When $r.finished_at)</p>"
Add "<div class=`"verdict v-$verdict`"><div class=`"word`">$verdict</div><div class=`"why`">$(E $why)</div></div>"
Add '<div class="stats">'
Add "<div class=`"stat`"><b>$($breaking.Count)</b><span>Breaking</span></div>"
Add "<div class=`"stat`"><b>$($warnings.Count)</b><span>Warnings</span></div>"
Add "<div class=`"stat`"><b>$($unverified.Count)</b><span>Not verified</span></div>"
Add "<div class=`"stat`"><b>$($passed.Count)</b><span>Passed</span></div>"
Add '</div>'
Add '<table class="meta">'
Add "<tr><td>Safe to publish to production?</td><td><b>$(E $safe)</b></td></tr>"
Add "<tr><td>Dev last published</td><td>$(When $r.publish.dev_last_published)</td></tr>"
Add "<tr><td>Production last published</td><td>$(When $r.publish.production_last_published)</td></tr>"
Add "<tr><td>Run type</td><td>$(OrDash $r.mode)</td></tr>"
if ($r.scope.since_checkpoint) { Add "<tr><td>Changes since</td><td>$(When $r.scope.since_checkpoint)</td></tr>" }
Add '</table>'

$live = @(Arr $r.scope.live_cms_publishes)
if ($live.Count -gt 0) {
    Add "<div class=`"note`"><b>Already live on production:</b> this session published these CMS items, which skips the manual production publish: $(E ($live -join ', '))</div>"
}

Add '<h2>What changed</h2>'
Add "<p>$(E $r.scope.notes)</p>"
Add '<h3>Pages worked on</h3>'; Add (ListHtml $r.scope.worked_pages)
Add '<h3>Shared changes</h3>'; Add (ListHtml $r.scope.shared_changes)
if (@(Arr $r.scope.cms_items).Count -gt 0) { Add '<h3>CMS items</h3>'; Add (ListHtml $r.scope.cms_items) }

Add '<h2>Breaking issues</h2>'
if ($breaking.Count -eq 0) { Add '<p class="muted">None found in the checks that ran.</p>' }
foreach ($c in $breaking) {
    Add '<div class="card">'
    Add "<h3>$(E $c.name)</h3>"
    Add "<div class=`"row`"><span class=`"label`">Page:</span> $(OrDash $c.page)</div>"
    Add "<div class=`"row`"><span class=`"label`">What happened:</span> $(OrDash $c.evidence)</div>"
    Add "<div class=`"row`"><span class=`"label`">Likely cause:</span> $(OrDash $c.cause)</div>"
    Add "<div class=`"row`"><span class=`"label`">Suggested fix:</span> $(OrDash $c.fix)</div>"
    if ($c.attribution -eq 'outside_session') { Add '<div class="row"><b>Not from this session.</b></div>' }
    $shots = @(Arr $c.screenshots)
    if ($shots.Count -gt 0) {
        Add '<div class="shots">'
        foreach ($s in $shots) {
            if ($s.path -and (Test-Path $s.path) -and $s.path -match '\.png$') {
                $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($s.path))
                Add "<figure><img src=`"data:image/png;base64,$b64`" alt=`"`"><figcaption>$(E $s.label)</figcaption></figure>"
            }
        }
        Add '</div>'
    }
    Add '</div>'
}

$earlier = @($earlierList)
if ($earlier.Count -gt 0) {
    Add '<h2>Issues from your last check</h2>'
    Add '<table class="t"><thead><tr><th>Issue</th><th>Page</th><th>Now</th></tr></thead><tbody>'
    $earlierLabels = @{ fixed = 'Fixed'; still_broken = 'Still broken'; not_rechecked = 'Not rechecked' }
    $earlierClass = @{ fixed = 'pass'; still_broken = 'fail'; not_rechecked = 'not_verified' }
    foreach ($x in $earlier) {
        Add "<tr><td>$(E $x.name)</td><td>$(OrDash $x.page)</td><td>$(Pill $earlierClass[[string]$x.status] $earlierLabels[[string]$x.status])</td></tr>"
    }
    Add '</tbody></table>'
}

function CheckTable($rows) {
    $rows = @($rows | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return '<p class="muted">Nothing in scope.</p>' }
    $labels = @{ pass = 'Pass'; fail = 'Fail'; not_verified = 'Not verified'; not_submitted = 'Not submitted'; skipped = 'Skipped' }
    $out = '<table class="t"><thead><tr><th style="width:27%">Check</th><th style="width:21%">Page</th><th style="width:13%">Result</th><th>Evidence</th></tr></thead><tbody>'
    foreach ($c in $rows) {
        $cls = $c.status
        if ($c.status -eq 'fail' -and $c.severity -ne 'breaking') { $cls = 'warning' }
        $txt = $labels[[string]$c.status]
        if ($c.status -eq 'fail' -and $c.severity -eq 'warning') { $txt = 'Warning' }
        if ($c.status -eq 'fail' -and $c.severity -eq 'info') { $txt = 'Info'; $cls = 'info' }
        $evidence = OrDash $c.evidence
        if ($c.fix) { $evidence += "<br><b>Fix:</b> $(OrDash $c.fix)" }
        $out += "<tr><td>$(E $c.name)</td><td>$(OrDash $c.page)</td><td>$(Pill $cls $txt)</td><td>$evidence</td></tr>"
    }
    return $out + '</tbody></table>'
}

Add '<h2>Forms and flows</h2>'
Add (CheckTable ($checks | Where-Object { @('form', 'flow') -contains $_.area -and $notCounted -notcontains $_.attribution }))

Add '<h2>Page health and layout</h2>'
Add (CheckTable ($checks | Where-Object { @('page', 'layout') -contains $_.area -and $notCounted -notcontains $_.attribution }))

Add '<h2>SEO and images</h2>'
Add (CheckTable ($checks | Where-Object { @('seo', 'image') -contains $_.area -and $notCounted -notcontains $_.attribution }))

$outside = @($checks | Where-Object { $_.status -eq 'fail' -and $_.attribution -eq 'outside_session' })
$review = @($checks | Where-Object { $_.status -eq 'fail' -and $_.attribution -eq 'needs_review' })
Add '<h2>Other differences</h2>'
Add '<h3>Intended by this session</h3>'; Add (CheckTable $intended)
Add '<h3>Not from this session</h3>'; Add (CheckTable $outside)
Add '<h3>Needs human review</h3>'; Add (CheckTable $review)
Add '<h3>Already on production</h3>'; Add (CheckTable $preExisting)

$cleanup = @(Arr $r.cleanup)
if ($cleanup.Count -gt 0) {
    Add '<h2>Test leads and cleanup</h2>'
    Add '<table class="t"><thead><tr><th>Form</th><th>Lead</th><th>Submitted</th><th>Delete due</th><th>Marketo</th><th>Salesforce</th></tr></thead><tbody>'
    foreach ($x in $cleanup) {
        Add "<tr><td>$(OrDash $x.form)</td><td>$(OrDash $x.lead_id)</td><td>$(When $x.submitted_at)</td><td>$(When $x.delete_due_at)</td><td>$(OrDash $x.marketo_status)</td><td>$(OrDash $x.salesforce_status)</td></tr>"
    }
    Add '</tbody></table>'
}

$follow = @(Arr $r.followups)
if ($follow.Count -gt 0) { Add '<h2>To do by hand</h2>'; Add (ListHtml $follow) }

Add '<h2>Coverage</h2>'
# Repeat everything unverified at the end, so nothing that blocks a clean result is only in a table above.
Add '<h3>Could not be verified</h3>'
Add (CheckTable $unverified)
Add '<h3>Not submitted or skipped</h3>'
Add (CheckTable ($checks | Where-Object { @('not_submitted', 'skipped') -contains $_.status }))
Add '<h3>Limits of this run</h3>'; Add (ListHtml $r.limits)
Add "<p class=`"foot`">Tests ran on $(E $r.dev_host). Production was only read for comparison.</p>"

$template = Get-Content (Join-Path $PSScriptRoot '..\templates\report.html') -Raw -Encoding UTF8
$html = $template.Replace('{{TITLE}}', (E "Site Guard $($r.run_id)")).Replace('{{CONTENT}}', $h.ToString())

# --- Output ---
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$safeId = ([string]$r.run_id) -replace '[^A-Za-z0-9_-]', '-'
$htmlFile = Join-Path $OutDir "site-guard-$safeId.html"
$pdfFile = Join-Path $OutDir "site-guard-$safeId.pdf"
[IO.File]::WriteAllText($htmlFile, $html, (New-Object System.Text.UTF8Encoding($false)))
if (Test-Path $pdfFile) { Remove-Item $pdfFile -Force }

$browser = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'preflight.ps1') | ConvertFrom-Json).pdf_browser
$pdfError = $null
if (-not $browser) {
    $pdfError = 'No Chrome or Edge found.'
}
else {
    $profile_dir = Join-Path $env:TEMP ("site-guard-" + [guid]::NewGuid().ToString('N'))
    $fileUrl = ([uri]$htmlFile).AbsoluteUri
    $browserArgs = @(
        '--headless=new', '--disable-gpu', '--no-first-run',
        "--user-data-dir=`"$profile_dir`"",
        '--no-pdf-header-footer', '--print-to-pdf-no-header',
        '--virtual-time-budget=5000',
        "--print-to-pdf=`"$pdfFile`"",
        "`"$fileUrl`""
    )
    $p = Start-Process -FilePath $browser -ArgumentList $browserArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and -not ((Test-Path $pdfFile) -and $p.HasExited)) { Start-Sleep -Milliseconds 500 }
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Milliseconds 500
    try { Remove-Item $profile_dir -Recurse -Force -ErrorAction Stop } catch {}
    if (-not (Test-Path $pdfFile)) { $pdfError = 'The browser did not produce a PDF within 90 seconds. The HTML report is still available.' }
}

if (-not $NoCheckpoint) {
    $dir = Split-Path -Parent $CheckpointFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $runs = @()
    # PowerShell 5.1 passes a JSON array down the pipeline as one object, so unroll it.
    if (Test-Path $CheckpointFile) { foreach ($saved in (Get-Content $CheckpointFile -Raw -Encoding UTF8 | ConvertFrom-Json)) { $runs += $saved } }
    $open = @(($breaking + $warnings + $unverified) | ForEach-Object { [pscustomobject]@{ name = $_.name; page = $_.page; status = $_.status; severity = $_.severity } })
    $runs += [pscustomobject]@{
        run_id         = $r.run_id
        session_id     = $r.session_id
        finished_at    = $r.finished_at
        verdict        = $verdict
        worked_pages   = @(Arr $r.scope.worked_pages)
        shared_changes = @(Arr $r.scope.shared_changes)
        open_issues    = $open
        last_real_submission_at = $r.last_real_submission_at
        report         = $pdfFile
    }
    if ($runs.Count -gt 50) { $runs = $runs[($runs.Count - 50)..($runs.Count - 1)] }
    [IO.File]::WriteAllText($CheckpointFile, (ConvertTo-Json -InputObject @($runs) -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

[pscustomobject]@{
    verdict = $verdict
    safe_to_publish = $safe
    why = $why
    breaking = $breaking.Count
    warnings = $warnings.Count
    not_verified = $unverified.Count
    passed = $passed.Count
    not_rechecked = @($earlierList | Where-Object { $_.status -eq 'not_rechecked' } | ForEach-Object { [pscustomobject]@{ name = $_.name; page = $_.page } })
    pdf = $(if ($pdfError) { $null } else { $pdfFile })
    html = $htmlFile
    pdf_error = $pdfError
    # Ready-made Markdown links, so the chat can show the report as something to click.
    pdf_link = $(if ($pdfError -or -not (Test-Path $pdfFile)) { $null } else { "[Open the PDF report]($(([uri](Get-Item $pdfFile).FullName).AbsoluteUri))" })
    html_link = $(if (Test-Path $htmlFile) { "[Open the report in a browser]($(([uri](Get-Item $htmlFile).FullName).AbsoluteUri))" } else { $null })
} | ConvertTo-Json
