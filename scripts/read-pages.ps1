# Reads many pages at once by running read-page.ps1 for each URL side by side, and prints the
# results as one JSON array in the order given. Same output per page as read-page.ps1, just faster.
param(
    [Parameter(Mandatory = $true)][string]$Urls,          # comma-separated
    [Parameter(Mandatory = $true)][string]$AllowedHosts,  # comma-separated
    [string]$CheckLinksHost = '',                         # check internal links only on pages from this host, normally dev
    [int]$MaxParallel = 6
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'read-page.ps1'
$list = @($Urls -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(1, $MaxParallel))
$pool.Open()
$jobs = @()
foreach ($u in $list) {
    $links = $CheckLinksHost -and (([uri]$u).Host -eq $CheckLinksHost)
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript({
        param($script, $url, $hosts, $links)
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Url', $url, '-AllowedHosts', $hosts)
        if ($links) { $a += '-CheckLinks' }
        (& powershell @a) -join "`n"
    }).AddArgument($script).AddArgument($u).AddArgument($AllowedHosts).AddArgument($links)
    $jobs += [pscustomobject]@{ url = $u; ps = $ps; handle = $ps.BeginInvoke() }
}

$results = @()
foreach ($j in $jobs) {
    try {
        $text = [string]($j.ps.EndInvoke($j.handle) -join "`n")
        $results += ($text | ConvertFrom-Json)
    }
    catch { $results += [pscustomobject]@{ ok = $false; url = $j.url; error = $_.Exception.Message } }
    finally { $j.ps.Dispose() }
}
$pool.Close()

ConvertTo-Json -InputObject @($results) -Depth 8
