#requires -version 7.0
<#
    GorillazAtWar  (author: Michael DALLA RIVA)
    An original, from-scratch reimplementation of the classic "two gorillas lob
    an exploding banana between buildings" game, rendered with real vector
    graphics (WinForms + GDI+) instead of console text characters.

    Attribution: This game is based on the concept of the original QBasic
    Gorillas game, which shipped as a sample program with MS-DOS 5.0 (1991)
    and QBasic. Its exact authorship is unclear - some sources credit IBM,
    others Microsoft - and available online information is conflicting, so
    no definitive original-author credit is given here. No original QBasic
    source code is included; this is an independent reimplementation.

    Run it normally: pwsh -File .\gorillas.ps1
    (WinForms needs an STA thread - the script relaunches itself with -sta
    automatically if it isn't already running on one.)
#>

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $psExe -ArgumentList @('-NoLogo', '-NoProfile', '-sta', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Enable-DoubleBuffering([System.Windows.Forms.Control]$control) {
    $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance, NonPublic')
    $prop.SetValue($control, $true, $null)
}

# ---------------------------------------------------------------------------
# CONSTANTS / STATE
# ---------------------------------------------------------------------------

$CanvasW = 1180
$CanvasH = 620
$GroundY = $CanvasH

$DaySkyTop     = [System.Drawing.Color]::FromArgb(80, 160, 235)
$DaySkyBottom  = [System.Drawing.Color]::FromArgb(190, 225, 250)
$NightSkyTop   = [System.Drawing.Color]::FromArgb(10, 10, 60)
$NightSkyBottom = [System.Drawing.Color]::FromArgb(0, 0, 20)

$BuildingPalette = @(
    [System.Drawing.Color]::FromArgb(0, 150, 150),   # teal
    [System.Drawing.Color]::FromArgb(150, 150, 150),  # gray
    [System.Drawing.Color]::FromArgb(160, 20, 20),    # red
    [System.Drawing.Color]::FromArgb(120, 30, 150),   # purple
    [System.Drawing.Color]::FromArgb(180, 120, 20)    # amber
)
$WindowLit  = [System.Drawing.Color]::FromArgb(255, 230, 90)
$WindowDark = [System.Drawing.Color]::FromArgb(40, 40, 45)

$script:Rng       = [Random]::new()
$script:Buildings = New-Object System.Collections.Generic.List[object]
$script:Craters   = New-Object System.Collections.Generic.List[object]
$script:Stars     = 1..40 | ForEach-Object {
    [pscustomobject]@{ X = $script:Rng.Next(0, $CanvasW); Y = $script:Rng.Next(0, [int]($CanvasH * 0.4)) }
}

$script:P1 = [pscustomobject]@{ Num = 1; X = 0; Y = 0; Color = [System.Drawing.Color]::FromArgb(230, 90, 60); Score = 0; Pose = 'idle' }
$script:P2 = [pscustomobject]@{ Num = 2; X = 0; Y = 0; Color = [System.Drawing.Color]::FromArgb(90, 170, 230); Score = 0; Pose = 'idle' }

$script:Wind      = 0
$script:Active    = 1
$script:State     = 'Idle'     # Idle | Flying | Exploding | Message
$script:Message   = ''
$script:Banana    = $null
$script:Explosion = $null
$script:Plane     = $null

$script:SoundOn  = $true
$script:IsDaytime = $true
$script:GameSpeed = 2.0
$script:AnimClock = 0.0
$script:VsCpu    = $false
$script:CpuPending = $false
$script:CpuMemory  = @{
    HasShot   = $false
    LastAngle = 45
    LastPower = 55
    LandX     = 0
    LandY     = 0
    Angle     = 0       # arc angle locked for the current round's power search (0 = not chosen yet)
    LoPower   = $null   # highest power known to fall SHORT  (lower bracket)
    LoDist    = 0
    HiPower   = $null   # lowest  power known to OVERSHOOT   (upper bracket)
    HiDist    = 0
    Shots     = 0       # shots taken this round (drives the shrinking aim jitter)
}
$script:Bubble   = $null
$script:Taunts   = @(
    "Ooh ooh aah aah!", "Nice throw... NOT!", "Banana time!",
    "You call that aim?", "Splat! Gotcha!", "King of the jungle!",
    "Too easy!", "Feel the fury!", "Direct hit!"
)
$script:Clouds = 1..5 | ForEach-Object {
    [pscustomobject]@{
        X = $script:Rng.Next(0, $CanvasW)
        Y = $script:Rng.Next(15, 130)
        Speed = 0.15 + $script:Rng.NextDouble() * 0.35
        Scale = 0.7 + $script:Rng.NextDouble() * 0.8
    }
}

function Invoke-Sound([string]$kind) {
    if (-not $script:SoundOn) { return }
    try {
        switch ($kind) {
            'throw'   { [Console]::Beep(300, 60) }
            'explode' { [Console]::Beep(150, 130) }
            'win'     { [Console]::Beep(523,90); [Console]::Beep(659,90); [Console]::Beep(784,90); [Console]::Beep(1047,220) }
        }
    } catch {
        try {
            switch ($kind) {
                'throw'   { [System.Media.SystemSounds]::Asterisk.Play() }
                'explode' { [System.Media.SystemSounds]::Exclamation.Play() }
                'win'     { [System.Media.SystemSounds]::Asterisk.Play() }
            }
        } catch { }
    }
}

function Update-Clouds {
    foreach ($c in $script:Clouds) {
        $c.X += $c.Speed
        if ($c.X - (90 * $c.Scale) -gt $CanvasW) {
            $c.X = -(120 * $c.Scale)
            $c.Y = $script:Rng.Next(15, 130)
            $c.Scale = 0.7 + $script:Rng.NextDouble() * 0.8
            $c.Speed = 0.15 + $script:Rng.NextDouble() * 0.35
        }
    }
}

# ---------------------------------------------------------------------------
# SKYLINE
# ---------------------------------------------------------------------------

function Get-SkyColor([double]$y) {
    $top    = if ($script:IsDaytime) { $DaySkyTop }    else { $NightSkyTop }
    $bottom = if ($script:IsDaytime) { $DaySkyBottom }  else { $NightSkyBottom }
    $t = [Math]::Max(0.0, [Math]::Min(1.0, $y / $CanvasH))
    $r = [int]($top.R + ($bottom.R - $top.R) * $t)
    $g = [int]($top.G + ($bottom.G - $top.G) * $t)
    $b = [int]($top.B + ($bottom.B - $top.B) * $t)
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function New-Skyline {
    $script:Buildings.Clear()
    $script:Craters.Clear()
    $x = 0
    $lastH = $script:Rng.Next(180, 330)
    while ($x -lt $CanvasW) {
        # Mixed city blocks: narrow towers, ordinary offices and broad apartment slabs.
        $roll = $script:Rng.NextDouble()
        $w = if ($roll -lt .22) { $script:Rng.Next(54, 78) } elseif ($roll -lt .78) { $script:Rng.Next(78, 126) } else { $script:Rng.Next(126, 166) }
        $targetH = if ($w -lt 75) { $script:Rng.Next(245, 410) } else { $script:Rng.Next(145, 365) }
        # Neighbouring buildings belong to the same city, but never form a flat wall.
        $h = [int](($targetH * .72) + ($lastH * .28) + $script:Rng.Next(-42, 43))
        $h = [Math]::Max(135, [Math]::Min(405, $h))
        if ([Math]::Abs($h - $lastH) -lt 28) { $h += $(if ($script:Rng.Next(0,2)) { 38 } else { -38 }) }
        $h = [Math]::Max(135, [Math]::Min(405, $h)); $lastH = $h
        $color = $BuildingPalette[$script:Rng.Next(0, $BuildingPalette.Length)]
        $style = $script:Rng.Next(0, 4)
        $rows = [Math]::Max(4, [int](($h - 18) / $script:Rng.Next(21, 27)))
        $cols = [Math]::Max(2, [int](($w - 14) / $script:Rng.Next(18, 23)))
        $lit = New-Object 'bool[,]' $rows, $cols
        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt $cols; $c++) {
                $lit[$r, $c] = $script:Rng.NextDouble() -gt 0.4
            }
        }
        $b = [pscustomobject]@{
            X = $x; Y = ($GroundY - $h); W = $w; H = $h
            Color = $color; Rows = $rows; Cols = $cols; Lit = $lit
            Style = $style
            Roof = $script:Rng.Next(0, 4)
            Accent = $script:Rng.NextDouble() -lt .42
            Seed = $script:Rng.Next(1, 1000000)
        }
        $script:Buildings.Add($b) | Out-Null
        $x += $w
    }
    if ($script:Buildings.Count -gt 0) {
        $last = $script:Buildings[$script:Buildings.Count - 1]
        $last.W = $CanvasW - $last.X
    }
}

function Get-BuildingAt([double]$px) {
    foreach ($b in $script:Buildings) {
        if ($px -ge $b.X -and $px -lt ($b.X + $b.W)) { return $b }
    }
    return $null
}

function Test-Solid([double]$x, [double]$y) {
    $bld = Get-BuildingAt $x
    if (-not $bld -or $y -lt $bld.Y) { return $false }
    foreach ($cr in $script:Craters) {
        $dx = $x - $cr.X; $dy = $y - $cr.Y
        if (($dx*$dx + $dy*$dy) -le ($cr.R * $cr.R)) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# GORILLA / ROUND SETUP
# ---------------------------------------------------------------------------

function Update-Hud {

    if ($script:VsCpu -and $script:Active -eq 2 -and $script:State -eq 'Idle' -and -not $script:CpuPending) {
        Start-CpuThinking
    }
    $script:canvas.Invalidate()
}

function New-Round {
    New-Skyline
    $script:Wind = $script:Rng.Next(-18, 19)
    $script:Craters.Clear()
    $script:Banana = $null
    $script:Explosion = $null
    $script:Plane = $null
    $script:Message = ''
    $script:Bubble = $null
    $script:State = 'Idle'
    $script:P1.Pose = 'idle'
    $script:P2.Pose = 'idle'
    $script:CpuPending = $false
    $script:CpuMemory.HasShot = $false
    $script:CpuMemory.Angle   = 0        # a fresh arc is chosen on the first shot of the round
    $script:CpuMemory.LoPower = $null    # clear the short/long bracket so aim is re-learned per layout
    $script:CpuMemory.HiPower = $null
    $script:CpuMemory.Shots   = 0

    $leftIdx  = $script:Rng.Next(0, [Math]::Max(1, [int]($script:Buildings.Count * 0.35)))
    $rightIdx = $script:Rng.Next([int]($script:Buildings.Count * 0.65), $script:Buildings.Count)
    if ($rightIdx -ge $script:Buildings.Count) { $rightIdx = $script:Buildings.Count - 1 }

    $bl = $script:Buildings[$leftIdx]
    $br = $script:Buildings[$rightIdx]

    $script:P1.X = $bl.X + $bl.W / 2
    $script:P1.Y = $bl.Y
    $script:P2.X = $br.X + $br.W / 2
    $script:P2.Y = $br.Y

    Update-Hud
}

# ---------------------------------------------------------------------------
# DRAWING
# ---------------------------------------------------------------------------

function Get-Shade([System.Drawing.Color]$c, [double]$f) {
    $rr = [int][Math]::Max(0, [Math]::Min(255, $c.R * $f))
    $gg = [int][Math]::Max(0, [Math]::Min(255, $c.G * $f))
    $bb = [int][Math]::Max(0, [Math]::Min(255, $c.B * $f))
    return [System.Drawing.Color]::FromArgb($c.A, $rr, $gg, $bb)
}

function Add-ShadedEllipse($g, [double]$cx, [double]$cy, [double]$rx, [double]$ry, [System.Drawing.Color]$base) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddEllipse([float]($cx - $rx), [float]($cy - $ry), [float]($rx * 2), [float]($ry * 2))
    $pgb = [System.Drawing.Drawing2D.PathGradientBrush]::new($path)
    $pgb.CenterColor = (Get-Shade $base 1.5)
    $pgb.SurroundColors = [System.Drawing.Color[]]@((Get-Shade $base 0.65))
    $pgb.CenterPoint = [System.Drawing.PointF]::new([float]($cx - $rx * 0.35), [float]($cy - $ry * 0.4))
    $pgb.FocusScales = [System.Drawing.PointF]::new(0.25, 0.25)
    $g.FillPath($pgb, $path)
    $pgb.Dispose(); $path.Dispose()
}

function Show-Sun($g) {
    $cx = $CanvasW * 0.5; $cy = 70; $r = 26
    $pen = [System.Drawing.Pen]::new(([System.Drawing.Color]::FromArgb(255, 220, 60)), 3)
    for ($i = 0; $i -lt 12; $i++) {
        $ang = $i * (360.0 / 12) * [Math]::PI / 180
        $x1 = $cx + [Math]::Cos($ang) * ($r + 6)
        $y1 = $cy + [Math]::Sin($ang) * ($r + 6)
        $x2 = $cx + [Math]::Cos($ang) * ($r + 16)
        $y2 = $cy + [Math]::Sin($ang) * ($r + 16)
        $g.DrawLine($pen, [float]$x1, [float]$y1, [float]$x2, [float]$y2)
    }
    $pen.Dispose()
    $sunBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 225, 70))
    $g.FillEllipse($sunBrush, [float]($cx - $r), [float]($cy - $r), [float]($r*2), [float]($r*2))
    $sunBrush.Dispose()
    $facePen = [System.Drawing.Pen]::new(([System.Drawing.Color]::FromArgb(120, 80, 0)), 2)
    $g.FillEllipse([System.Drawing.Brushes]::SaddleBrown, [float]($cx-9), [float]($cy-6), 3, 3)
    $g.FillEllipse([System.Drawing.Brushes]::SaddleBrown, [float]($cx+6), [float]($cy-6), 3, 3)
    $g.DrawArc($facePen, [float]($cx-9), [float]($cy-2), 18, 12, 0, 180)
    $facePen.Dispose()
}

