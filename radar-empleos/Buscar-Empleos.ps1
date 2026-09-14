<#
.SYNOPSIS
    Radar de empleos: busca ofertas de Data Analyst / BI Developer en varias fuentes,
    las puntua contra el perfil del CV y genera un reporte HTML + CSV.

.DESCRIPTION
    Fuentes: LinkedIn (endpoint publico de invitado), Computrabajo Argentina, Indeed,
    Remotive, Jobicy, Himalayas, RemoteOK y Arbeitnow.
    No requiere instalar nada: PowerShell 5.1 nativo de Windows.

.EXAMPLE
    .\Buscar-Empleos.ps1
    .\Buscar-Empleos.ps1 -SinDetalle          # mas rapido, no baja descripciones
    .\Buscar-Empleos.ps1 -PuntajeMinimo 40    # solo matches fuertes
#>

[CmdletBinding()]
param(
    [string] $RutaPerfil,
    [int]    $PuntajeMinimo = -1,
    [switch] $SinDetalle,
    [switch] $NoAbrir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Raiz        = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RutaPerfil) { $RutaPerfil = Join-Path $Raiz 'perfil.json' }
$DirDatos    = Join-Path $Raiz 'datos'
$DirReportes = Join-Path $Raiz 'reportes'
foreach ($d in @($DirDatos, $DirReportes)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'

# ---------------------------------------------------------------- utilidades

function Read-Utf8Json([string]$Path) {
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $txt | ConvertFrom-Json
}

function Write-Utf8([string]$Path, [string]$Content) {
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Log([string]$Msg, [string]$Nivel = 'info') {
    $c = 'Gray'
    if ($Nivel -eq 'ok')   { $c = 'Green' }
    if ($Nivel -eq 'warn') { $c = 'Yellow' }
    if ($Nivel -eq 'err')  { $c = 'Red' }
    if ($Nivel -eq 'head') { $c = 'Cyan' }
    Write-Host $Msg -ForegroundColor $c
}

function Get-Web([string]$Url, [hashtable]$Headers, [int]$TimeoutSec = 30) {
    $h = @{ 'User-Agent' = $UA; 'Accept-Language' = 'es-AR,es;q=0.9,en;q=0.8' }
    if ($Headers) { $Headers.GetEnumerator() | ForEach-Object { $h[$_.Key] = $_.Value } }
    return (Invoke-WebRequest -Uri $Url -Headers $h -TimeoutSec $TimeoutSec -UseBasicParsing).Content
}

function Get-Json([string]$Url, [int]$TimeoutSec = 45) {
    $h = @{ 'User-Agent' = $UA; 'Accept' = 'application/json' }
    return Invoke-RestMethod -Uri $Url -Headers $h -TimeoutSec $TimeoutSec
}

function Clean-Html([string]$s) {
    if (-not $s) { return '' }
    $s = $s -replace '(?s)<script.*?</script>', ' '
    $s = $s -replace '(?s)<style.*?</style>', ' '
    $s = $s -replace '<[^>]+>', ' '
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

function Norm([string]$s) {
    if (-not $s) { return '' }
    $s = $s.ToLowerInvariant()
    $s = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return ($sb.ToString() -replace '\s+', ' ').Trim()
}

function New-Oferta($Fuente, $Id, $Titulo, $Empresa, $Ubicacion, $Url, $Descripcion, $Fecha, $Modalidad) {
    [PSCustomObject]@{
        Fuente      = $Fuente
        IdFuente    = "$Fuente::$Id"
        Titulo      = (Clean-Html $Titulo)
        Empresa     = (Clean-Html $Empresa)
        Ubicacion   = (Clean-Html $Ubicacion)
        Url         = $Url
        Descripcion = (Clean-Html $Descripcion)
        Fecha       = $Fecha
        Modalidad   = $Modalidad
        Puntaje     = 0
        Motivos     = @()
        Alertas     = @()
        Nuevo       = $false
    }
}

# ------------------------------------------------------------------ fuentes

function Get-LinkedIn($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    $tpr = ''
    if ($cfg.ultimosDias -gt 0) { $tpr = '&f_TPR=r' + ($cfg.ultimosDias * 86400) }
    foreach ($kw in $cfg.keywords) {
        foreach ($loc in $cfg.ubicaciones) {
            for ($p = 0; $p -lt $cfg.paginas; $p++) {
                $start = $p * 25
                $url = 'https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords=' +
                       [uri]::EscapeDataString($kw) + '&location=' + [uri]::EscapeDataString($loc) +
                       "&start=$start" + $tpr
                try {
                    $html = Get-Web $url
                } catch {
                    Log "    LinkedIn '$kw' p$p -> $($_.Exception.Message)" 'warn'; continue
                }
                $cards = [regex]::Matches($html, '(?s)<li>.*?</li>')
                if ($cards.Count -eq 0) { break }
                foreach ($c in $cards) {
                    $t = $c.Value
                    $mId  = [regex]::Match($t, 'urn:li:jobPosting:(\d+)')
                    $mTit = [regex]::Match($t, '(?s)base-search-card__title">\s*(.*?)\s*</h3>')
                    $mEmp = [regex]::Match($t, '(?s)base-search-card__subtitle">.*?<a[^>]*>\s*(.*?)\s*</a>')
                    $mLoc = [regex]::Match($t, '(?s)job-search-card__location">\s*(.*?)\s*</span>')
                    $mUrl = [regex]::Match($t, 'base-card__full-link[^"]*"[^>]*href="([^"]+)"')
                    $mFec = [regex]::Match($t, 'datetime="([^"]+)"')
                    if (-not $mTit.Success -or -not $mUrl.Success) { continue }
                    $fecha = $null
                    if ($mFec.Success) { try { $fecha = [datetime]$mFec.Groups[1].Value } catch {} }
                    $limpia = ([System.Net.WebUtility]::HtmlDecode($mUrl.Groups[1].Value) -split '\?')[0]
                    $idv = $limpia
                    if ($mId.Success) { $idv = $mId.Groups[1].Value }
                    $out += New-Oferta 'LinkedIn' $idv $mTit.Groups[1].Value $mEmp.Groups[1].Value `
                                       $mLoc.Groups[1].Value $limpia '' $fecha ''
                }
                Start-Sleep -Milliseconds 700
            }
        }
    }
    return $out
}

function Get-Computrabajo($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    foreach ($slug in $cfg.slugs) {
        for ($p = 1; $p -le $cfg.paginas; $p++) {
            $url = "https://ar.computrabajo.com/trabajo-de-$slug"
            if ($p -gt 1) { $url += "?p=$p" }
            try {
                $html = Get-Web $url
            } catch {
                Log "    Computrabajo '$slug' p$p -> $($_.Exception.Message)" 'warn'; continue
            }
            $bloques = [regex]::Matches($html, '(?s)<article[^>]*class="box_offer.*?</article>')
            if ($bloques.Count -eq 0) { break }
            foreach ($b in $bloques) {
                $t = $b.Value
                $mId  = [regex]::Match($t, "data-id='([^']+)'")
                $mTit = [regex]::Match($t, '(?s)<h2[^>]*>\s*<a class="js-o-link fc_base" href="([^"]+)">\s*(.*?)\s*</a>')
                $mEmp = [regex]::Match($t, '(?s)<a class="fc_base t_ellipsis"[^>]*>\s*(.*?)\s*</a>')
                $mLoc = [regex]::Match($t, '(?s)<p class="fs16 fc_base mt5">\s*<span class="mr10">\s*(.*?)\s*</span>')
                $mMod = [regex]::Match($t, '(?s)i_home"></span>\s*(.*?)\s*</span>')
                $mFec = [regex]::Match($t, '(?s)<p class="fs13 fc_aux mt15">\s*(.*?)\s*</p>')
                if (-not $mTit.Success) { continue }
                $href = 'https://ar.computrabajo.com' + (($mTit.Groups[1].Value -split '#')[0])
                $idv = $href
                if ($mId.Success) { $idv = $mId.Groups[1].Value }
                $emp = ''
                if ($mEmp.Success) { $emp = $mEmp.Groups[1].Value }
                $mod = ''
                if ($mMod.Success) { $mod = Clean-Html $mMod.Groups[1].Value }
                $o = New-Oferta 'Computrabajo' $idv $mTit.Groups[2].Value $emp `
                                $mLoc.Groups[1].Value $href '' $null $mod
                if ($mFec.Success) { $o | Add-Member -NotePropertyName FechaTexto -NotePropertyValue (Clean-Html $mFec.Groups[1].Value) }
                $out += $o
            }
            Start-Sleep -Milliseconds 900
        }
    }
    return $out
}

function Get-Remotive($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    foreach ($kw in $cfg.keywords) {
        try {
            $d = Get-Json ('https://remotive.com/api/remote-jobs?search=' + [uri]::EscapeDataString($kw))
        } catch { Log "    Remotive '$kw' -> $($_.Exception.Message)" 'warn'; continue }
        foreach ($j in $d.jobs) {
            $f = $null; try { $f = [datetime]$j.publication_date } catch {}
            $out += New-Oferta 'Remotive' $j.id $j.title $j.company_name $j.candidate_required_location `
                               $j.url $j.description $f 'Remoto'
        }
        Start-Sleep -Milliseconds 400
    }
    return $out
}

function Get-Jobicy($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    foreach ($tag in $cfg.tags) {
        try {
            $d = Get-Json ('https://jobicy.com/api/v2/remote-jobs?count=50&tag=' + [uri]::EscapeDataString($tag))
        } catch { Log "    Jobicy '$tag' -> $($_.Exception.Message)" 'warn'; continue }
        foreach ($j in $d.jobs) {
            $f = $null; try { $f = [datetime]$j.pubDate } catch {}
            $desc = "$($j.jobExcerpt) $($j.jobDescription)"
            $out += New-Oferta 'Jobicy' $j.id $j.jobTitle $j.companyName $j.jobGeo `
                               $j.url $desc $f 'Remoto'
        }
        Start-Sleep -Milliseconds 400
    }
    return $out
}

function Get-Himalayas($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    $cursor = $null
    for ($p = 0; $p -lt $cfg.paginas; $p++) {
        $url = 'https://himalayas.app/jobs/api?limit=100'
        if ($cursor) { $url += '&cursor=' + [uri]::EscapeDataString($cursor) }
        try { $d = Get-Json $url } catch { Log "    Himalayas p$p -> $($_.Exception.Message)" 'warn'; break }
        foreach ($j in $d.jobs) {
            $f = $null
            try { $f = [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.pubDate).DateTime } catch {
                try { $f = [datetime]$j.pubDate } catch {}
            }
            $loc = ''
            if ($j.locationRestrictions) { $loc = ($j.locationRestrictions -join ', ') }
            if (-not $loc) { $loc = 'Worldwide' }
            $out += New-Oferta 'Himalayas' $j.guid $j.title $j.companyName $loc `
                               $j.applicationLink "$($j.excerpt) $($j.description)" $f 'Remoto'
        }
        $cursor = $d.nextCursor
        if (-not $cursor) { break }
        Start-Sleep -Milliseconds 400
    }
    return $out
}

function Get-RemoteOK($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    try { $d = Get-Json 'https://remoteok.com/api' } catch { Log "    RemoteOK -> $($_.Exception.Message)" 'warn'; return $out }
    foreach ($j in $d) {
        if (-not $j.position) { continue }
        $f = $null; try { $f = [datetime]$j.date } catch {}
        $loc = $j.location
        if (-not $loc) { $loc = 'Worldwide' }
        $desc = "$($j.description) $($j.tags -join ' ')"
        $out += New-Oferta 'RemoteOK' $j.id $j.position $j.company $loc $j.url $desc $f 'Remoto'
    }
    return $out
}

function Get-Indeed($cfg) {
    # OJO: Indeed usa proteccion anti-bot agresiva (similar a lo que ya nos paso con
    # Bumeran/Zonajobs, ver README). Este scraper hace peticiones HTML simples, sin
    # navegador real: es esperable que en muchos entornos devuelva 0 resultados o un
    # error 403/CAPTCHA en vez de la pagina de resultados. Probar antes de confiar en el.
    $out = @()
    if (-not $cfg.activo) { return $out }
    $dominio = if ($cfg.dominio) { $cfg.dominio } else { 'ar.indeed.com' }
    foreach ($kw in $cfg.keywords) {
        foreach ($loc in $cfg.ubicaciones) {
            for ($p = 0; $p -lt $cfg.paginas; $p++) {
                $start = $p * 10
                $url = "https://$dominio/jobs?q=" + [uri]::EscapeDataString($kw) +
                       '&l=' + [uri]::EscapeDataString($loc) + "&start=$start"
                try {
                    $html = Get-Web $url
                } catch {
                    Log "    Indeed '$kw' p$p -> $($_.Exception.Message)" 'warn'; continue
                }
                $bloques = [regex]::Matches($html, '(?s)<div class="job_seen_beacon".*?</div>\s*</table>')
                if ($bloques.Count -eq 0) { break }
                foreach ($b in $bloques) {
                    $t = $b.Value
                    $mId  = [regex]::Match($t, 'data-jk="([^"]+)"')
                    $mTit = [regex]::Match($t, '(?s)<h2 class="jobTitle[^"]*">.*?<span[^>]*>\s*(.*?)\s*</span>')
                    $mEmp = [regex]::Match($t, '(?s)<span class="companyName">\s*(.*?)\s*</span>')
                    $mLoc = [regex]::Match($t, '(?s)<div class="companyLocation">\s*(.*?)\s*</div>')
                    if (-not $mTit.Success -or -not $mId.Success) { continue }
                    $href = "https://$dominio/viewjob?jk=$($mId.Groups[1].Value)"
                    $out += New-Oferta 'Indeed' $mId.Groups[1].Value $mTit.Groups[1].Value $mEmp.Groups[1].Value `
                                       $mLoc.Groups[1].Value $href '' $null ''
                }
                Start-Sleep -Milliseconds 900
            }
        }
    }
    return $out
}

function Get-Arbeitnow($cfg) {
    $out = @()
    if (-not $cfg.activo) { return $out }
    try { $d = Get-Json 'https://www.arbeitnow.com/api/job-board-api' -TimeoutSec 90 } catch { Log "    Arbeitnow -> $($_.Exception.Message)" 'warn'; return $out }
    foreach ($j in $d.data) {
        $f = $null
        try { $f = [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.created_at).DateTime } catch {}
        $mod = ''
        if ($j.remote) { $mod = 'Remoto' }
        $out += New-Oferta 'Arbeitnow' $j.slug $j.title $j.company_name $j.location `
                           $j.url "$($j.description) $($j.tags -join ' ')" $f $mod
    }
    return $out
}

# -------------------------------------------------- enriquecer descripciones

function Enrich-Oferta($o) {
    try {
        if ($o.Fuente -eq 'LinkedIn') {
            $id = ($o.IdFuente -split '::')[1]
            if ($id -notmatch '^\d+$') { return }
            $h = Get-Web "https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/$id"
            $m = [regex]::Match($h, '(?s)<div class="[^"]*description__text[^"]*">(.*?)</div>\s*</div>')
            if ($m.Success) { $o.Descripcion = Clean-Html $m.Groups[1].Value }
            else            { $o.Descripcion = (Clean-Html $h) }
        }
        elseif ($o.Fuente -eq 'Computrabajo') {
            $h = Get-Web $o.Url
            $m = [regex]::Match($h, '(?s)<div class="mb40 pb40 bb1">(.*?)</div>')
            if ($m.Success) { $o.Descripcion = Clean-Html $m.Groups[1].Value }
            else {
                $m2 = [regex]::Match($h, '(?s)<p class="mbB">(.*?)</section>')
                if ($m2.Success) { $o.Descripcion = Clean-Html $m2.Groups[1].Value }
            }
        }
    } catch { }
}

# ---------------------------------------------------------------- puntuacion

function Score-Oferta($o, $perfil) {
    $tit  = Norm $o.Titulo
    $body = Norm ("$($o.Titulo) $($o.Descripcion) $($o.Modalidad)")
    # OJO: solo la ubicacion. Si se incluye Modalidad, las fuentes que marcan
    # todo como "Remoto" matchean el elegible "remoto" y se saltan el filtro de pais.
    $loc  = Norm $o.Ubicacion
    $motivos = New-Object System.Collections.ArrayList
    $alertas = New-Object System.Collections.ArrayList

    # 1. exclusiones duras por empresa (ej: tu propio empleador actual)
    $emp = Norm $o.Empresa
    foreach ($ex in $perfil.empresasExcluidas) {
        if ($emp -and $emp.Contains((Norm $ex))) {
            $o.Puntaje = 0
            $o.Alertas = @("Excluido por empresa: '$ex'")
            return
        }
    }

    # 1b. exclusiones duras por titulo
    foreach ($ex in $perfil.exclusiones) {
        if ($tit.Contains((Norm $ex))) {
            $o.Puntaje = 0
            $o.Alertas = @("Excluido por titulo: '$ex'")
            return
        }
    }

    # 2. habilidades: el titulo manda, el cuerpo aporta pero topeado.
    #    Sin el tope, una fuente que devuelve la descripcion completa (Jobicy)
    #    le gana siempre a una que solo da el titulo (LinkedIn, Computrabajo).
    $ptsTitulo = 0.0
    $ptsCuerpo = 0.0
    foreach ($p in $perfil.habilidades.PSObject.Properties) {
        $k = Norm $p.Name
        $w = [double]$p.Value
        if ($tit.Contains($k))      { $ptsTitulo += $w; [void]$motivos.Add("$($p.Name) (titulo)") }
        elseif ($body.Contains($k)) { $ptsCuerpo += $w; [void]$motivos.Add($p.Name) }
    }
    $tope = 18.0
    if ($perfil.topeCuerpo) { $tope = [double]$perfil.topeCuerpo }
    if ($ptsCuerpo -gt $tope) { $ptsCuerpo = $tope }
    $raw = $ptsTitulo + $ptsCuerpo

    # 3. rol nucleo en el titulo: filtro principal contra falsos positivos
    $tieneRol = $false
    foreach ($r in $perfil.rolesNucleo.terminos) {
        if ($tit.Contains((Norm $r))) { $tieneRol = $true; break }
    }
    if ($tieneRol) { $raw += [double]$perfil.rolesNucleo._bonus }
    else {
        $raw += [double]$perfil.rolesNucleo._penalidadSinRol
        [void]$alertas.Add('El titulo no es un rol de BI/Data')
    }

    # 4. geografia: se evalua solo sobre la ubicacion, no sobre toda la descripcion
    $geoOk = $false
    foreach ($t in $perfil.geo.elegibles) {
        if ($loc.Contains((Norm $t))) { $geoOk = $true; break }
    }
    if ($geoOk) { $raw += [double]$perfil.geo._bonus }
    else {
        foreach ($t in $perfil.geo.noElegibles) {
            if ($loc.Contains((Norm $t))) {
                $raw += [double]$perfil.geo._penalidad
                [void]$alertas.Add("Restringida a $($o.Ubicacion)")
                break
            }
        }
    }

    # 5. dominio afin al CV (fintech, pagos, transporte, banca...)
    foreach ($t in $perfil.dominios.terminos) {
        if ($body.Contains((Norm $t))) { $raw += [double]$perfil.dominios._peso; [void]$motivos.Add("dominio: $t"); break }
    }

    # 6. seniority
    foreach ($p in $perfil.seniority.PSObject.Properties) {
        if ($tit.Contains((Norm $p.Name))) { $raw += [double]$p.Value }
    }

    # 7. antiguedad
    if ($o.Fecha -and $perfil.diasMaximoAntiguedad -gt 0) {
        $dias = ((Get-Date) - $o.Fecha).TotalDays
        if ($dias -gt $perfil.diasMaximoAntiguedad) {
            $raw = $raw * 0.5
            [void]$alertas.Add("Publicada hace $([int]$dias) dias")
        }
    }

    if ($raw -lt 0) { $raw = 0 }
    $pct = [Math]::Round(($raw / [double]$perfil.escalaMaxima) * 100)
    if ($pct -gt 100) { $pct = 100 }
    $o.Puntaje = [int]$pct
    $o.Motivos = @($motivos | Select-Object -Unique -First 10)
    $o.Alertas = $alertas.ToArray()
}

# --------------------------------------------------------- cola de postulacion

function Read-ColaEstados([string]$Path) {
    $estados = @{}
    if (-not (Test-Path $Path)) { return $estados }
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    foreach ($line in ($txt -split "`n")) {
        $m = [regex]::Match($line, '^\|\s*\d+\s*\|\s*\[.*?\]\((.*?)\)\s*\|.*?\|.*?\|\s*(PENDIENTE|ENVIADA|DESCARTADA)\s*\|')
        if ($m.Success) { $estados[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return $estados
}

function Write-Cola($Ofertas, [string]$Path) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Cola de postulación')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Generado por `Buscar-Empleos.ps1`. Ofertas por encima del `puntajeMinimo` de `perfil.json`.')
    [void]$sb.AppendLine('Actualizá el `Estado` a mano (o pedile a Claude que lo actualice) a medida que postulás:')
    [void]$sb.AppendLine('`PENDIENTE` -> `ENVIADA` o `DESCARTADA`. La proxima corrida respeta lo que ya marcaste.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Puntaje | Título | Empresa | Fuente | Estado |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    foreach ($o in $Ofertas) {
        $tit = ($o.Titulo -replace '\|', '/')
        $emp = ($o.Empresa -replace '\|', '/')
        [void]$sb.AppendLine("| $($o.Puntaje) | [$tit]($($o.Url)) | $emp | $($o.Fuente) | $($o.Estado) |")
    }
    Write-Utf8 $Path $sb.ToString()
}

# ------------------------------------------------------------------- reporte

function Build-Html($ofertas, $perfil, $stats) {
    $css = @'
<style>
:root{--bg:#f7f7f5;--card:#fff;--ink:#1a1a18;--mut:#6b6b66;--line:#e3e3de;--acc:#c25c30;--ok:#3f7d5a;--warn:#a8742a}
@media(prefers-color-scheme:dark){:root:not([data-t="light"]){--bg:#16161a;--card:#1e1e23;--ink:#eceae6;--mut:#9a9a93;--line:#2e2e35;--acc:#e0794a;--ok:#63a883;--warn:#d3a05a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:26px;margin:0 0 4px;letter-spacing:-.02em}
.sub{color:var(--mut);font-size:14px;margin:0 0 24px}
.stats{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:24px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 14px;min-width:100px}
.stat b{display:block;font-size:22px;line-height:1.2}
.stat span{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.05em}
.bar{display:flex;flex-wrap:wrap;gap:6px;margin-bottom:20px}
.bar button{background:var(--card);border:1px solid var(--line);color:var(--ink);border-radius:20px;padding:6px 13px;font-size:13px;cursor:pointer}
.bar button.on{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.job{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:10px;display:grid;grid-template-columns:56px 1fr;gap:16px;align-items:start}
.job[hidden]{display:none!important}
.sc{width:56px;height:56px;border-radius:50%;display:grid;place-items:center;font-weight:700;font-size:17px;color:#fff;background:var(--mut)}
.s90{background:#2f7a52}.s70{background:#5b8f3c}.s50{background:#b0862c}.s30{background:#9a6a4a}
.t{font-size:16px;font-weight:650;margin:0 0 3px;letter-spacing:-.01em}
.t a{color:var(--ink);text-decoration:none}.t a:hover{color:var(--acc)}
.meta{color:var(--mut);font-size:13px;margin:0 0 8px}
.meta b{color:var(--ink);font-weight:600}
.chips{display:flex;flex-wrap:wrap;gap:5px}
.chip{font-size:11px;padding:2px 8px;border-radius:6px;border:1px solid var(--line);color:var(--mut)}
.chip.src{border-color:var(--acc);color:var(--acc)}
.chip.new{background:var(--ok);border-color:var(--ok);color:#fff;font-weight:600}
.chip.al{border-color:var(--warn);color:var(--warn)}
.chip.enviada{background:var(--ok);border-color:var(--ok);color:#fff;font-weight:600}
.chip.descartada{border-color:var(--mut);color:var(--mut);text-decoration:line-through}
.chip.pendiente{border-color:var(--line);color:var(--mut)}
.chip.revisar{background:var(--warn);border-color:var(--warn);color:#fff;font-weight:600}
.why{color:var(--mut);font-size:12px;margin-top:8px}
footer{color:var(--mut);font-size:12px;margin-top:32px;border-top:1px solid var(--line);padding-top:14px}
@media(max-width:640px){.job{grid-template-columns:44px 1fr;gap:12px}.sc{width:44px;height:44px;font-size:14px}}
</style>
'@
    $js = @'
<script>
document.querySelectorAll('.bar button').forEach(function(b){
  b.addEventListener('click',function(){
    document.querySelectorAll('.bar button').forEach(function(x){x.classList.remove('on')});
    b.classList.add('on');
    var f=b.dataset.f;
    document.querySelectorAll('.job').forEach(function(j){
      j.hidden = !(f==='*' || (f==='new' && j.dataset.new==='1') || j.dataset.src===f);
    });
  });
});
</script>
'@

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!doctype html><html lang="es"><head><meta charset="utf-8">')
    [void]$sb.Append('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.Append('<title>Radar de empleos - ' + (Get-Date -Format 'dd/MM/yyyy') + '</title>')
    [void]$sb.Append($css + '</head><body><div class="wrap">')
    [void]$sb.Append('<h1>Radar de empleos</h1>')
    [void]$sb.Append('<p class="sub">' + [System.Net.WebUtility]::HtmlEncode($perfil.candidato.titulo) +
                     ' &middot; ' + [System.Net.WebUtility]::HtmlEncode($perfil.candidato.ubicacion) +
                     ' &middot; corrida del ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '</p>')

    [void]$sb.Append('<div class="stats">')
    [void]$sb.Append('<div class="stat"><b>' + $ofertas.Count + '</b><span>Con match</span></div>')
    [void]$sb.Append('<div class="stat"><b>' + (@($ofertas | Where-Object { $_.Nuevo }).Count) + '</b><span>Nuevas</span></div>')
    [void]$sb.Append('<div class="stat"><b>' + (@($ofertas | Where-Object { $_.Puntaje -ge 70 }).Count) + '</b><span>Match alto</span></div>')
    [void]$sb.Append('<div class="stat"><b>' + (@($ofertas | Where-Object { $_.PSObject.Properties.Name -contains 'Estado' -and $_.Estado -eq 'REVISAR' }).Count) + '</b><span>A revisar</span></div>')
    [void]$sb.Append('<div class="stat"><b>' + $stats.Recolectadas + '</b><span>Analizadas</span></div>')
    [void]$sb.Append('</div>')

    [void]$sb.Append('<div class="bar"><button class="on" data-f="*">Todas</button>')
    [void]$sb.Append('<button data-f="new">Solo nuevas</button>')
    foreach ($f in ($ofertas | Select-Object -ExpandProperty Fuente -Unique | Sort-Object)) {
        [void]$sb.Append('<button data-f="' + $f + '">' + $f + '</button>')
    }
    [void]$sb.Append('</div>')

    foreach ($o in $ofertas) {
        $cls = 's30'
        if ($o.Puntaje -ge 90) { $cls = 's90' } elseif ($o.Puntaje -ge 70) { $cls = 's70' } elseif ($o.Puntaje -ge 50) { $cls = 's50' }
        $nv = '0'; if ($o.Nuevo) { $nv = '1' }
        [void]$sb.Append('<div class="job" data-src="' + $o.Fuente + '" data-new="' + $nv + '">')
        [void]$sb.Append('<div class="sc ' + $cls + '">' + $o.Puntaje + '</div><div>')
        $estado = 'PENDIENTE'
        if ($o.PSObject.Properties.Name -contains 'Estado' -and $o.Estado) { $estado = $o.Estado }
        $estadoCls = 'pendiente'
        if ($estado -eq 'ENVIADA') { $estadoCls = 'enviada' } elseif ($estado -eq 'DESCARTADA') { $estadoCls = 'descartada' } elseif ($estado -eq 'REVISAR') { $estadoCls = 'revisar' }
        [void]$sb.Append('<p class="t"><a href="' + [System.Net.WebUtility]::HtmlEncode($o.Url) + '" target="_blank" rel="noopener">' +
                         [System.Net.WebUtility]::HtmlEncode($o.Titulo) + '</a> <span class="chip ' + $estadoCls + '">' +
                         $estado + '</span></p>')
        $emp = $o.Empresa; if (-not $emp) { $emp = 'Empresa no informada' }
        $partes = @('<b>' + [System.Net.WebUtility]::HtmlEncode($emp) + '</b>')
        if ($o.Ubicacion) { $partes += [System.Net.WebUtility]::HtmlEncode($o.Ubicacion) }
        if ($o.Fecha)     { $partes += $o.Fecha.ToString('dd/MM/yyyy') }
        elseif ($o.PSObject.Properties.Name -contains 'FechaTexto' -and $o.FechaTexto) { $partes += [System.Net.WebUtility]::HtmlEncode($o.FechaTexto) }
        [void]$sb.Append('<p class="meta">' + ($partes -join ' &middot; ') + '</p>')

        [void]$sb.Append('<div class="chips"><span class="chip src">' + $o.Fuente + '</span>')
        if ($o.Nuevo)     { [void]$sb.Append('<span class="chip new">NUEVA</span>') }
        if ($o.Modalidad) { [void]$sb.Append('<span class="chip">' + [System.Net.WebUtility]::HtmlEncode($o.Modalidad) + '</span>') }
        foreach ($a in $o.Alertas) { [void]$sb.Append('<span class="chip al">' + [System.Net.WebUtility]::HtmlEncode($a) + '</span>') }
        [void]$sb.Append('</div>')

        if ($o.Motivos.Count -gt 0) {
            $motivosEnc = $o.Motivos | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_) }
            [void]$sb.Append('<p class="why">Coincide en: ' + ($motivosEnc -join ' &middot; ') + '</p>')
        }
        [void]$sb.Append('</div></div>')
    }

    [void]$sb.Append('<footer>Generado por Buscar-Empleos.ps1 &middot; fuentes: ' + ($stats.Fuentes -join ', ') +
                     '. Los puntajes son heuristicos: sirven para ordenar, no para decidir por vos.</footer>')
    [void]$sb.Append('</div>' + $js + '</body></html>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------- main

Log ''
Log '  RADAR DE EMPLEOS' 'head'
Log '  ================' 'head'

$perfil = Read-Utf8Json $RutaPerfil
if ($PuntajeMinimo -ge 0) { $perfil.puntajeMinimo = $PuntajeMinimo }
Log "  Perfil: $($perfil.candidato.titulo)"
Log ''

$todas   = @()
$fuentes = @()
$plan = @(
    @{ N = 'LinkedIn';     F = ${function:Get-LinkedIn};     C = $perfil.busquedas.linkedin }
    @{ N = 'Computrabajo'; F = ${function:Get-Computrabajo}; C = $perfil.busquedas.computrabajo }
    @{ N = 'Indeed';       F = ${function:Get-Indeed};       C = $perfil.busquedas.indeed }
    @{ N = 'Remotive';     F = ${function:Get-Remotive};     C = $perfil.busquedas.remotive }
    @{ N = 'Jobicy';       F = ${function:Get-Jobicy};       C = $perfil.busquedas.jobicy }
    @{ N = 'Himalayas';    F = ${function:Get-Himalayas};    C = $perfil.busquedas.himalayas }
    @{ N = 'RemoteOK';     F = ${function:Get-RemoteOK};     C = $perfil.busquedas.remoteok }
    @{ N = 'Arbeitnow';    F = ${function:Get-Arbeitnow};    C = $perfil.busquedas.arbeitnow }
)

foreach ($s in $plan) {
    if (-not $s.C.activo) { Log "  - $($s.N): desactivado en perfil.json"; continue }
    Write-Host ("  - {0,-13} " -f $s.N) -NoNewline
    try {
        $r = & $s.F $s.C
        $r = @($r)
        Log "$($r.Count) ofertas" 'ok'
        $todas += $r
        $fuentes += $s.N
    } catch {
        Log "ERROR: $($_.Exception.Message)" 'err'
    }
}

$recolectadas = $todas.Count
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
Log ''
Log "  Recolectadas: $recolectadas"

# deduplicar por titulo+empresa normalizados, quedandonos con la fuente mas util
$prioridad = @{ 'LinkedIn' = 1; 'Computrabajo' = 2; 'Indeed' = 3; 'Remotive' = 4; 'Himalayas' = 5; 'Jobicy' = 6; 'RemoteOK' = 7; 'Arbeitnow' = 8 }
$vistoClave = @{}
$unicas = @()
foreach ($o in ($todas | Sort-Object @{E = { $prioridad[$_.Fuente] }})) {
    $clave = (Norm $o.Titulo) + '|' + (Norm $o.Empresa)
    if ($vistoClave.ContainsKey($clave)) { continue }
    $vistoClave[$clave] = $true
    $unicas += $o
}
Log "  Unicas tras deduplicar: $($unicas.Count)"

# puntuacion preliminar (titulo + lo que ya tengamos)
foreach ($o in $unicas) { Score-Oferta $o $perfil }

# enriquecer las mejores que no tienen descripcion, y repuntuar
if (-not $SinDetalle) {
    $candidatas = @($unicas |
        Where-Object { -not $_.Descripcion -and $_.Puntaje -gt 0 } |
        Sort-Object Puntaje -Descending |
        Select-Object -First $perfil.enriquecerTopN)
    if ($candidatas.Count -gt 0) {
        Log "  Bajando descripcion de las $($candidatas.Count) mejores sin detalle..."
        $i = 0
        foreach ($o in $candidatas) {
            $i++
            Write-Host ("`r    $i/$($candidatas.Count)") -NoNewline
            Enrich-Oferta $o
            Score-Oferta $o $perfil
            Start-Sleep -Milliseconds 600
        }
        Write-Host ''
    }
}

$final = @($unicas | Where-Object { $_.Puntaje -ge $perfil.puntajeMinimo } | Sort-Object Puntaje -Descending)
Log "  Superan el puntaje minimo ($($perfil.puntajeMinimo)): $($final.Count)" 'ok'

# estado: marcar nuevas
$archivoVistos = Join-Path $DirDatos 'vistos.json'
$vistos = @{}
if (Test-Path $archivoVistos) {
    try {
        $j = Read-Utf8Json $archivoVistos
        foreach ($p in $j.PSObject.Properties) { $vistos[$p.Name] = $p.Value }
    } catch { }
}
$hoy = (Get-Date).ToString('yyyy-MM-dd')
foreach ($o in $final) {
    if (-not $vistos.ContainsKey($o.IdFuente)) {
        $o.Nuevo = $true
        $vistos[$o.IdFuente] = $hoy
    }
}
Log "  Nuevas desde la ultima corrida: $(@($final | Where-Object { $_.Nuevo }).Count)" 'ok'
Write-Utf8 $archivoVistos (($vistos | ConvertTo-Json -Depth 3))

# estado de postulacion: por debajo de puntajeAutoEnvio queda REVISAR (no se postula),
# salvo que ya lo hayas marcado ENVIADA/DESCARTADA a mano en una corrida anterior.
$umbralAuto = 70
if ($perfil.puntajeAutoEnvio) { $umbralAuto = [int]$perfil.puntajeAutoEnvio }
$rutaCola = Join-Path $Raiz 'cola-postulacion.md'
$estadosPrevios = Read-ColaEstados $rutaCola
foreach ($o in $final) {
    $estado = if ($o.Puntaje -lt $umbralAuto) { 'REVISAR' } else { 'PENDIENTE' }
    if ($estadosPrevios.ContainsKey($o.Url)) { $estado = $estadosPrevios[$o.Url] }
    $o | Add-Member -NotePropertyName Estado -NotePropertyValue $estado -Force
}
Write-Cola $final $rutaCola
Log "  Cola de postulacion: $rutaCola" 'ok'
$countRevisar = @($final | Where-Object { $_.Estado -eq 'REVISAR' }).Count
Log "  A revisar (match < $umbralAuto, no se postulan solas): $countRevisar" 'warn'

# reporte de brechas: que terminos aparecen seguido en las ofertas REVISAR y no estan en tu perfil
$rutaBrechas = $null
if ($countRevisar -gt 0 -and $perfil.vocabularioBrechas -and $perfil.vocabularioBrechas.Count -gt 0) {
    $conteo = @{}
    $ejemplos = @{}
    foreach ($o in ($final | Where-Object { $_.Estado -eq 'REVISAR' })) {
        $texto = Norm ("$($o.Titulo) $($o.Descripcion)")
        foreach ($termino in $perfil.vocabularioBrechas) {
            if ($texto.Contains((Norm $termino))) {
                if (-not $conteo.ContainsKey($termino)) { $conteo[$termino] = 0; $ejemplos[$termino] = @() }
                $conteo[$termino]++
                if ($ejemplos[$termino].Count -lt 3) { $ejemplos[$termino] += $o.Titulo }
            }
        }
    }
    if ($conteo.Count -gt 0) {
        $rutaBrechas = Join-Path $DirReportes "brechas_$stamp.md"
        $sbB = New-Object System.Text.StringBuilder
        [void]$sbB.AppendLine('# Brechas de skills detectadas')
        [void]$sbB.AppendLine('')
        [void]$sbB.AppendLine("Terminos que aparecen en ofertas de match medio-bajo (REVISAR, puntaje < $umbralAuto) y que NO estan en tu perfil (`habilidades` de `perfil.json`).")
        [void]$sbB.AppendLine('Si algo se repite mucho, es candidato a sumarse al CV/perfil (si lo tenes) o a formacion (si no).')
        [void]$sbB.AppendLine('')
        [void]$sbB.AppendLine('| Termino | Ofertas que lo mencionan | Ejemplos |')
        [void]$sbB.AppendLine('|---|---|---|')
        foreach ($k in ($conteo.Keys | Sort-Object { $conteo[$_] } -Descending)) {
            [void]$sbB.AppendLine("| $k | $($conteo[$k]) | $(($ejemplos[$k] -join '; ')) |")
        }
        Write-Utf8 $rutaBrechas $sbB.ToString()
        Log "  Reporte de brechas: $rutaBrechas" 'warn'
    }
}

# salidas
$rutaCsv = Join-Path $DirReportes "ofertas_$stamp.csv"
$final | Select-Object Puntaje, Estado, Nuevo, Fuente, Titulo, Empresa, Ubicacion, Modalidad,
    @{N='Fecha';E={ if ($_.Fecha) { $_.Fecha.ToString('yyyy-MM-dd') } else { '' } }},
    @{N='Motivos';E={ $_.Motivos -join '; ' }},
    @{N='Alertas';E={ $_.Alertas -join '; ' }}, Url |
    Export-Csv -Path $rutaCsv -NoTypeInformation -Encoding UTF8

$stats = @{ Recolectadas = $recolectadas; Fuentes = $fuentes }
$rutaHtml = Join-Path $DirReportes "reporte_$stamp.html"
Write-Utf8 $rutaHtml (Build-Html $final $perfil $stats)

Log ''
Log "  Reporte: $rutaHtml" 'ok'
Log "  CSV:     $rutaCsv" 'ok'
Log ''

if (-not $NoAbrir) { Start-Process $rutaHtml }
