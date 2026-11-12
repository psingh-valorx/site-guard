# Reads one page without a browser and prints its SEO, image, form and link details as JSON.
# Run it on the dev and production copy of a page, then compare the two outputs.
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$AllowedHosts,  # comma-separated
    [switch]$CheckLinks
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Done($obj) { $obj | ConvertTo-Json -Depth 6; exit 0 }

$uri = [uri]$Url
$hosts = @($AllowedHosts -split ',' | ForEach-Object { $_.Trim() })
if ($uri.Scheme -ne 'https' -or $hosts -notcontains $uri.Host) { Done ([pscustomobject]@{ ok = $false; error = "Refused: $($uri.Host) is not an allowed host." }) }

$status = 0
$html = ''
try {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5
    $status = [int]$resp.StatusCode
    $html = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
}
catch [System.Net.WebException] {
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    else { Done ([pscustomobject]@{ ok = $false; url = $Url; error = $_.Exception.Message }) }
}

$xmlValid = $false
try { [void][xml]$html; $xmlValid = $true } catch {}

function Attr($tag, $name) {
    $m = [regex]::Match($tag, "(?is)\b$name\s*=\s*(?:""([^""]*)""|'([^']*)'|([^\s>]+))")
    if (-not $m.Success) { return $null }
    foreach ($g in 1, 2, 3) { if ($m.Groups[$g].Success) { return [System.Net.WebUtility]::HtmlDecode($m.Groups[$g].Value) } }
}
function Text($s) { return ([System.Net.WebUtility]::HtmlDecode(([regex]::Replace($s, '(?s)<[^>]+>', ' '))) -replace '\s+', ' ').Trim() }

# Scripts and styles hold text that looks like tags, so drop them first, keeping JSON-LD apart.
$jsonLd = @([regex]::Matches($html, '(?is)<script\b[^>]*type\s*=\s*["'']?application/ld\+json["'']?[^>]*>(.*?)</script>') | ForEach-Object { $_.Groups[1].Value })
$formIds = @([regex]::Matches($html, 'mktoForm_(\d+)|loadForm\s*\([^)]*?,\s*(\d{2,6})\s*[,)]') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Sort-Object -Unique)
# Same code on both sites gives the same hash, so a console error on dev can be traced to production.
$scriptText = (@([regex]::Matches($html, '(?is)<script\b.*?</script>') | ForEach-Object { $_.Value }) -join "`n")
foreach ($h in $hosts) { $scriptText = $scriptText.Replace($h, 'HOST') }
$scriptText = [regex]::Replace($scriptText, '(?i)data-wf-domain="[^"]*"', '')
$sha = [Security.Cryptography.SHA256]::Create()
$scriptsHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scriptText))) -replace '-', '').ToLower()
$munchkin = [regex]::Match($html, '\b(\d{3}-[A-Z]{3}-\d{3})\b').Groups[1].Value
$body = [regex]::Replace($html, '(?is)<(script|style|noscript)\b.*?</\1>', '')

$meta = @{}
foreach ($t in [regex]::Matches($body, '(?is)<meta\b[^>]*>')) {
    $k = Attr $t.Value 'name'
    if (-not $k) { $k = Attr $t.Value 'property' }
    if ($k) { $meta[$k.ToLower()] = Attr $t.Value 'content' }
}
$canonical = $null
foreach ($t in [regex]::Matches($body, '(?is)<link\b[^>]*>')) { if ((Attr $t.Value 'rel') -eq 'canonical') { $canonical = Attr $t.Value 'href' } }
$h1 = @([regex]::Matches($body, '(?is)<h1\b[^>]*>(.*?)</h1>') | ForEach-Object { Text $_.Groups[1].Value })
$h2 = @([regex]::Matches($body, '(?is)<h2\b[^>]*>(.*?)</h2>') | ForEach-Object { Text $_.Groups[1].Value })

$schema = @()
foreach ($j in $jsonLd) {
    try { $o = $j | ConvertFrom-Json; $schema += [pscustomobject]@{ valid = $true; type = $o.'@type'; has_context = [bool]$o.'@context' } }
    catch { $schema += [pscustomobject]@{ valid = $false; type = $null; has_context = $false } }
}