function Show-Moon($g) {
    $cx = $CanvasW * 0.5; $cy = 70; $r = 24

    # soft glow halo
    $glowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(40, 230, 230, 255))
    $g.FillEllipse($glowBrush, [float]($cx - $r - 10), [float]($cy - $r - 10), [float](($r+10)*2), [float](($r+10)*2))
    $glowBrush.Dispose()

    # main moon disc (full moon)
    $moonBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(235, 235, 245))
    $g.FillEllipse($moonBrush, [float]($cx - $r), [float]($cy - $r), [float]($r*2), [float]($r*2))
    $moonBrush.Dispose()

    # a few soft craters for character
    $craterBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55, 190, 190, 200))
    $g.FillEllipse($craterBrush, [float]($cx-14), [float]($cy-10), 7, 7)
    $g.FillEllipse($craterBrush, [float]($cx+6), [float]($cy-4), 5, 5)
    $g.FillEllipse($craterBrush, [float]($cx-4), [float]($cy+9), 6, 6)
    $craterBrush.Dispose()

    # a cute little face, centered like the sun's
    $g.FillEllipse([System.Drawing.Brushes]::DimGray, [float]($cx-9), [float]($cy-6), 3, 3)
    $g.FillEllipse([System.Drawing.Brushes]::DimGray, [float]($cx+6), [float]($cy-6), 3, 3)
    $facePen = [System.Drawing.Pen]::new([System.Drawing.Color]::DimGray, 2)
    $g.DrawArc($facePen, [float]($cx-9), [float]($cy-2), 18, 12, 0, 180)
    $facePen.Dispose()
}

function Show-Stars($g) {
    $brush = [System.Drawing.Brushes]::White
    foreach ($s in $script:Stars) {
        $g.FillEllipse($brush, [float]$s.X, [float]$s.Y, 2, 2)
    }
}

function Show-Clouds($g) {
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(160,255,255,255))
    foreach ($c in $script:Clouds) {
        $s = $c.Scale
        $g.FillEllipse($brush, [float]$c.X,            [float]$c.Y,            [float](40*$s), [float](24*$s))
        $g.FillEllipse($brush, [float]($c.X+18*$s),     [float]($c.Y-10*$s),    [float](46*$s), [float](28*$s))
        $g.FillEllipse($brush, [float]($c.X+40*$s),     [float]$c.Y,            [float](36*$s), [float](22*$s))
    }
    $brush.Dispose()
}

function New-RoundedRectPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc($x, $y, $r*2, $r*2, 180, 90)
    $path.AddArc($x+$w-$r*2, $y, $r*2, $r*2, 270, 90)
    $path.AddArc($x+$w-$r*2, $y+$h-$r*2, $r*2, $r*2, 0, 90)
    $path.AddArc($x, $y+$h-$r*2, $r*2, $r*2, 90, 90)
    $path.CloseFigure()
    return $path
}

function Show-Bubble($g) {
    if (-not $script:Bubble) { return }
    $gor = if ($script:Bubble.GorillaNum -eq 1) { $script:P1 } else { $script:P2 }
    $text = $script:Bubble.Text
    $font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $sz = $g.MeasureString($text, $font)
    $bw = [single]($sz.Width + 16); $bh = [single]($sz.Height + 8)
    $bx = [single]($gor.X - $bw/2)
    $by = [single]($gor.Y - 100 - $bh)
    $bx = [Math]::Max(4, [Math]::Min($CanvasW - $bw - 4, $bx))

    $path = New-RoundedRectPath $bx $by $bw $bh 8
    $bgBrush   = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, 2)
    $g.FillPath($bgBrush, $path)
    $g.DrawPath($borderPen, $path)

    $tailX = [Math]::Max($bx+10, [Math]::Min($bx+$bw-10, [single]$gor.X))
    $tailPts = @(
        [System.Drawing.PointF]::new($tailX-6, $by+$bh)
        [System.Drawing.PointF]::new($tailX+6, $by+$bh)
        [System.Drawing.PointF]::new([single]$gor.X, [single]($gor.Y-90))
    )
    $g.FillPolygon($bgBrush, $tailPts)
    $g.DrawLine($borderPen, $tailPts[0], $tailPts[2])
    $g.DrawLine($borderPen, $tailPts[1], $tailPts[2])

    $g.DrawString($text, $font, [System.Drawing.Brushes]::Black, [float]($bx+8), [float]($by+4))
    $bgBrush.Dispose(); $borderPen.Dispose(); $font.Dispose(); $path.Dispose()
}

