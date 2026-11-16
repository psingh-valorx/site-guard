# Regression tests for site-guard's render-report.ps1 and scripts. Prints PASS/FAIL per case.
param([string]$Plugin = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TEMP 'site-guard-tests'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory $work | Out-Null
$render = Join-Path $Plugin 'scripts\render-report.ps1'
$script:fails = 0; $script:n = 0

function Ok($name, $cond, $detail) {
    $script:n++
    if ($cond) { Write-Host "PASS  $name" } else { $script:fails++; Write-Host "FAIL  $name  -> $detail" -ForegroundColor Red }
}
function Chk($area, $name, $page, $status, $sev = 'info', $att = $null, $ev = 'Evidence.') {
    $o = [ordered]@{ area = $area; name = $name; page = $page; status = $status; severity = $sev; evidence = $ev }
    if ($att) { $o.attribution = $att }
    [pscustomobject]$o
}
# Every row a worked page needs to be fully verified.
function Full($page) { @((Chk 'image' 'Image sizes' $page 'pass'), (Chk 'image' 'PNG images' $page 'pass'), (Chk 'page' 'Console errors' $page 'pass'), (Chk 'layout' 'Layout' $page 'pass'), (Chk 'seo' 'Compared with live site' $page 'pass')) }
function Results($id, $checks, $worked = @(), $extra = @{}) {
    $r = [ordered]@{
        run_id = $id; session_id = "sess-$id"; site_name = 'Test'; dev_host = 'dev.example'
        publish = [ordered]@{ unpublished_changes = $false }
        scope = [ordered]@{ confidence = 'high'; notes = 'x'; worked_pages = @($worked) }
        checks = @($checks)
    }
    foreach ($k in $extra.Keys) { $r[$k] = $extra[$k] }
    $r
}
function Render($r, [string]$cp = '', [switch]$Raw) {
    $f = Join-Path $work "$($r.run_id).json"
    $r | ConvertTo-Json -Depth 10 | Set-Content $f -Encoding UTF8
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $render, '-ResultsFile', $f, '-OutDir', (Join-Path $work 'out'), '-NoReveal')
    if ($cp) { $a += @('-CheckpointFile', $cp) } else { $a += '-NoCheckpoint' }
    $ErrorActionPreference = 'Continue'
    $text = (& powershell @a 2>&1 | Out-String)
    $ErrorActionPreference = 'Stop'
    if ($Raw) { return $text }
    try { return ($text | ConvertFrom-Json) } catch { return [pscustomobject]@{ verdict = 'ERROR'; raw = $text } }
}
function WriteCp($path, $runs) { [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject @($runs) -Depth 6), (New-Object Text.UTF8Encoding($false))) }

Write-Host "`n== Verdicts =="
$o = Render (Results 't01' ((Full '/a')) @('/a')); Ok 'clean worked page -> PASS' ($o.verdict -eq 'PASS' -and $o.safe_to_publish -eq 'Yes') "$($o.verdict) $($o.why)"
$o = Render (Results 't02' ((Full '/a') + (Chk 'seo' 'H1 removed' '/a' 'fail' 'breaking' 'this_session')) @('/a')); Ok 'breaking this_session -> BREAKING' ($o.verdict -eq 'BREAKING' -and $o.breaking -eq 1) "$($o.verdict)"
$o = Render (Results 't03' ((Full '/a') + (Chk 'seo' 'No H1' '/a' 'fail' 'breaking' 'pre_existing')) @('/a')); Ok 'breaking pre_existing -> PASS' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
$o = Render (Results 't04' ((Full '/a') + (Chk 'seo' 'Title changed' '/a' 'fail' 'warning' 'intended')) @('/a')); Ok 'intended -> PASS' ($o.verdict -eq 'PASS') "$($o.verdict)"
$o = Render (Results 't05' ((Full '/a') + (Chk 'flow' 'Nav' '/' 'pass' 'info' $null '')) @('/a')); Ok 'pass with no evidence -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE' -and $o.not_verified -eq 1) "$($o.verdict) nv=$($o.not_verified)"
$o = Render (Results 't06' @() @()); Ok 'no checks -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$r = Results 't07' ((Full '/a')) @('/a'); $r.scope.confidence = 'low'; $o = Render $r; Ok 'low confidence -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$r = Results 't08' ((Full '/a')) @('/a'); $r.publish.unpublished_changes = $true; $o = Render $r; Ok 'unpublished changes -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$o = Render (Results 't09' @((Chk 'seo' 'X' '/a' 'maybe'))) -Raw; Ok 'unknown status is rejected' ($o -match "unknown status") ($o.Substring(0, [math]::Min(200, $o.Length)))
$o = Render (Results 't10' ((Full '/a') + (Chk 'seo' 'Title long' '/a' 'fail' 'warning' 'this_session')) @('/a')); Ok 'warning only -> PASS, counted as warning' ($o.verdict -eq 'PASS' -and $o.warnings -eq 1) "$($o.verdict) w=$($o.warnings)"

