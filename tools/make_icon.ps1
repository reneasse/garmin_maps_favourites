# Erzeugt alle Launcher-Icons und die grosse Store-Fassung.
#
# Die Edge-Modelle verlangen unterschiedliche Icon-Kantenlaengen (35 bis 68 px).
# Gezeichnet wird einmal 8-fach vergroessert und anschliessend auf jede Zielgroesse
# heruntergerechnet, damit die Kanten sauber bleiben. Geraeteabweichende Groessen
# landen in resources-<device>/, was Connect IQ automatisch dem jeweiligen Geraet
# zuordnet; resources/ traegt die Basisgroesse fuer den Edge 1050.
param(
    [string]$Root = "$PSScriptRoot\..",
    [int]$Scale = 8
)

Add-Type -AssemblyName System.Drawing

# Geraet -> Kantenlaenge des Launcher-Icons (aus compiler.json des SDK).
$targets = [ordered]@{
    ''         = 68   # Basis: resources/, gilt fuer den Edge 1050
    'edge1040' = 40
    'edge850'  = 56
    'edge550'  = 56
    'edge840'  = 35
    'edge540'  = 35
}

$S = 68 * $Scale
$bmp = New-Object System.Drawing.Bitmap $S, $S
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.Clear([System.Drawing.Color]::Transparent)

function U([double]$v) { return [float]($v * $Scale) }
function P([double]$x, [double]$y) {
    return New-Object System.Drawing.PointF ([float]($x * $Scale)), ([float]($y * $Scale))
}

# --- Kartennadel ------------------------------------------------------------
# Kreis plus Spitze, in der Signalfarbe von Google Maps.
$pin = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 234, 67, 53))
$g.FillEllipse($pin, (U 11), (U 4), (U 46), (U 46))
$tip = @((P 19.5 40), (P 48.5 40), (P 34 65))
$g.FillPolygon($pin, [System.Drawing.PointF[]]$tip)

# --- Stern: der Ort ist ein Favorit -----------------------------------------
# Fuenfzackig, aus zehn abwechselnd weit und nah liegenden Punkten.
$star = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$cx = 34.0
$cy = 27.0
$outer = 14.0
$inner = 5.8
$pts = @()
for ($i = 0; $i -lt 10; $i++) {
    $r = if ($i % 2 -eq 0) { $outer } else { $inner }
    $a = [Math]::PI * (-0.5 + $i * 0.2)
    $pts += (P ($cx + $r * [Math]::Cos($a)) ($cy + $r * [Math]::Sin($a)))
}
$g.FillPolygon($star, [System.Drawing.PointF[]]$pts)

$star.Dispose()
$pin.Dispose()
$g.Dispose()

function Save-Scaled([System.Drawing.Bitmap]$src, [int]$size, [string]$path) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $out = New-Object System.Drawing.Bitmap $size, $size
    $gg = [System.Drawing.Graphics]::FromImage($out)
    $gg.InterpolationMode = 'HighQualityBicubic'
    $gg.PixelOffsetMode = 'HighQuality'
    $gg.SmoothingMode = 'AntiAlias'
    $gg.Clear([System.Drawing.Color]::Transparent)
    $gg.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $size, $size))
    $gg.Dispose()
    $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $out.Dispose()
    Write-Output ("{0,-52} {1}x{1}" -f $path.Replace("$Root\", ''), $size)
}

$drawablesXml = @'
<drawables>
    <bitmap id="LauncherIcon" filename="launcher_icon.png"/>
</drawables>
'@

foreach ($device in $targets.Keys) {
    $folder = if ($device -eq '') { 'resources' } else { "resources-$device" }
    $dir = Join-Path $Root "$folder\drawables"
    Save-Scaled $bmp $targets[$device] (Join-Path $dir 'launcher_icon.png')
    Set-Content -Path (Join-Path $dir 'drawables.xml') -Value $drawablesXml -Encoding utf8
}

Save-Scaled $bmp 512 (Join-Path $Root 'store\icon_512.png')
$bmp.Dispose()