function Show-Building($g, $b) {

    $rect  = [System.Drawing.RectangleF]::new([float]$b.X, [float]$b.Y, [float]$b.W, [float]$b.H)
    $light = Get-Shade $b.Color 1.22
    $dark  = Get-Shade $b.Color 0.6
    $lgb   = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect, $light, $dark, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
    $g.FillRectangle($lgb, $rect)
    $lgb.Dispose()

    # Architectural structure: floor bands, corner columns and occasional facade accents.
    $floorPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(34, 255, 255, 255), 1)
    for ($yy = $b.Y + 24; $yy -lt $GroundY; $yy += 25) {
        $g.DrawLine($floorPen, [float]($b.X + 3), [float]$yy, [float]($b.X + $b.W - 7), [float]$yy)
    }
    $floorPen.Dispose()
    $columnBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(42, 255, 255, 255))
    $g.FillRectangle($columnBrush, [float]($b.X + 3), [float]$b.Y, 3, [float]$b.H)
    if ($b.Accent) { $g.FillRectangle($columnBrush, [float]($b.X + $b.W * .48), [float]$b.Y, 3, [float]$b.H) }
    $columnBrush.Dispose()

    # A deeper shadow band down the right edge sells the sense of a corner /
    # the side face turning away from us.
    $shadowBand = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
    $g.FillRectangle($shadowBand, [float]($b.X + $b.W - 6), [float]$b.Y, 6, [float]$b.H)
    $shadowBand.Dispose()

    # A lighter roof cap band plus a bright top edge = light hitting the roof.
    $capBrush = [System.Drawing.SolidBrush]::new((Get-Shade $b.Color 1.4))
    $g.FillRectangle($capBrush, [float]$b.X, [float]$b.Y, [float]$b.W, 4)
    $capBrush.Dispose()
    $edgePen = [System.Drawing.Pen]::new((Get-Shade $b.Color 1.7), 2)
    $g.DrawLine($edgePen, [float]$b.X, [float]($b.Y + 1), [float]($b.X + $b.W), [float]($b.Y + 1))
    $edgePen.Dispose()

    # Rooftop silhouettes make every block distinct without changing collision geometry.
    $roofDark = [System.Drawing.SolidBrush]::new((Get-Shade $b.Color .48))
    switch ($b.Roof) {
        0 { # lift / utility room
            $rw = [Math]::Min(34, $b.W * .38); $rx = $b.X + $b.W * .18
            $g.FillRectangle($roofDark, [float]$rx, [float]($b.Y - 9), [float]$rw, 9)
        }
        1 { # water tank
            $cx = $b.X + $b.W * .62
            $g.FillRectangle($roofDark, [float]($cx-10), [float]($b.Y-11), 20, 9)
            $g.DrawLine([System.Drawing.Pens]::DimGray, [float]($cx-8), [float]($b.Y-2), [float]($cx-11), [float]$b.Y)
            $g.DrawLine([System.Drawing.Pens]::DimGray, [float]($cx+8), [float]($b.Y-2), [float]($cx+11), [float]$b.Y)
        }
        2 { # aerial and warning light
            $ax = $b.X + $b.W * .72
            $antenna = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(150,170,180), 1.5)
            $g.DrawLine($antenna, [float]$ax, [float]$b.Y, [float]$ax, [float]($b.Y-20)); $antenna.Dispose()
            $g.FillEllipse([System.Drawing.Brushes]::OrangeRed, [float]($ax-2), [float]($b.Y-22), 4, 4)
        }
    }
    $roofDark.Dispose()

    $litBrush  = [System.Drawing.SolidBrush]::new($WindowLit)
    $glowBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(70, 255, 235, 120))
    $darkBrush = [System.Drawing.SolidBrush]::new($WindowDark)
    $padX = 10; $padY = 13
    $cellW = [Math]::Max(1, [int](($b.W - $padX) / [Math]::Max(1,$b.Cols)))
    $cellH = [Math]::Max(1, [int](($b.H - $padY) / [Math]::Max(1,$b.Rows)))
    $winW = [Math]::Max(6, [Math]::Min(11, $cellW - 7)); $winH = [Math]::Max(8, [Math]::Min(14, $cellH - 8))
    for ($r = 0; $r -lt $b.Rows; $r++) {
        for ($c = 0; $c -lt $b.Cols; $c++) {
            $wx = $b.X + $padX/2 + $c * $cellW
            $wy = $b.Y + $padY + $r * $cellH
            if ($b.Lit[$r, $c]) {
                # soft halo behind lit windows so night scenes glow
                $g.FillRectangle($glowBrush, [float]($wx - 2), [float]($wy - 2), [float]($winW + 4), [float]($winH + 4))
                $g.FillRectangle($litBrush, [float]$wx, [float]$wy, [float]$winW, [float]$winH)
                if ($b.Style -eq 1) { $g.DrawLine([System.Drawing.Pens]::Goldenrod, [float]($wx+$winW/2), [float]$wy, [float]($wx+$winW/2), [float]($wy+$winH)) }
            } else {
                $g.FillRectangle($darkBrush, [float]$wx, [float]$wy, [float]$winW, [float]$winH)
            }
        }
    }
    $litBrush.Dispose(); $glowBrush.Dispose(); $darkBrush.Dispose()

    $pen = [System.Drawing.Pen]::new(([System.Drawing.Color]::FromArgb(120, 0, 0, 0)), 1)
    $g.DrawRectangle($pen, [float]$b.X, [float]$b.Y, [float]$b.W, [float]$b.H)
    $pen.Dispose()
}

function Show-Craters($g) {
    foreach ($cr in $script:Craters) {
        $col = Get-SkyColor $cr.Y
        $brush = [System.Drawing.SolidBrush]::new($col)
        $g.FillEllipse($brush, [float]($cr.X - $cr.R), [float]($cr.Y - $cr.R), [float]($cr.R*2), [float]($cr.R*2))
        $brush.Dispose()
        $pen = [System.Drawing.Pen]::new(([System.Drawing.Color]::FromArgb(60,30,10)), 2)
        $g.DrawArc($pen, [float]($cr.X - $cr.R), [float]($cr.Y - $cr.R), [float]($cr.R*2), [float]($cr.R*2), 20, 140)
        $pen.Dispose()
    }
}