Write-Host "`n== Forms =="
$c = (Full '/a') + @([pscustomobject]@{ area = 'form'; name = 'Form 5 loads'; page = '/a'; form_id = '5'; form_renders = $false; status = 'fail'; severity = 'breaking'; attribution = 'this_session'; evidence = 'No fields.' },
    [pscustomobject]@{ area = 'form'; name = 'Form 5 compared'; page = '/a'; form_id = '5'; status = 'pass'; severity = 'info'; evidence = 'IDs match.' },
    [pscustomobject]@{ area = 'form'; name = 'Form 5 elsewhere'; page = '/b'; form_id = '5'; status = 'pass'; severity = 'info'; evidence = 'Loads.' })
$o = Render (Results 't11' $c @('/a')); Ok 'dead form fails its companion check, not other pages' ($o.verdict -eq 'BREAKING' -and $o.breaking -eq 2) "breaking=$($o.breaking)"
$c = (Full '/a') + @([pscustomobject]@{ area = 'form'; name = 'Form 6 loads'; page = '/a'; form_id = '6'; form_renders = $false; status = 'fail'; severity = 'breaking'; attribution = 'pre_existing'; evidence = 'Dead on prod too.' }, [pscustomobject]@{ area = 'form'; name = 'Form 6 compared'; page = '/a'; form_id = '6'; status = 'pass'; severity = 'info'; evidence = 'IDs match.' })
$o = Render (Results 't12' $c @('/a')); Ok 'dead form already broken on production -> PASS' ($o.verdict -eq 'PASS') "$($o.verdict)"