$imgs = @([regex]::Matches($body, '(?is)<img\b[^>]*>') | ForEach-Object { $_.Value })
$seen = @{}
$formats = @{}
$missingAlt = 0; $missingDims = 0; $lazy = 0
foreach ($t in $imgs) {
    if ($t -notmatch '(?i)\balt\s*=') { $missingAlt++ }
    if (-not ((Attr $t 'width') -and (Attr $t 'height'))) { $missingDims++ }
    if ((Attr $t 'loading') -eq 'lazy') { $lazy++ }
    $src = Attr $t 'src'
    if (-not $src -or $seen.ContainsKey($src)) { continue }
    $seen[$src] = 1
    $ext = [IO.Path]::GetExtension(($src -split '[?#]')[0]).TrimStart('.').ToLower()
    if (-not $ext) { $ext = 'unknown' }
    if ($formats.ContainsKey($ext)) { $formats[$ext]++ } else { $formats[$ext] = 1 }
}
$toReview = @($seen.Keys | Where-Object { ($_ -split '[?#]')[0] -match '(?i)\.(png|jpe?g|gif)$' } | ForEach-Object { [uri]::UnescapeDataString(($_ -split '[?#]')[0].Split('/')[-1]) } | Select-Object -First 60)

# File size of each unique image, read from the response headers, so size checks never depend on a browser.
# This is the uploaded original. Browsers may load a smaller srcset copy, but the original is what to fix.
function ImageBytes($u) {
    foreach ($method in 'HEAD', 'GET') {
        $res = $null
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Method = $method
            $req.Timeout = 15000
            $req.UserAgent = 'Site Guard image check'
            if ($method -eq 'GET') { $req.AddRange(0, 0) }
            $res = $req.GetResponse()
            $range = $res.Headers['Content-Range']
            if ($range -match '/(\d+)\s*$') { return [long]$Matches[1] }
            if ($method -eq 'HEAD' -and $res.ContentLength -gt 0) { return [long]$res.ContentLength }
        }
        catch {}
        finally { if ($res) { $res.Close() } }
    }
    return $null
}
$imageSizes = @()
$sizesUnknown = @()
foreach ($src in @($seen.Keys | Select-Object -First 150)) {
    $abs = $null
    if (-not [uri]::TryCreate($uri, $src, [ref]$abs) -or $abs.Scheme -notmatch '^https?$') { continue }
    $name = [uri]::UnescapeDataString($abs.AbsolutePath.Split('/')[-1])
    $bytes = ImageBytes $abs.AbsoluteUri
    if ($null -eq $bytes) { $sizesUnknown += $name; continue }
    $imageSizes += [pscustomobject]@{
        file   = $name
        format = [IO.Path]::GetExtension($abs.AbsolutePath).TrimStart('.').ToLower()
        kb     = [math]::Round($bytes / 1KB)
        url    = $abs.AbsoluteUri
    }
}
$imageSizes = @($imageSizes | Sort-Object kb -Descending)

$links = @([regex]::Matches($body, '(?is)<a\b[^>]*>') | ForEach-Object { Attr $_.Value 'href' } | Where-Object { $_ -and $_ -match '^/' } | ForEach-Object { ($_ -split '[?#]')[0] } | Sort-Object -Unique)

$linksChecked = 0
$broken = @()
if ($CheckLinks) {
    $root = "$($uri.Scheme)://$($uri.Host)"
    foreach ($l in $links) {
        $linksChecked++
        $code = 0
        try {
            $req = [System.Net.HttpWebRequest]::Create($root + $l)
            $req.Method = 'GET'
            $req.Timeout = 20000
            $req.UserAgent = 'Site Guard link check'
            $res = $req.GetResponse()
            $code = [int]$res.StatusCode
            $res.Close()
        }
        catch [System.Net.WebException] {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close() }
        }
        if ($code -lt 200 -or $code -ge 400) { $broken += [pscustomobject]@{ path = $l; status = $code } }
    }
}

Done ([pscustomobject]@{
    ok               = $true
    url              = $Url
    status           = $status
    xml_valid        = $xmlValid
    title            = $(Text ([regex]::Match($body, '(?is)<title\b[^>]*>(.*?)</title>').Groups[1].Value))
    description      = $meta['description']
    robots           = $meta['robots']
    canonical        = $canonical
    h1               = $h1
    h2_count         = $h2.Count
    open_graph       = @($meta.Keys | Where-Object { $_ -like 'og:*' } | Sort-Object)
    twitter          = @($meta.Keys | Where-Object { $_ -like 'twitter:*' } | Sort-Object)
    schema           = $schema
    marketo_munchkin = $munchkin
    marketo_form_ids = $formIds
    images_total     = $imgs.Count
    images_unique    = $seen.Count
    image_formats    = $formats
    images_to_review = $toReview
    image_sizes      = $imageSizes
    image_sizes_unknown = $sizesUnknown
    missing_alt      = $missingAlt
    missing_dimensions = $missingDims
    lazy_loaded      = $lazy
    internal_links   = $links
    links_checked    = $linksChecked
    broken_links     = $broken
    scripts_hash     = $scriptsHash
    html_bytes       = $html.Length
})