function Show-Gorilla($g, [double]$fx, [double]$fy, [System.Drawing.Color]$color, [string]$pose, [int]$facing, [double]$animT = 0) {
    # Draw around the planted feet so the larger animal still stands exactly on its roof.
    $savedState = $g.Save()
    $gorillaScale = 1.28
    $g.TranslateTransform([float]$fx, [float]$fy)
    $g.ScaleTransform([float]$gorillaScale, [float]$gorillaScale)
    $g.TranslateTransform([float](-$fx), [float](-$fy))
    if ($pose -eq 'dance') {
        $bounce = -[Math]::Abs([Math]::Sin($animT * 9)) * 11
        $wiggle = [Math]::Sin($animT * 11) * 14
        $g.TranslateTransform([float]$fx, [float]($fy + $bounce))
        $g.RotateTransform([float]$wiggle)
        $g.TranslateTransform([float](-$fx), [float](-($fy + $bounce)))
    } elseif ($pose -eq 'defeated') {
        $g.TranslateTransform([float]$fx, [float]$fy)
        $g.RotateTransform([float](68 * $facing))
        $g.TranslateTransform([float](-$fx), [float](-$fy))
    }

    $legH      = 14
    $torsoTop  = $fy - $legH - 30           # fy - 44
    $shoulderY = $torsoTop + 6              # fy - 38
    $headCx    = $fx
    $headCy    = $torsoTop - 11 + 4         # fy - 51

    # ---- soft contact shadow on the rooftop (skip mid-tumble) ----
    if ($pose -ne 'defeated') {
        $shadow = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(60, 0, 0, 0))
        $g.FillEllipse($shadow, [float]($fx - 20), [float]($fy - 4), 40, 9)
        $shadow.Dispose()
    }

    # ---- legs + feet ----
    foreach ($side in @(-1, 1)) {
        $lx = $fx + $side * 9
        Add-ShadedEllipse $g $lx ($fy - $legH / 2) 7 ($legH / 2 + 2) $color
        $footBrush = [System.Drawing.SolidBrush]::new((Get-Shade $color 0.8))
        $g.FillEllipse($footBrush, [float]($lx - 8), [float]($fy - 4), 16, 7)
        $footBrush.Dispose()
    }

    Add-ShadedEllipse $g $fx ($torsoTop + 15) 21 18 $color
    $belly = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55, 255, 255, 255))
    $g.FillEllipse($belly, [float]($fx - 9), [float]($torsoTop + 10), 18, 16)
    $belly.Dispose()

    Add-ShadedEllipse $g ($fx - 13) ($shoulderY + 2) 9 8 $color
    Add-ShadedEllipse $g ($fx + 13) ($shoulderY + 2) 9 8 $color

    $armPen = [System.Drawing.Pen]::new((Get-Shade $color 0.92), 11)
    $armPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $armPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

    if ($pose -eq 'throw') {
        $backX  = $fx - (14 * $facing)
        $frontX = $fx + (20 * $facing)
        $g.DrawLine($armPen, [float]($fx - 12*$facing), [float]$shoulderY, [float]$backX,  [float]($shoulderY + 8))
        $g.DrawLine($armPen, [float]($fx + 12*$facing), [float]$shoulderY, [float]$frontX, [float]($headCy - 14))
        Add-ShadedEllipse $g $frontX ($headCy - 14) 6 6 $color
        Add-ShadedEllipse $g $backX  ($shoulderY + 8) 6 6 $color
    } elseif ($pose -eq 'dance') {
        $lift = [Math]::Sin($animT * 11) * 6
        $g.DrawLine($armPen, [float]($fx - 15), [float]$shoulderY, [float]($fx - 19), [float]($headCy - 10 - $lift))
        $g.DrawLine($armPen, [float]($fx + 15), [float]$shoulderY, [float]($fx + 19), [float]($headCy - 10 + $lift))
        Add-ShadedEllipse $g ($fx - 19) ($headCy - 10 - $lift) 6 6 $color
        Add-ShadedEllipse $g ($fx + 19) ($headCy - 10 + $lift) 6 6 $color
    } elseif ($pose -eq 'defeated') {
        $g.DrawLine($armPen, [float]($fx - 15), [float]$shoulderY, [float]($fx - 20), [float]($shoulderY + 10))
        $g.DrawLine($armPen, [float]($fx + 15), [float]$shoulderY, [float]($fx + 20), [float]($shoulderY + 10))
        Add-ShadedEllipse $g ($fx - 20) ($shoulderY + 10) 6 6 $color
        Add-ShadedEllipse $g ($fx + 20) ($shoulderY + 10) 6 6 $color
    } else {
        # resting knuckle-walk stance: long ape arms hanging to the ground
        $g.DrawLine($armPen, [float]($fx - 15), [float]$shoulderY, [float]($fx - 19), [float]($fy - 6))
        $g.DrawLine($armPen, [float]($fx + 15), [float]$shoulderY, [float]($fx + 19), [float]($fy - 6))
        Add-ShadedEllipse $g ($fx - 19) ($fy - 6) 6 5 $color
        Add-ShadedEllipse $g ($fx + 19) ($fy - 6) 6 5 $color
    }
    $armPen.Dispose()

    Add-ShadedEllipse $g ($headCx - 11) $headCy 5 6 $color
    Add-ShadedEllipse $g ($headCx + 11) $headCy 5 6 $color
    Add-ShadedEllipse $g $headCx $headCy 11 11 $color

    $muzzle = [System.Drawing.SolidBrush]::new((Get-Shade $color 1.15))
    $g.FillEllipse($muzzle, [float]($headCx - 7), [float]($headCy + 1), 14, 10)
    $muzzle.Dispose()

    $brow = [System.Drawing.SolidBrush]::new((Get-Shade $color 0.68))
    $g.FillEllipse($brow, [float]($headCx - 9), [float]($headCy - 6), 18, 7)
    $brow.Dispose()

    if ($pose -eq 'defeated') {
        $eyePen = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, 1.8)
        $g.DrawLine($eyePen, [float]($headCx-7), [float]($headCy-3), [float]($headCx-3), [float]($headCy+1))
        $g.DrawLine($eyePen, [float]($headCx-3), [float]($headCy-3), [float]($headCx-7), [float]($headCy+1))
        $g.DrawLine($eyePen, [float]($headCx+1), [float]($headCy-3), [float]($headCx+5), [float]($headCy+1))
        $g.DrawLine($eyePen, [float]($headCx+5), [float]($headCy-3), [float]($headCx+1), [float]($headCy+1))
        $eyePen.Dispose()
    } else {
        $g.FillEllipse([System.Drawing.Brushes]::White, [float]($headCx - 6), [float]($headCy - 3), 5, 5)
        $g.FillEllipse([System.Drawing.Brushes]::White, [float]($headCx + 1), [float]($headCy - 3), 5, 5)
        $g.FillEllipse([System.Drawing.Brushes]::Black, [float]($headCx - 4), [float]($headCy - 2), 3, 3)
        $g.FillEllipse([System.Drawing.Brushes]::Black, [float]($headCx + 3), [float]($headCy - 2), 3, 3)
    }

    $g.FillEllipse([System.Drawing.Brushes]::Black, [float]($headCx - 3), [float]($headCy + 4), 2, 2)
    $g.FillEllipse([System.Drawing.Brushes]::Black, [float]($headCx + 1), [float]($headCy + 4), 2, 2)

    # Mouth, chin and a small eye catchlight add expression at the larger scale.
    $mouthPen = [System.Drawing.Pen]::new((Get-Shade $color .42), 1.4)
    $g.DrawArc($mouthPen, [float]($headCx-5), [float]($headCy+4), 10, 6, 12, 156)
    $mouthPen.Dispose()
    if ($pose -ne 'defeated') {
        $g.FillEllipse([System.Drawing.Brushes]::White, [float]($headCx-3.7), [float]($headCy-1.8), 1, 1)
        $g.FillEllipse([System.Drawing.Brushes]::White, [float]($headCx+3.3), [float]($headCy-1.8), 1, 1)
    }

    $g.Restore($savedState)
}

function Show-Banana($g, [double]$x, [double]$y, [double]$angleRad) {
    $g.TranslateTransform([float]$x, [float]$y)
    $g.RotateTransform([float]($angleRad * 180 / [Math]::PI))
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc(-6.0, -3.0, 12.0, 8.0, 200, 140)
    $path.AddArc(-5.0, -1.0, 10.0, 6.0, 340, -140)
    $path.CloseFigure()
    $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 224, 60))
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
    $g.ResetTransform()
}

function Show-Trail($g) {
    if (-not $script:Banana) { return }
    $pts = $script:Banana.Trail
    for ($i = 0; $i -lt $pts.Count; $i++) {
        $alpha = [int](255 * (($i + 1) / [double]$pts.Count) * 0.5)
        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($alpha, 255, 230, 120))
        $g.FillEllipse($brush, [float]($pts[$i].X - 2), [float]($pts[$i].Y - 2), 4, 4)
        $brush.Dispose()
    }
}

function Show-PlaneBlast($g, [double]$x, [double]$y, [double]$radius) {
    $r = [Math]::Max(2, $radius)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddEllipse([float]($x-$r), [float]($y-$r), [float]($r*2), [float]($r*2))
    $fire = [System.Drawing.Drawing2D.PathGradientBrush]::new($path)
    $fire.CenterColor = [System.Drawing.Color]::FromArgb(255,255,245,190)
    $fire.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(20,210,35,5))
    $g.FillPath($fire, $path)
    $fire.Dispose(); $path.Dispose()
    $ring = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(190,255,115,20), 4)
    $g.DrawEllipse($ring, [float]($x-$r*1.12), [float]($y-$r*1.12), [float]($r*2.24), [float]($r*2.24))
    $ring.Dispose()
}