Write-Host "`n== Required per-page rows =="
$o = Render (Results 't13' @((Chk 'seo' 'Title' '/a' 'pass'), (Chk 'image' 'PNG images' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass')) @('/a')); Ok 'missing image size row -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$o = Render (Results 't14' @((Chk 'image' 'Image sizes' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass')) @('/a')); Ok 'missing PNG row -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$o = Render (Results 't15' @((Chk 'image' 'Image sizes' '/a' 'pass'), (Chk 'image' 'PNG images' '/a' 'pass')) @('/a')); Ok 'missing console row on worked page -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$c = @((Chk 'seo' 'Links' '/events and its 2 detail pages' 'pass'), (Chk 'seo' 'Sitemap' '/sitemap.xml' 'pass')) + (Full '/events') + (Full '/events/x') + (Full '/events/y')
$o = Render (Results 't16' $c @('/events', '/events/x', '/events/y')); Ok 'grouped page label and sitemap need no extra rows' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
$c = @((Chk 'seo' 'Links' '/events/x, /events/y' 'pass')) + (Full '/events/x') + (Full '/events/y')
$o = Render (Results 't17' $c @('/events/x', '/events/y')); Ok 'comma list of pages is matched' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
$c = (Full '/a') + @((Chk 'layout' 'Home layout' '/' 'pass'))
$o = Render (Results 't18' $c @('/a')); Ok 'a layout check on a page the session didn''t change needs no image rows' ($o.verdict -eq 'PASS') "$($o.verdict)"

Write-Host "`n== Images block =="
$c = @((Chk 'image' 'Image sizes' '/a' 'fail' 'warning' 'this_session'), (Chk 'image' 'PNG images' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass'))
$o = Render (Results 't19' $c @('/a')); Ok 'new oversized image sent as warning -> BREAKING' ($o.verdict -eq 'BREAKING') "$($o.verdict)"
$c = @((Chk 'image' 'Image sizes' '/a' 'pass'), (Chk 'image' 'PNG images' '/a' 'fail' 'info' 'this_session'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass'))
$o = Render (Results 't20' $c @('/a')); Ok 'new PNG sent as info -> BREAKING' ($o.verdict -eq 'BREAKING') "$($o.verdict)"
$c = @((Chk 'image' 'Image sizes' '/a' 'fail' 'warning' 'pre_existing'), (Chk 'image' 'PNG images' '/a' 'fail' 'warning' 'pre_existing'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass'))
$o = Render (Results 't21' $c @('/a')); Ok 'only live-site images over -> PASS' ($o.verdict -eq 'PASS') "$($o.verdict)"
$c = @((Chk 'image' 'Image sizes' '/a' 'fail' 'warning'), (Chk 'image' 'PNG images' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass'))
$o = Render (Results 't22' $c @('/a')); Ok 'failed image row with no attribution counts' ($o.verdict -eq 'BREAKING') "$($o.verdict)"

Write-Host "`n== Checkpoints and earlier issues =="
$cp = Join-Path $work 'cp1.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t23'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'Menu opens'; page = '/'; status = 'not_verified'; severity = 'warning' }) })
$o = Render (Results 't23' ((Full '/a')) @('/a')) $cp; Ok 'forgotten open issue -> not_rechecked, INCOMPLETE' ($o.verdict -eq 'INCOMPLETE' -and @($o.not_rechecked).Count -eq 1) "$($o.verdict) nr=$(@($o.not_rechecked).Count)"
$cp = Join-Path $work 'cp2.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t24'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/b'; status = 'fail'; severity = 'breaking' }) })
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/b' 'fail' 'warning' 'pre_existing'), (Chk 'image' 'PNG images' '/b' 'pass'))
$r = Results 't24' $c @('/a') @{ earlier_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/b'; status = 'still_broken' }) }
$o = Render $r $cp; Ok 'still-open issue relabelled pre_existing stays BREAKING' ($o.verdict -eq 'BREAKING') "$($o.verdict) $($o.why)"
$after = $null; foreach ($x in (Get-Content $cp -Raw | ConvertFrom-Json)) { $after = $x }
Ok '... and is carried into the new checkpoint' (@($after.open_issues | Where-Object { $_.page -eq '/b' }).Count -eq 1) "open=$(@($after.open_issues).Count)"
$cp = Join-Path $work 'cp3.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t26'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/b'; status = 'fail'; severity = 'breaking' }) })
$r = Results 't26' ((Full '/a') + (Full '/b')) @('/a') @{ earlier_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/b'; status = 'fixed' }) }
$o = Render $r $cp; Ok 'fixed earlier issue -> PASS' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
$cp = Join-Path $work 'cp-none.json'
$o = Render (Results 't27' ((Full '/a')) @('/a')) $cp; Ok 'missing checkpoint file is created' ((Test-Path $cp) -and $o.verdict -eq 'PASS') "$($o.verdict)"
$r2 = Results 't27b' ((Full '/a')) @('/a'); $r2.session_id = 'sess-t27'; $o = Render $r2 $cp; $cnt = 0; foreach ($x in (Get-Content $cp -Raw | ConvertFrom-Json)) { $cnt++ }; Ok 'a second run in the session is appended' ($cnt -eq 2) "runs=$cnt"

Write-Host "`n== Output and rendering =="
$c = (Full '/a') + @((Chk 'seo' 'Bad <script>alert(1)</script>' '/a' 'fail' 'warning' 'this_session' "Line one`nLine two & <b>bold</b>"))
$o = Render (Results 't28' $c @('/a'))
Ok 'pdf, pdf_link, pdf_path, folder_path returned' ($o.pdf -and $o.pdf_link -match '^\[Open the PDF report\]\(file:///' -and (Test-Path $o.pdf_path) -and (Test-Path $o.folder_path)) "link=$($o.pdf_link)"
$h = Get-Content $o.html -Raw
Ok 'HTML is escaped' (($h -notmatch '<script>alert') -and ($h -match '&lt;script&gt;')) 'script tag not escaped'
Ok 'newlines become line breaks' ($h -match 'Line one<br>Line two') 'no <br>'
Ok 'report opens File Explorer flag is off with -NoReveal' ($o.folder_opened -eq $false) "$($o.folder_opened)"

Write-Host "`n== Reviewer findings =="
# 1. Rerunning the report for the same run must not treat the run as its own last check.
$cp = Join-Path $work 'cp-rerun.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t40'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'X'; page = '/a'; status = 'fail'; severity = 'warning' }) })
$r = Results 't40' ((Full '/a') + (Chk 'seo' 'Title changed' '/a' 'fail' 'warning' 'needs_review')) @('/a') @{ earlier_issues = @([pscustomobject]@{ name = 'X'; page = '/a'; status = 'fixed' }) }
$o1 = Render $r $cp; $o2 = Render $r $cp
$runs = @(); foreach ($x in (Get-Content $cp -Raw | ConvertFrom-Json)) { $runs += $x }
Ok 'rerun gives the same verdict' ($o1.verdict -eq 'PASS' -and $o2.verdict -eq 'PASS') "$($o1.verdict) then $($o2.verdict) / $($o2.why)"
Ok 'rerun replaces its checkpoint entry' ($runs.Count -eq 2) "runs=$($runs.Count)"
# 2. A check that was only unverified last time keeps its pre_existing label.
$cp = Join-Path $work 'cp-nv.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t41'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/a'; status = 'not_verified'; severity = 'breaking' }) })
$c = @((Chk 'image' 'Image sizes' '/a' 'fail' 'warning' 'pre_existing'), (Chk 'image' 'PNG images' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass'))
$o = Render (Results 't41' $c @('/a') @{ earlier_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/a'; status = 'fixed' }) }) $cp
Ok 'unverified-last-time check stays pre_existing' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
# 3. still_broken / not_rechecked earlier issues missing from checks are added and carried forward.
$cp = Join-Path $work 'cp-sb.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t42'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'Hero broken'; page = '/b'; status = 'fail'; severity = 'breaking' }, [pscustomobject]@{ name = 'Menu'; page = '/'; status = 'not_verified'; severity = 'warning' }) })
$r = Results 't42' ((Full '/a')) @('/a') @{ earlier_issues = @([pscustomobject]@{ name = 'Hero broken'; page = '/b'; status = 'still_broken' }, [pscustomobject]@{ name = 'Menu'; page = '/'; status = 'not_rechecked' }) }
$o = Render $r $cp
$last = $null; foreach ($x in (Get-Content $cp -Raw | ConvertFrom-Json)) { $last = $x }
Ok 'still_broken missing from checks -> BREAKING' ($o.verdict -eq 'BREAKING') "$($o.verdict)"
Ok '... both carried into the next checkpoint' (@($last.open_issues).Count -eq 2) "open=$(@($last.open_issues).Count)"
# 5. Name matching is exact.
$c = (Full '/a') + @((Chk 'image' 'Missing alt: team.png' '/a' 'fail' 'warning' 'this_session'), (Chk 'image' 'Image size attributes missing' '/a' 'fail' 'warning' 'this_session'))
$o = Render (Results 't43' $c @('/a')); Ok 'a finding that mentions png or image size stays a warning' ($o.verdict -eq 'PASS' -and $o.warnings -eq 2) "$($o.verdict) w=$($o.warnings)"
$c = @((Chk 'image' 'Image sizes' '/a' 'pass'), (Chk 'image' 'Missing alt: team.png' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'), (Chk 'layout' 'Layout' '/a' 'pass'), (Chk 'seo' 'Compared with live site' '/a' 'pass'))
$o = Render (Results 't44' $c @('/a')); Ok 'a png-named finding does not count as the PNG check' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
# 10. Page strings.
$c = (Full '/a') + @((Chk 'layout' 'No scroll' '/a (desktop / phone)' 'pass'))
$o = Render (Results 't45' $c @('/a')); Ok '"desktop / phone" does not add the homepage' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
$o = Render (Results 't46' ((Full '/a')) @('https://dev.example/a')); Ok 'worked page given as a full URL matches' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
# 11. Attribution values.
$o = Render (Results 't47' ((Full '/a') + (Chk 'seo' 'No H1' '/a' 'fail' 'breaking' 'Pre-existing')) @('/a')); Ok '"Pre-existing" is understood' ($o.verdict -eq 'PASS') "$($o.verdict)"
$o = Render (Results 't48' ((Full '/a') + (Chk 'seo' 'No H1' '/a' 'fail' 'breaking' 'old stuff')) @('/a')) -Raw; Ok 'unknown attribution is rejected' ($o -match 'unknown attribution') ($o.Substring(0, [math]::Min(150, $o.Length)))
Write-Host "`n== Session scope =="
function WithSession($r, $pages) { $r.scope.session_pages = @($pages); $r }
# Image checks on pages the session never changed are left out.
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/' 'fail' 'warning' 'pre_existing'), (Chk 'image' 'PNG images' '/' 'fail' 'breaking' 'pre_existing'), (Chk 'page' 'Broken images' '/wave' 'fail' 'breaking' 'pre_existing'), (Chk 'image' 'Image sizes' '/wave' 'not_verified' 'info'))
$r = WithSession (Results 't50' $c @('/a')) @('/a')
$o = Render $r; $h = Get-Content $o.html -Raw
Ok 'image checks on other pages are left out' ($o.verdict -eq 'PASS' -and $h -notmatch '>/wave<' -and $h -match 'Left out 4 image check') "$($o.verdict) $($o.why)"
# ...unless they are blamed on this session.
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/' 'fail' 'breaking' 'this_session'))
$o = Render (WithSession (Results 't51' $c @('/a')) @('/a')); Ok 'an image check on another page blamed on the session stays' ($o.verdict -eq 'BREAKING') "$($o.verdict)"
# Old image issues on other pages carried from the last run don't come back.
$cp = Join-Path $work 'cp-scope.json'
WriteCp $cp @([pscustomobject]@{ session_id = 'sess-t52'; run_id = 'old'; finished_at = '2026-11-01T00:00:00Z'; open_issues = @([pscustomobject]@{ name = 'Image sizes'; page = '/'; status = 'not_verified'; severity = 'breaking' }, [pscustomobject]@{ name = 'PNG images'; page = '/wave'; status = 'fail'; severity = 'breaking' }) })
$o = Render (WithSession (Results 't52' ((Full '/a')) @('/a')) @('/a')) $cp
Ok 'carried image issues on other pages are dropped' ($o.verdict -eq 'PASS' -and @($o.not_rechecked).Count -eq 0) "$($o.verdict) $($o.why)"
# Pages changed earlier in the session still need image checks on every run.
$o = Render (WithSession (Results 't53' ((Full '/a')) @('/a')) @('/a', '/b')); Ok 'an earlier session page with no image rows -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/b' 'fail' 'warning' 'this_session'), (Chk 'image' 'PNG images' '/b' 'pass'))
$o = Render (WithSession (Results 't54' $c @('/a')) @('/a', '/b')); Ok 'an oversized session image on an earlier page -> BREAKING' ($o.verdict -eq 'BREAKING') "$($o.verdict)"
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/b' 'fail' 'warning' 'pre_existing'), (Chk 'image' 'PNG images' '/b' 'fail' 'warning' 'pre_existing'))
$o = Render (WithSession (Results 't55' $c @('/a')) @('/a', '/b')); $h = Get-Content $o.html -Raw
Ok 'older images on a session page are listed but do not block' ($o.verdict -eq 'PASS' -and $h -match '>/b<') "$($o.verdict)"
# Without session_pages (older results), the worked pages set the scope.
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/z' 'fail' 'warning' 'pre_existing'))
$o = Render (Results 't56' $c @('/a')); Ok 'older results without session_pages still work' ($o.verdict -eq 'PASS') "$($o.verdict)"
Write-Host "`n== Layout and live-site comparison =="
$base = @((Chk 'image' 'Image sizes' '/a' 'pass'), (Chk 'image' 'PNG images' '/a' 'pass'), (Chk 'page' 'Console errors' '/a' 'pass'))
$o = Render (Results 't60' ($base + (Chk 'seo' 'Compared with live site' '/a' 'pass')) @('/a')); Ok 'worked page without a layout check -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE' -and $o.not_verified -eq 1) "$($o.verdict) nv=$($o.not_verified)"
$o = Render (Results 't61' ($base + (Chk 'layout' 'Layout' '/a' 'pass')) @('/a')); Ok 'worked page without a live-site comparison -> INCOMPLETE' ($o.verdict -eq 'INCOMPLETE' -and $o.not_verified -eq 1) "$($o.verdict) nv=$($o.not_verified)"
$c = (Full '/a') + @((Chk 'image' 'Image sizes' '/b' 'pass'), (Chk 'image' 'PNG images' '/b' 'pass'))
$o = Render (WithSession (Results 't62' $c @('/a')) @('/a', '/b')); Ok 'earlier session page needs images only, not layout or comparison' ($o.verdict -eq 'PASS') "$($o.verdict) $($o.why)"
$o = Render (Results 't63' ($base + (Chk 'layout' 'Layout check at 375px' '/a' 'pass') + (Chk 'seo' 'Compared with live site' '/a' 'pass')) @('/a')); Ok 'a differently named layout row does not count' ($o.verdict -eq 'INCOMPLETE') "$($o.verdict)"
Write-Host "`n$($script:n - $script:fails) of $($script:n) passed"