function Show-CommercialPlane($g) {
    if (-not $script:Plane) { return }
    $p = $script:Plane
    if ($p.State -in @('Exploding','Crashed')) {
        Show-PlaneBlast $g $p.X $p.Y $p.BlastRadius
    }
    if ($p.State -eq 'Crashed') { return }

    $saved = $g.Save()
    $g.TranslateTransform([float]$p.X, [float]$p.Y)
    if ($p.State -eq 'Falling') { $g.RotateTransform([float]$p.Rotation) }
    if ($p.Direction -lt 0) { $g.ScaleTransform(-1, 1) }

    # A proper side-view twin-engine airliner. The nose points to +X; mirroring
    # the whole drawing handles westbound flights without reversing its anatomy.
    $outline = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(95,108,122), 1.35)
    $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(246,248,250))
    $shadowWhite = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(211,218,226))
    $dark = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(42,66,86))

    # Far wing: broad at the fuselage, correctly swept backward toward its tip.
    $g.FillPolygon($shadowWhite, @(
        [System.Drawing.PointF]::new(22,-2), [System.Drawing.PointF]::new(-18,-30),
        [System.Drawing.PointF]::new(-31,-28), [System.Drawing.PointF]::new(-5,2)))

    # Horizontal tailplane and tall vertical stabilizer sit at the rear.
    $g.FillPolygon($shadowWhite, @(
        [System.Drawing.PointF]::new(-39,-2), [System.Drawing.PointF]::new(-55,-14),
        [System.Drawing.PointF]::new(-61,-12), [System.Drawing.PointF]::new(-48,3)))
    $g.FillPolygon($white, @(
        [System.Drawing.PointF]::new(-48,-5), [System.Drawing.PointF]::new(-42,-32),
        [System.Drawing.PointF]::new(-30,-30), [System.Drawing.PointF]::new(-25,-3)))
    $g.FillPolygon([System.Drawing.Brushes]::Crimson, @(
        [System.Drawing.PointF]::new(-46,-7), [System.Drawing.PointF]::new(-41,-29),
        [System.Drawing.PointF]::new(-35,-28), [System.Drawing.PointF]::new(-35,-5)))

    # Long tapered fuselage with a rounded airliner nose.
    $bodyPath = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $bodyPath.AddBezier(-55,-8, -28,-12, 34,-12, 57,-3)
    $bodyPath.AddBezier(57,-3, 64,0, 57,6, 45,9)
    $bodyPath.AddBezier(45,9, 10,13, -33,11, -55,6)
    $bodyPath.CloseFigure()
    $bodyRect = [System.Drawing.RectangleF]::new(-58,-12,120,24)
    $bodyFill = [System.Drawing.Drawing2D.LinearGradientBrush]::new($bodyRect,
        [System.Drawing.Color]::White, [System.Drawing.Color]::FromArgb(194,205,216),
        [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $g.FillPath($bodyFill,$bodyPath); $g.DrawPath($outline,$bodyPath)

    # Near wing is swept toward the tail, matching a modern narrow-body jet.
    [System.Drawing.PointF[]]$nearWing = @(
        [System.Drawing.PointF]::new(21,3), [System.Drawing.PointF]::new(-16,31),
        [System.Drawing.PointF]::new(-32,29), [System.Drawing.PointF]::new(-3,1))
    $g.FillPolygon($white,$nearWing); $g.DrawPolygon($outline,$nearWing)

    # Two under-wing turbofan nacelles with dark intakes and silver highlights.
    foreach ($engineX in @(-8,13)) {
        $g.FillEllipse($shadowWhite,[float]($engineX-8),13.0,18.0,12.0)
        $g.DrawEllipse($outline,[float]($engineX-8),13.0,18.0,12.0)
        $g.FillEllipse($dark,[float]($engineX+4),15.0,5.0,7.0)
        $g.FillEllipse([System.Drawing.Brushes]::Silver,[float]($engineX+5),16.0,1.5,4.5)
    }

    # Cockpit windshield, passenger windows, door and a restrained cheatline.
    $g.FillPolygon($dark, @(
        [System.Drawing.PointF]::new(43,-7), [System.Drawing.PointF]::new(55,-3),
        [System.Drawing.PointF]::new(47,0), [System.Drawing.PointF]::new(38,-1)))
    $stripe = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(80,118,158), 1.4)
    $g.DrawLine($stripe,-34.0,2.0,44.0,3.0); $stripe.Dispose()
    for ($wx=-29; $wx -le 34; $wx+=7) { $g.FillEllipse($dark,[float]$wx,-5.0,3.5,3.0) }
    $doorPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(120,130,140),1)
    $g.DrawRectangle($doorPen,30.0,-6.0,6.0,11.0); $doorPen.Dispose()

    $bodyFill.Dispose(); $bodyPath.Dispose(); $white.Dispose(); $shadowWhite.Dispose(); $dark.Dispose(); $outline.Dispose()
    $g.Restore($saved)
}

function Show-Explosion($g) {
    if (-not $script:Explosion) { return }
    $e = $script:Explosion
    $r    = [Math]::Max(1.0, $e.Radius)
    $frac = [Math]::Min(1.0, $r / $e.Target)   # 0..1 animation progress

    $ringR   = $r * 1.15
    $ringA   = [int][Math]::Max(0, 200 * (1 - $frac))
    $ringPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb($ringA, 255, 220, 150), [single]([Math]::Max(1.5, 4 * (1 - $frac) + 1)))
    $g.DrawEllipse($ringPen, [float]($e.X - $ringR), [float]($e.Y - $ringR), [float]($ringR * 2), [float]($ringR * 2))
    $ringPen.Dispose()

    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddEllipse([float]($e.X - $r), [float]($e.Y - $r), [float]($r * 2), [float]($r * 2))
    $pgb = [System.Drawing.Drawing2D.PathGradientBrush]::new($path)
    $pgb.CenterColor    = [System.Drawing.Color]::FromArgb(255, 255, 245, 200)
    $pgb.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, 200, 40, 10))
    $pgb.FocusScales    = [System.Drawing.PointF]::new(0.35, 0.35)
    $g.FillPath($pgb, $path)
    $pgb.Dispose(); $path.Dispose()

    $coreR = $r * 0.5
    $core  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(235, 255, 230, 120))
    $g.FillEllipse($core, [float]($e.X - $coreR), [float]($e.Y - $coreR), [float]($coreR * 2), [float]($coreR * 2))
    $core.Dispose()

    $sparkA   = [int][Math]::Max(0, 220 * (1 - $frac * 0.5))
    $sparkPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb($sparkA, 255, 240, 150), 2)
    for ($i = 0; $i -lt 10; $i++) {
        $a  = $i * (360.0 / 10) * [Math]::PI / 180 + $e.X * 0.01
        $r1 = $r * 0.7
        $r2 = $r * (1.15 + 0.18 * [Math]::Sin($i * 2.7))
        $g.DrawLine($sparkPen,
            [float]($e.X + [Math]::Cos($a) * $r1), [float]($e.Y + [Math]::Sin($a) * $r1),
            [float]($e.X + [Math]::Cos($a) * $r2), [float]($e.Y + [Math]::Sin($a) * $r2))
    }
    $sparkPen.Dispose()
}

function Show-Hud($g) {
    $font  = [System.Drawing.Font]::new('Consolas', 13, [System.Drawing.FontStyle]::Bold)
    $g.DrawString("Player 1  Score: $($script:P1.Score)", $font, [System.Drawing.Brushes]::OrangeRed, 12, 10)
    $sz = $g.MeasureString("Player 2  Score: $($script:P2.Score)", $font)
    $g.DrawString("Player 2  Score: $($script:P2.Score)", $font, [System.Drawing.Brushes]::DeepSkyBlue, [float]($CanvasW - $sz.Width - 12), 10)

    if ($script:Message) {
        $msz = $g.MeasureString($script:Message, $font)
        $bx = ($CanvasW - $msz.Width)/2 - 10
        $bg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(180,0,0,0))
        $g.FillRectangle($bg, [float]$bx, 40, [float]($msz.Width+20), [float]($msz.Height+10))
        $bg.Dispose()
        $g.DrawString($script:Message, $font, [System.Drawing.Brushes]::White, [float]($bx+10), 45)
    }
    $font.Dispose()
}

function Show-DayNightIcon($g, $rect, [bool]$isDay) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $cx = 18.0; $cy = 18.0; $r = 8.0

    if ($isDay) {
        $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 220, 60), 2)
        for ($i = 0; $i -lt 8; $i++) {
            $ang = $i * (360.0 / 8) * [Math]::PI / 180
            $x1 = $cx + [Math]::Cos($ang) * ($r + 3)
            $y1 = $cy + [Math]::Sin($ang) * ($r + 3)
            $x2 = $cx + [Math]::Cos($ang) * ($r + 8)
            $y2 = $cy + [Math]::Sin($ang) * ($r + 8)
            $g.DrawLine($pen, [float]$x1, [float]$y1, [float]$x2, [float]$y2)
        }
        $pen.Dispose()
        $sunBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 225, 70))
        $g.FillEllipse($sunBrush, [float]($cx - $r), [float]($cy - $r), [float]($r*2), [float]($r*2))
        $sunBrush.Dispose()
    } else {
        $moonBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(235, 235, 245))
        $g.FillEllipse($moonBrush, [float]($cx - $r), [float]($cy - $r), [float]($r*2), [float]($r*2))
        $moonBrush.Dispose()
        $craterBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55, 190, 190, 200))
        $g.FillEllipse($craterBrush, [float]($cx-5), [float]($cy-6), 3, 3)
        $g.FillEllipse($craterBrush, [float]($cx+2), [float]($cy+1), 2, 2)
        $craterBrush.Dispose()
    }
}

function Show-SpeakerIcon($g, $rect, [bool]$on) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $whiteBrush = [System.Drawing.Brushes]::White

    $g.FillRectangle($whiteBrush, 9.0, 12.0, 5.0, 10.0)
    $cone = @(
        [System.Drawing.PointF]::new(14, 12)
        [System.Drawing.PointF]::new(22, 6)
        [System.Drawing.PointF]::new(22, 28)
        [System.Drawing.PointF]::new(14, 22)
    )
    $g.FillPolygon($whiteBrush, $cone)

    if ($on) {
        $wavePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2)
        $g.DrawArc($wavePen, 23.0, 11.0, 6.0, 12.0, -50, 100)
        $g.DrawArc($wavePen, 26.0, 7.0, 8.0, 20.0, -50, 100)
        $wavePen.Dispose()
    } else {
        $mutePen = [System.Drawing.Pen]::new([System.Drawing.Color]::OrangeRed, 3)
        $g.DrawLine($mutePen, 6.0, 28.0, 30.0, 6.0)
        $mutePen.Dispose()
    }
}

function Invoke-FrameRender($g) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    for ($y = 0; $y -lt $CanvasH; $y += 4) {
        $brush = [System.Drawing.SolidBrush]::new((Get-SkyColor $y))
        $g.FillRectangle($brush, 0, [float]$y, [float]$CanvasW, 5)
        $brush.Dispose()
    }
    if ($script:IsDaytime) { Show-Sun $g } else { Show-Stars $g; Show-Moon $g }
    Show-Clouds $g
    Show-CommercialPlane $g
    foreach ($b in $script:Buildings) { Show-Building $g $b }
    Show-Craters $g

    Show-Gorilla $g $script:P1.X $script:P1.Y $script:P1.Color $script:P1.Pose 1 $script:AnimClock
    Show-Gorilla $g $script:P2.X $script:P2.Y $script:P2.Color $script:P2.Pose -1 $script:AnimClock
    Show-Bubble $g

    Show-Trail $g
    if ($script:Banana -and $script:State -eq 'Flying') {
        $ang = [Math]::Atan2($script:Banana.VY, $script:Banana.VX)
        Show-Banana $g $script:Banana.X $script:Banana.Y $ang
    }
    Show-Explosion $g
    Show-Hud $g
}

# ---------------------------------------------------------------------------
# FORM / CONTROLS
# ---------------------------------------------------------------------------

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "GorillazAtWar"
$script:form.ClientSize = [System.Drawing.Size]::new($CanvasW, $CanvasH + 196)
$script:form.FormBorderStyle = 'FixedSingle'
$script:form.MaximizeBox = $false
$script:form.StartPosition = 'CenterScreen'
$script:form.BackColor = [System.Drawing.Color]::FromArgb(25,25,25)

$script:canvas = New-Object System.Windows.Forms.Panel
Enable-DoubleBuffering $script:canvas
$script:canvas.Size = [System.Drawing.Size]::new($CanvasW, $CanvasH)
$script:canvas.Location = [System.Drawing.Point]::new(0, 0)
$script:canvas.Add_Paint({ param($s, $e) Invoke-FrameRender $e.Graphics })
$script:form.Controls.Add($script:canvas)

$script:soundBtn = New-Object System.Windows.Forms.Panel
Enable-DoubleBuffering $script:soundBtn
$script:soundBtn.Size = [System.Drawing.Size]::new(36, 36)
$script:soundBtn.Location = [System.Drawing.Point]::new($CanvasW - 46, 40)
$script:soundBtn.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 65)
$script:soundBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:soundBtn.Add_Paint({ param($s, $e) Show-SpeakerIcon $e.Graphics $s.ClientRectangle $script:SoundOn })
$script:soundBtn.Add_Click({
    $script:SoundOn = -not $script:SoundOn
    $script:soundBtn.Invalidate()
})
$script:canvas.Controls.Add($script:soundBtn)

$script:dayNightBtn = New-Object System.Windows.Forms.Panel
Enable-DoubleBuffering $script:dayNightBtn
$script:dayNightBtn.Size = [System.Drawing.Size]::new(36, 36)
$script:dayNightBtn.Location = [System.Drawing.Point]::new($CanvasW - 46, 80)
$script:dayNightBtn.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 65)
$script:dayNightBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:dayNightBtn.Add_Paint({ param($s, $e) Show-DayNightIcon $e.Graphics $s.ClientRectangle $script:IsDaytime })
$script:dayNightBtn.Add_Click({
    $script:IsDaytime = -not $script:IsDaytime
    $script:dayNightBtn.Invalidate()
    $script:canvas.Invalidate()
})
$script:canvas.Controls.Add($script:dayNightBtn)

function New-ControlGroup([string]$title, [int]$x) {
    $panel = New-Object System.Windows.Forms.GroupBox
    $panel.Text = $title
    $panel.ForeColor = [System.Drawing.Color]::White
    $panel.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $panel.Size = [System.Drawing.Size]::new(340, 120)
    $panel.Location = [System.Drawing.Point]::new($x, $CanvasH + 5)

    $ctrlFont = [System.Drawing.Font]::new('Segoe UI', 10)

    $lblA = New-Object System.Windows.Forms.Label
    $lblA.Text = "Angle (0-90):"; $lblA.ForeColor = 'White'; $lblA.Font = $ctrlFont
    $lblA.Location = [System.Drawing.Point]::new(10, 27); $lblA.AutoSize = $true
    $numA = New-Object System.Windows.Forms.NumericUpDown
    $numA.Minimum = 0; $numA.Maximum = 90; $numA.Value = 45; $numA.Font = $ctrlFont
    $numA.Location = [System.Drawing.Point]::new(130, 24); $numA.Width = 65

    $lblP = New-Object System.Windows.Forms.Label
    $lblP.Text = "Power (1-100):"; $lblP.ForeColor = 'White'; $lblP.Font = $ctrlFont
    $lblP.Location = [System.Drawing.Point]::new(10, 60); $lblP.AutoSize = $true
    $numP = New-Object System.Windows.Forms.NumericUpDown
    $numP.Minimum = 1; $numP.Maximum = 100; $numP.Value = 50; $numP.Font = $ctrlFont
    $numP.Location = [System.Drawing.Point]::new(130, 57); $numP.Width = 65

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "THROW"
    $btn.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Location = [System.Drawing.Point]::new(210, 30); $btn.Size = [System.Drawing.Size]::new(115, 48)

    $panel.Controls.AddRange(@($lblA, $numA, $lblP, $numP, $btn))
    return [pscustomobject]@{ Panel = $panel; Angle = $numA; Power = $numP; Button = $btn }
}

$script:g1 = New-ControlGroup "Player 1" 10
$script:g2 = New-ControlGroup "Player 2" ($CanvasW - 350)
$script:form.Controls.Add($script:g1.Panel)
$script:form.Controls.Add($script:g2.Panel)

$script:cpuCheck = New-Object System.Windows.Forms.CheckBox
$script:cpuCheck.Text = "CPU Opponent"
$script:cpuCheck.ForeColor = [System.Drawing.Color]::White
$script:cpuCheck.Font = [System.Drawing.Font]::new('Segoe UI', 10)
$script:cpuCheck.AutoSize = $true
$script:cpuCheck.Location = [System.Drawing.Point]::new(10, 95)
$script:g2.Panel.Controls.Add($script:cpuCheck)
$script:cpuCheck.Add_CheckedChanged({
    $script:VsCpu = $script:cpuCheck.Checked
    Update-Hud
})

$script:newGameBtn = New-Object System.Windows.Forms.Button
$script:newGameBtn.Text = "New Game"
$script:newGameBtn.ForeColor = [System.Drawing.Color]::White
$script:newGameBtn.Font = [System.Drawing.Font]::new('Segoe UI', 13.2, [System.Drawing.FontStyle]::Bold)
$script:newGameBtn.Location = [System.Drawing.Point]::new(($CanvasW/2 - 78), $CanvasH + 8)
$script:newGameBtn.Size = [System.Drawing.Size]::new(156, 36)
$script:form.Controls.Add($script:newGameBtn)

$script:speedTitle = New-Object System.Windows.Forms.Label
$script:speedTitle.Text = "Game Speed"
$script:speedTitle.ForeColor = [System.Drawing.Color]::White
$script:speedTitle.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$script:speedTitle.TextAlign = 'MiddleCenter'
$script:speedTitle.Location = [System.Drawing.Point]::new(($CanvasW/2 - 100), $CanvasH + 48)
$script:speedTitle.Size = [System.Drawing.Size]::new(200, 18)
$script:form.Controls.Add($script:speedTitle)

$script:speedSlider = New-Object System.Windows.Forms.TrackBar
$script:speedSlider.Minimum = 0
$script:speedSlider.Maximum = 2
$script:speedSlider.Value = 1
$script:speedSlider.TickFrequency = 1
$script:speedSlider.TickStyle = 'Both'
$script:speedSlider.LargeChange = 1
$script:speedSlider.SmallChange = 1
$script:speedSlider.Location = [System.Drawing.Point]::new(($CanvasW/2 - 90), $CanvasH + 64)
$script:speedSlider.Size = [System.Drawing.Size]::new(180, 40)
$script:form.Controls.Add($script:speedSlider)

$script:speedLabels = New-Object System.Windows.Forms.Label
$script:speedLabels.Text = "50%" + (" " * 15) + "100%" + (" " * 13) + "200%"
$script:speedLabels.ForeColor = [System.Drawing.Color]::Gray
$script:speedLabels.Font = [System.Drawing.Font]::new('Segoe UI', 8.5)
$script:speedLabels.Location = [System.Drawing.Point]::new(($CanvasW/2 - 100), $CanvasH + 106)
$script:speedLabels.Size = [System.Drawing.Size]::new(220, 16)
$script:form.Controls.Add($script:speedLabels)

$script:speedSelectedLabel = New-Object System.Windows.Forms.Label
$script:speedSelectedLabel.ForeColor = [System.Drawing.Color]::Yellow
$script:speedSelectedLabel.Font = [System.Drawing.Font]::new('Segoe UI', 8.5, [System.Drawing.FontStyle]::Italic)
$script:speedSelectedLabel.TextAlign = 'MiddleCenter'
$script:speedSelectedLabel.Location = [System.Drawing.Point]::new(($CanvasW/2 - 100), $CanvasH + 124)
$script:speedSelectedLabel.Size = [System.Drawing.Size]::new(200, 16)
$script:form.Controls.Add($script:speedSelectedLabel)

function Update-SpeedLabel {
    $name = switch ($script:speedSlider.Value) {
        0 { "Selected: 50% faster (1.5x)" }
        1 { "Selected: 100% faster (2x)" }
        2 { "Selected: 200% faster (4x)" }
    }
    $script:speedSelectedLabel.Text = $name
}

$script:speedSlider.Add_ValueChanged({
    $script:GameSpeed = switch ($script:speedSlider.Value) {
        0 { 1.5 }
        1 { 2.0 }
        2 { 4.0 }
    }
    Update-SpeedLabel
})
$script:GameSpeed = switch ($script:speedSlider.Value) { 0 {1.5} 1 {2.0} 2 {4.0} }
Update-SpeedLabel

$script:aboutBtn = New-Object System.Windows.Forms.Button
$script:aboutBtn.Text = "About"
$script:aboutBtn.ForeColor = [System.Drawing.Color]::White
$script:aboutBtn.Font = [System.Drawing.Font]::new('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$script:aboutBtn.Location = [System.Drawing.Point]::new(($CanvasW/2 - 50), $CanvasH + 150)
$script:aboutBtn.Size = [System.Drawing.Size]::new(100, 28)
$script:form.Controls.Add($script:aboutBtn)

function Show-AboutDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "About GorillazAtWar"
    $dlg.Size = [System.Drawing.Size]::new(540, 500)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)

    $rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb.ReadOnly = $true
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
    $rtb.ForeColor = [System.Drawing.Color]::White
    $rtb.BorderStyle = 'None'
    $rtb.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $rtb.Location = [System.Drawing.Point]::new(15, 15)
    $rtb.Size = [System.Drawing.Size]::new(495, 400)
    $rtb.Text = @"
GorillazAtWar

Author: Michael DALLA RIVA
Blog : https://lafrenchaieti.com
Version: 1.1
Date : 12-July-2026

Originally inspired by the concept of the original QBasic Gorillas
game, which shipped as a sample program with MS-DOS 5.0 (1991) and
QBasic. Its exact original authorship is unclear - some sources credit
IBM, others Microsoft - and the information available online is
conflicting, so no definitive original-author credit can be given here.
No original QBasic source code is included or reproduced; this is an
independent, from-scratch reimplementation written in PowerShell 7
using Windows Forms and GDI+ for rendering.
Update 1.1 : Improved the graphics + Added plane

--------------------------------------------------------------------
MIT License

Copyright (c) 2026 Michael DALLA RIVA

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--------------------------------------------------------------------

Free and open source. Fork it, modify it, ship it - just keep the
license notice attached.
"@
    $dlg.Controls.Add($rtb)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = "Close"
    $closeBtn.ForeColor = [System.Drawing.Color]::White
    $closeBtn.Location = [System.Drawing.Point]::new(220, 425)
    $closeBtn.Size = [System.Drawing.Size]::new(90, 28)
    $closeBtn.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($closeBtn)
    $dlg.AcceptButton = $closeBtn

    $dlg.ShowDialog($script:form) | Out-Null
    $dlg.Dispose()
}

$script:aboutBtn.Add_Click({ Show-AboutDialog })

function Start-Throw([pscustomobject]$shooter, [pscustomobject]$target, [double]$angleDeg, [double]$power) {
    $facing = if ($target.X -gt $shooter.X) { 1 } else { -1 }
    $rad = $angleDeg * [Math]::PI / 180.0
    $speed = $power * 0.34
    $shooter.Pose = 'throw'
    Invoke-Sound 'throw'

    $script:Banana = [pscustomobject]@{
        X = $shooter.X + (18 * $facing)
        Y = $shooter.Y - 20
        VX = [Math]::Cos($rad) * $speed * $facing
        VY = -[Math]::Sin($rad) * $speed
        Trail = New-Object System.Collections.Generic.List[object]
        Shooter = $shooter
        Target = $target
    }
    $script:State = 'Flying'
    Update-Hud
}

function Get-CpuThrow {
    $shooter = $script:P2; $target = $script:P1
    $dx      = $target.X - $shooter.X
    $dist    = [Math]::Abs($dx)
    $facing  = if ($dx -gt 0) { 1 } else { -1 }
    $heightDiff = $shooter.Y - $target.Y     # +ve = shooter standing higher than target
    $mem = $script:CpuMemory

    if ($mem.Angle -le 0) {
        $a  = 50 + ($heightDiff * 0.03)          # lob a little steeper when firing down onto a lower foe
        $a += -($script:Wind * $facing) * 0.20   # steeper into a headwind so it isn't blown short
        $mem.Angle = [Math]::Max(35, [Math]::Min(68, $a))
    }
    $angle = $mem.Angle

    if (-not $mem.HasShot) {

        $g     = 0.32
        $rad   = $angle * [Math]::PI / 180.0
        $sin2  = [Math]::Max(0.2, [Math]::Sin(2 * $rad))
        $vNeed = [Math]::Sqrt(($dist * $g) / $sin2)
        $power = ($vNeed / 0.34) * 0.78
        $power += -($script:Wind * $facing) * 0.35
        $power = [Math]::Max(20, [Math]::Min(95, $power))
    }
    else {

        $landedDist = ($mem.LandX - $shooter.X) * $facing
        $err        = $dist - $landedDist         # +ve = fell short, -ve = overshot
        $lastPower  = $mem.LastPower

        if ($err -gt 0) {
            # short -> that power is a lower bound on what's needed
            if ($null -eq $mem.LoPower -or $lastPower -gt $mem.LoPower) {
                $mem.LoPower = $lastPower; $mem.LoDist = $landedDist
            }
        } else {
            # long -> that power is an upper bound
            if ($null -eq $mem.HiPower -or $lastPower -lt $mem.HiPower) {
                $mem.HiPower = $lastPower; $mem.HiDist = $landedDist
            }
        }

        if (($null -ne $mem.LoPower) -and ($null -ne $mem.HiPower)) {

            $span = $mem.HiDist - $mem.LoDist
            if ([Math]::Abs($span) -lt 1) {
                $power = ($mem.LoPower + $mem.HiPower) / 2
            } else {
                $frac  = ($dist - $mem.LoDist) / $span
                $frac  = [Math]::Max(0.05, [Math]::Min(0.95, $frac))
                $power = $mem.LoPower + ($mem.HiPower - $mem.LoPower) * $frac
            }
        }
        elseif ($null -ne $mem.LoPower) {

            $step  = [Math]::Min(16, 6 + [Math]::Abs($err) * 0.05)
            $power = $mem.LoPower + $step
        }
        else {
            # Only ever overshot. Step DOWN, likewise capped.
            $step  = [Math]::Min(16, 6 + [Math]::Abs($err) * 0.05)
            $power = $mem.HiPower - $step
        }

        # Stuck at max power and STILL short? A building is probably blocking the
        # line - lob steeper next time and restart the power search from there.
        if ($power -ge 99 -and ($null -eq $mem.HiPower)) {
            $mem.Angle   = [Math]::Min(75, $mem.Angle + 6)
            $mem.LoPower = $null
            $power       = 70
        }
        $angle = $mem.Angle
    }


    $bracketed = ($null -ne $mem.LoPower) -and ($null -ne $mem.HiPower)
    # >>> DIFFICULTY DIAL <<< These two numbers are the CPU's aim spread, in
    # power units. First = wobble once it has you bracketed (lower = deadlier);
    # second = wobble while still ranging in. Raise BOTH to make the CPU easier
    # (e.g. 2.5 / 5.0 for a gentler game), lower BOTH to make it more brutal
    # (e.g. 0.8 / 2.5). Set the first to 0 and it becomes a near-perfect sniper.
    $jit = if ($bracketed) { 1.5 } else { 4.0 }
    $power += ($script:Rng.NextDouble() * 2 - 1) * $jit
    $angle += ($script:Rng.NextDouble() * 2 - 1) * ($jit * 0.4)
    $mem.Shots++

    $angle = [Math]::Max(15, [Math]::Min(75, $angle))
    $power = [Math]::Max(15, [Math]::Min(100, $power))
    return @($angle, $power)
}

function Start-CpuThinking {
    $script:CpuPending = $true
    $script:CpuTimer.Start()
}

function Start-Explosion([double]$x, [double]$y, [pscustomobject]$shooter) {
    $script:Explosion = [pscustomobject]@{
        X = $x; Y = $y; Radius = 2
        Shooter = $shooter        # who threw it - used to resolve the outcome by splash
        Target  = 48              # peak fireball radius (visual)
        CraterR = 40              # terrain destroyed
        KillR   = 52              # splash radius that eliminates a gorilla near the blast
        Step    = 5.0             # growth per frame (also scaled by GameSpeed in the loop)
    }
    $script:State = 'Exploding'
    Invoke-Sound 'explode'
}

function Complete-Turn {
    $script:Banana = $null
    $script:P1.Pose = 'idle'; $script:P2.Pose = 'idle'
    $script:Active = if ($script:Active -eq 1) { 2 } else { 1 }
    $script:State = 'Idle'
    Update-Hud
}

function Complete-Round([pscustomobject]$winner, [string]$specialMessage = '') {
    $winner.Score++
    $loser = if ($winner.Num -eq 1) { $script:P2 } else { $script:P1 }
    $name = if ($winner.Num -eq 1) { "Player 1" } else { "Player 2" }
    $script:Message = if ($specialMessage) { $specialMessage } else { "$name wins the round! Next round starting..." }
    $script:Bubble = [pscustomobject]@{
        Text = if ($specialMessage) { $specialMessage } else { $script:Taunts[$script:Rng.Next(0, $script:Taunts.Count)] }
        GorillaNum = $winner.Num
    }
    $winner.Pose = 'dance'
    $loser.Pose = 'defeated'
    $script:State = 'Message'
    Invoke-Sound 'win'
    Update-Hud
    $script:RoundEndTimer.Start()
}

$script:g1.Button.Add_Click({
    if ($script:Active -eq 1 -and $script:State -eq 'Idle') {
        Start-Throw $script:P1 $script:P2 ([double]$script:g1.Angle.Value) ([double]$script:g1.Power.Value)
    }
})
$script:g2.Button.Add_Click({
    if ($script:Active -eq 2 -and $script:State -eq 'Idle' -and -not $script:VsCpu) {
        Start-Throw $script:P2 $script:P1 ([double]$script:g2.Angle.Value) ([double]$script:g2.Power.Value)
    }
})
$script:newGameBtn.Add_Click({
    $script:P1.Score = 0; $script:P2.Score = 0
    $script:Active = 1
    New-Round
})

$script:RoundEndTimer = New-Object System.Windows.Forms.Timer
$script:RoundEndTimer.Interval = 2200
$script:RoundEndTimer.Add_Tick({
    $script:RoundEndTimer.Stop()
    $script:Active = if ($script:Active -eq 1) { 2 } else { 1 }
    New-Round
})

$script:CpuTimer = New-Object System.Windows.Forms.Timer
$script:CpuTimer.Interval = 900
$script:CpuTimer.Add_Tick({
    $script:CpuTimer.Stop()
    $script:CpuPending = $false
    if (-not $script:VsCpu -or $script:Active -ne 2 -or $script:State -ne 'Idle') { return }
    $throwVals = Get-CpuThrow
    $angle = $throwVals[0]; $power = $throwVals[1]
    $script:CpuMemory.LastAngle = $angle
    $script:CpuMemory.LastPower = $power
    Start-Throw $script:P2 $script:P1 $angle $power
})

$script:PlaneTimer = New-Object System.Windows.Forms.Timer
$script:PlaneTimer.Interval = 45000
$script:PlaneTimer.Add_Tick({
    if ($script:Plane -or $script:State -in @('Message','PlaneDisaster')) { return }
    $dir = if ($script:Rng.Next(0,2) -eq 0) { 1 } else { -1 }
    $script:Plane = [pscustomobject]@{
        X = if ($dir -gt 0) { -65.0 } else { $CanvasW + 65.0 }
        Y = [double]$script:Rng.Next(105, 166)
        Direction = $dir
        Speed = 1.15 + $script:Rng.NextDouble() * .55
        State = 'Flying'; Rotation = 0.0; FallSpeed = 0.0
        BlastRadius = 0.0; BlastTarget = 82.0; Shooter = $null
    }
})

# ---------------------------------------------------------------------------
# GAME LOOP
# ---------------------------------------------------------------------------

$script:gravity = 0.32
$script:windAccel = { $script:Wind * 0.0055 }
$script:PlaneClock = [System.Diagnostics.Stopwatch]::StartNew()

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 16
$script:timer.Add_Tick({
    # WinForms timers do not fire at perfectly even intervals. Measuring real
    # elapsed time prevents the aircraft from advancing in visible little steps.
    $planeElapsed = $script:PlaneClock.Elapsed.TotalSeconds
    $script:PlaneClock.Restart()
    $planeFrame = [Math]::Min(2.5, [Math]::Max(.25, $planeElapsed / (1.0/60.0)))
    Update-Clouds
    $script:AnimClock += 0.016 * $script:GameSpeed

    if ($script:Plane) {
        $p = $script:Plane
        switch ($p.State) {
            'Flying' {
                $p.X += $p.Speed * $p.Direction * $script:GameSpeed * $planeFrame
                $p.Y += [Math]::Sin($script:AnimClock * 1.35) * .025 * $planeFrame
                if (($p.Direction -gt 0 -and $p.X -gt $CanvasW+70) -or ($p.Direction -lt 0 -and $p.X -lt -70)) { $script:Plane = $null }
            }
            'Exploding' {
                $p.BlastRadius += 5.5 * $script:GameSpeed
                if ($p.BlastRadius -ge $p.BlastTarget) { $p.State='Falling'; $p.BlastRadius=0; $p.FallSpeed=1.5 }
            }
            'Falling' {
                $p.FallSpeed += .20 * $script:GameSpeed
                $p.Y += $p.FallSpeed * $script:GameSpeed
                $p.X += $p.Direction * .45 * $script:GameSpeed
                $p.Rotation += $p.Direction * 2.2 * $script:GameSpeed
                $planeHitBuilding = Test-Solid -x $p.X -y ($p.Y + 12)
                $planeBelowCanvas = $p.Y -gt $CanvasH
                if ($planeHitBuilding -or $planeBelowCanvas) {
                    $p.State = 'Crashed'
                    $p.BlastRadius = 2
                    $p.BlastTarget = 72
                    Invoke-Sound 'explode'
                }
            }
            'Crashed' {
                $p.BlastRadius += 6 * $script:GameSpeed
                if ($p.BlastRadius -ge $p.BlastTarget) {
                    $culprit=$p.Shooter; $script:Plane=$null
                    $winner = if ($culprit.Num -eq 1) { $script:P2 } else { $script:P1 }
                    Complete-Round $winner 'You nasty boy!'
                }
            }
        }
    }
    switch ($script:State) {
        'Flying' {
            $b = $script:Banana
            $simDt = 0.5 * $script:GameSpeed

            $b.VX += (& $script:windAccel) * $script:GameSpeed
            $b.VY += $script:gravity * $script:GameSpeed

            # Total displacement this frame...
            $frameDX = $b.VX * $simDt
            $frameDY = $b.VY * $simDt
            $frameLen = [Math]::Sqrt($frameDX*$frameDX + $frameDY*$frameDY)

            $steps  = [Math]::Max(1, [int][Math]::Ceiling($frameLen / 4.0))
            $stepDX = $frameDX / $steps
            $stepDY = $frameDY / $steps

            $hit = $false
            for ($s = 0; $s -lt $steps; $s++) {
                $b.X += $stepDX
                $b.Y += $stepDY

                $b.Trail.Add([pscustomobject]@{ X = $b.X; Y = $b.Y }) | Out-Null
                if ($b.Trail.Count -gt 24) { $b.Trail.RemoveAt(0) }

                if ($b.X -lt -20 -or $b.X -gt ($CanvasW + 20) -or $b.Y -gt $GroundY) {
                    $hit = $true; break
                }
                if (Test-Solid $b.X $b.Y) { $hit = $true; break }

                if ($script:Plane -and $script:Plane.State -eq 'Flying' -and
                    [Math]::Abs($b.X-$script:Plane.X) -lt 55 -and [Math]::Abs($b.Y-$script:Plane.Y) -lt 24) {
                    $script:Plane.State='Exploding'; $script:Plane.Shooter=$b.Shooter
                    $script:Plane.BlastRadius=3; $script:Banana=$null; $script:State='PlaneDisaster'
                    Invoke-Sound 'explode'; $hit=$false; break
                }


                foreach ($gp in @($script:P1, $script:P2)) {
                    if ($gp.Num -eq $b.Shooter.Num) { continue }
                    if ([Math]::Abs($b.X - $gp.X) -lt 27 -and $b.Y -gt ($gp.Y - 76) -and $b.Y -lt ($gp.Y + 4)) {
                        $hit = $true; break
                    }
                }
                if ($hit) { break }
            }


            if ($hit) {
                Start-Explosion $b.X $b.Y $b.Shooter
            }
        }
        'Exploding' {
            $e = $script:Explosion
            $e.Radius += $e.Step * $script:GameSpeed   # animate at the same tempo as the rest of the sim
            if ($e.Radius -ge $e.Target) {
                if ($e.Y -le $CanvasH) {
                    $script:Craters.Add([pscustomobject]@{ X = $e.X; Y = $e.Y; R = $e.CraterR }) | Out-Null
                }
                if ($script:VsCpu -and $e.Shooter -and $e.Shooter.Num -eq 2) {
                    $script:CpuMemory.HasShot = $true
                    $script:CpuMemory.LandX = $e.X
                    $script:CpuMemory.LandY = $e.Y
                }

                $shooter   = $e.Shooter
                $enemyHit  = $false
                $selfHit   = $false
                foreach ($gp in @($script:P1, $script:P2)) {
                    $dx = $e.X - $gp.X; $dy = $e.Y - ($gp.Y - 22)
                    if (($dx*$dx + $dy*$dy) -le ($e.KillR * $e.KillR)) {
                        if ($shooter -and $gp.Num -eq $shooter.Num) { $selfHit = $true }
                        else { $enemyHit = $true }
                    }
                }

                $script:Explosion = $null
                if ($enemyHit) {
                    Complete-Round $shooter
                } elseif ($selfHit) {
                    $other = if ($shooter.Num -eq 1) { $script:P2 } else { $script:P1 }
                    Complete-Round $other
                } else {
                    Complete-Turn
                }
            }
        }
        default { }
    }
    $script:canvas.Invalidate()
})

# ---------------------------------------------------------------------------
# GO
# ---------------------------------------------------------------------------

New-Round
$script:timer.Start()
$script:PlaneTimer.Start()
[System.Windows.Forms.Application]::Run($script:form)
