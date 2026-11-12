# =====================================================================
#  Triple Clock Widget for Windows - Jeddah, Cairo, Toronto
#  Uses only what is already built into Windows (PowerShell + WPF).
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\TripleClockDesktopWidget', [ref]$createdNew)
if (-not $createdNew) { exit }

$ScriptDir  = Split-Path -Parent $PSCommandPath
$AppDir     = Join-Path $env:APPDATA 'TripleClockWidget'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
$ConfigPath = Join-Path $AppDir 'config.json'
$LogPath    = Join-Path $AppDir 'widget.log'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Triple Clock.lnk'
$Launcher   = Join-Path $ScriptDir 'Start Triple Clock.vbs'

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

$script:Culture = [Globalization.CultureInfo]::CurrentCulture
if (-not ($script:Culture.Calendar -is [Globalization.GregorianCalendar])) {
    $script:Culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
}

# ---------- the three cities (Windows time zone names) ----------
$Cities = @(
    @{ Name = 'JEDDAH';  Tz = 'Arab Standard Time';    Accent = '#34C38F' }
    @{ Name = 'CAIRO';   Tz = 'Egypt Standard Time';   Accent = '#F7B84B' }
    @{ Name = 'TORONTO'; Tz = 'Eastern Standard Time'; Accent = '#F46A6A' }
)

# ---------- settings ----------
$script:Config = [ordered]@{ Left = $null; Top = $null; Topmost = $false; Use24h = $false; ShowSeconds = $false; Alpha = 'D9'; Width = 300; Height = 380 }
if (Test-Path $ConfigPath) {
    try {
        $j = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $j.Left) { $script:Config.Left = [double]$j.Left }
        if ($null -ne $j.Top)  { $script:Config.Top  = [double]$j.Top }
        if ($null -ne $j.Topmost) { $script:Config.Topmost = [bool]$j.Topmost }
        if ($null -ne $j.Use24h)  { $script:Config.Use24h  = [bool]$j.Use24h }
        if ($null -ne $j.ShowSeconds) { $script:Config.ShowSeconds = [bool]$j.ShowSeconds }
        if ($j.Width -gt 0)  { $script:Config.Width  = [double]$j.Width }
        if ($j.Height -gt 0) { $script:Config.Height = [double]$j.Height }
        if ($j.Alpha -match '^[0-9A-Fa-f]{2}$') { $script:Config.Alpha = ([string]$j.Alpha).ToUpper() }
        # older versions: map the previous levels onto the new, less see-through ones
        $oldMap = @{ 'EB' = 'F2'; 'B3' = 'D9'; '80' = 'A6'; '4D' = '73' }
        if ($oldMap.ContainsKey($script:Config.Alpha)) { $script:Config.Alpha = $oldMap[$script:Config.Alpha] }
    } catch { Write-Log "Could not read settings: $($_.Exception.Message)" }
}
function Save-Config {
    try { $script:Config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8 } catch { Write-Log "Save failed: $($_.Exception.Message)" }
}

# ---------- window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Triple Clock" Width="330" Height="470" MinWidth="90" MinHeight="40"
        WindowStyle="None" AllowsTransparency="True" Background="#01000000"
        ShowInTaskbar="False" ResizeMode="CanResize" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="12" GlassFrameThickness="0" CornerRadius="0"/>
  </WindowChrome.WindowChrome>
  <Border x:Name="Card" CornerRadius="18" Background="#EB15181E" BorderBrush="#26FFFFFF"
          BorderThickness="1" Padding="18,6,18,6" Margin="10">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.25" Color="Black"/>
    </Border.Effect>
    <Viewbox Stretch="Uniform">
      <StackPanel x:Name="Row"/>
    </Viewbox>
  </Border>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$Card = $window.FindName('Card')
$Row  = $window.FindName('Row')

$script:BrushConv = New-Object Windows.Media.BrushConverter
function Brush([string]$hex) { return $script:BrushConv.ConvertFromString($hex) }
function Set-CardAlpha { $Card.Background = Brush ('#' + $script:Config.Alpha + '15181E') }
Set-CardAlpha

function New-Text([string]$text, [double]$size, [string]$color) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = Brush $color
    $tb.HorizontalAlignment = 'Center'
    return $tb
}

$script:Clocks = @()
$first = $true
foreach ($c in $Cities) {
    $tz = $null
    try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($c.Tz) } catch { Write-Log "Time zone not found: $($c.Tz)" }

    $panel = New-Object Windows.Controls.Border
    $panel.BorderBrush = Brush '#1FFFFFFF'

    # one column: city, big time, then date / difference - all centred
    $grid = New-Object Windows.Controls.StackPanel
    $city = New-Text $c.Name 16 $c.Accent
    $city.FontWeight = [Windows.FontWeights]::Bold
    [void]$grid.Children.Add($city)

    $timeRow = New-Object Windows.Controls.StackPanel
    $timeRow.Orientation = 'Horizontal'; $timeRow.HorizontalAlignment = 'Center'
    $time = New-Text '' 46 '#FFFFFF'
    $time.FontWeight = [Windows.FontWeights]::Bold
    $ampm = New-Text '' 17 '#C9CFDA'
    $ampm.FontWeight = [Windows.FontWeights]::Bold
    $ampm.VerticalAlignment = 'Bottom'; $ampm.Margin = New-Object Windows.Thickness(5, 0, 0, 11)
    [void]$timeRow.Children.Add($time); [void]$timeRow.Children.Add($ampm)
    [void]$grid.Children.Add($timeRow)

    $sub = New-Text '' 12.5 '#AEB6C4'
    $sub.FontWeight = [Windows.FontWeights]::SemiBold
    [void]$grid.Children.Add($sub)

    $panel.Child = $grid
    [void]$Row.Children.Add($panel)
    $script:Clocks += @{ Tz = $tz; Time = $time; AmPm = $ampm; Sub = $sub; Panel = $panel; First = $first }
    $first = $false
}

function Update-Clocks {
    try {
        $utc = [DateTime]::UtcNow
        $local = $utc.ToLocalTime()
        foreach ($k in $script:Clocks) {
            if ($null -eq $k.Tz) { $k.Time.Text = '--:--'; $k.Sub.Text = 'time zone missing'; continue }
            $t = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $k.Tz)

            $fmt = 'h:mm'; if ($script:Config.Use24h) { $fmt = 'HH:mm' }
            if ($script:Config.ShowSeconds) { $fmt += ':ss' }
            $k.Time.Text = $t.ToString($fmt, $script:Culture)
            if ($script:Config.Use24h) { $k.AmPm.Text = '' } else { $k.AmPm.Text = $t.ToString('tt', $script:Culture) }

            if ($t.Hour -ge 6 -and $t.Hour -lt 18) { $icon = [string][char]0x2600 } else { $icon = [string][char]0x263E }

            $diffH = [math]::Round(($t - $local).TotalHours * 2) / 2
            if ($diffH -eq 0) { $diff = 'Your time' }
            elseif ($diffH -gt 0) { $diff = '+' + $diffH + ' hr' }
            else { $diff = [string][char]0x2212 + [math]::Abs($diffH) + ' hr' }

            if ($t.Date -gt $local.Date) { $day = 'Tomorrow' }
            elseif ($t.Date -lt $local.Date) { $day = 'Yesterday' }
            else { $day = $t.ToString('ddd d MMM', $script:Culture) }

            $k.Sub.Text = "$icon  $day  " + [char]0x00B7 + "  $diff"
            $k.Panel.ToolTip = $t.ToString('dddd d MMMM yyyy, ', $script:Culture) + $t.ToString('HH:mm:ss') + "`n" + $k.Tz.DisplayName
        }
    } catch { Write-Log "Update error: $($_.Exception.Message)" }
}

# ---------- menu ----------
function Set-Startup([bool]$on) {
    try {
        if ($on) {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($StartupLnk)
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $lnk.Arguments = '"' + $Launcher + '"'
            $lnk.WorkingDirectory = $ScriptDir
            $lnk.Description = 'Triple clock desktop widget'
            $lnk.Save()
        } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    } catch { [Windows.MessageBox]::Show("Couldn't change the startup setting: $($_.Exception.Message)", 'Triple Clock') | Out-Null }
}
function Save-Position {
    $script:Config.Left = $window.Left; $script:Config.Top = $window.Top
    if ($window.ActualWidth -gt 0) { $script:Config.Width = $window.ActualWidth; $script:Config.Height = $window.ActualHeight }
    Save-Config
}

# Wide and short = one row; otherwise one column. The text scales to fill the widget.
$script:Horizontal = $null
function Update-Layout {
    $w = $window.ActualWidth; $h = $window.ActualHeight
    if ($w -le 0) { $w = $window.Width; $h = $window.Height }
    $horiz = ($w -gt $h * 1.9)
    if ($horiz -eq $script:Horizontal) { return }
    $script:Horizontal = $horiz
    if ($horiz) { $Row.Orientation = 'Horizontal'; $Card.Padding = New-Object Windows.Thickness(8, 6, 8, 6) }
    else { $Row.Orientation = 'Vertical'; $Card.Padding = New-Object Windows.Thickness(12, 4, 12, 4) }
    foreach ($k in $script:Clocks) {
        if ($horiz) {
            $k.Panel.Padding = New-Object Windows.Thickness(14, 2, 14, 2)
            if ($k.First) { $k.Panel.BorderThickness = New-Object Windows.Thickness(0) }
            else { $k.Panel.BorderThickness = New-Object Windows.Thickness(1, 0, 0, 0) }
        } else {
            $k.Panel.Padding = New-Object Windows.Thickness(2, 8, 2, 8)
            if ($k.First) { $k.Panel.BorderThickness = New-Object Windows.Thickness(0) }
            else { $k.Panel.BorderThickness = New-Object Windows.Thickness(0, 1, 0, 0) }
        }
    }
}

$script:Snapping = $false
$script:LastDim = 'W'
function Snap-ToContent {
    if ($window.ActualWidth -le 0) { return }
    $Row.Measure((New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $cw = $Row.DesiredSize.Width; $ch = $Row.DesiredSize.Height
    if ($cw -le 0 -or $ch -le 0) { return }
    $pad = $Card.Padding
    $extraW = 22 + $pad.Left + $pad.Right     # shadow margin (10+10) + border (1+1) + padding
    $extraH = 22 + $pad.Top + $pad.Bottom
    $script:Snapping = $true
    try {
        if ($script:LastDim -eq 'H') {
            $scale = ($window.ActualHeight - $extraH) / $ch
            $window.Width = [math]::Max($window.MinWidth, [math]::Round($cw * $scale + $extraW))
        } else {
            $scale = ($window.ActualWidth - $extraW) / $cw
            $window.Height = [math]::Max($window.MinHeight, [math]::Round($ch * $scale + $extraH))
        }
    } finally { $script:Snapping = $false }
    Save-Position
}

$menu = New-Object Windows.Controls.ContextMenu
function Add-Item([string]$header, [scriptblock]$action) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header; $mi.Add_Click($action)
    [void]$menu.Items.Add($mi); return $mi
}
$mi24 = Add-Item '24-hour clock' { $script:Config.Use24h = $this.IsChecked; Save-Config; Update-Clocks }
$mi24.IsCheckable = $true; $mi24.IsChecked = [bool]$script:Config.Use24h
$miSec = Add-Item 'Show seconds' { $script:Config.ShowSeconds = $this.IsChecked; Save-Config; Update-Clocks }
$miSec.IsCheckable = $true; $miSec.IsChecked = [bool]$script:Config.ShowSeconds
$miTop = Add-Item 'Keep on top of other windows' { $script:Config.Topmost = $this.IsChecked; $window.Topmost = $this.IsChecked; Save-Config }
$miTop.IsCheckable = $true; $miTop.IsChecked = [bool]$script:Config.Topmost
$alphaMenu = New-Object Windows.Controls.MenuItem; $alphaMenu.Header = 'Transparency'
foreach ($opt in @(@('Solid', 'F2'), @('Slightly transparent', 'D9'), @('More transparent', 'A6'), @('Very transparent', '73'))) {
    $am = New-Object Windows.Controls.MenuItem
    $am.Header = $opt[0]; $am.Tag = $opt[1]; $am.IsCheckable = $true
    $am.IsChecked = ($script:Config.Alpha -eq $opt[1])
    $am.Add_Click({
        $script:Config.Alpha = [string]$this.Tag; Save-Config; Set-CardAlpha
        foreach ($x in $alphaMenu.Items) { $x.IsChecked = ([string]$x.Tag -eq $script:Config.Alpha) }
    })
    [void]$alphaMenu.Items.Add($am)
}
[void]$menu.Items.Add($alphaMenu)
$miStart = Add-Item 'Start with Windows' { Set-Startup $this.IsChecked; $this.IsChecked = (Test-Path $StartupLnk) }
$miStart.IsCheckable = $true; $miStart.IsChecked = (Test-Path $StartupLnk)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-Item 'Close clock' { $window.Close() })
$Card.ContextMenu = $menu

# ---------- start ----------
$window.Topmost = [bool]$script:Config.Topmost
$window.Width  = [math]::Max(150, [double]$script:Config.Width)
$window.Height = [math]::Max(60, [double]$script:Config.Height)
Update-Layout
$vs = [Windows.SystemParameters]
$script:Placed = $false
if ($null -ne $script:Config.Left -and $null -ne $script:Config.Top) {
    $l = [double]$script:Config.Left; $t = [double]$script:Config.Top
    if ($l -ge $vs::VirtualScreenLeft - 50 -and $l -le ($vs::VirtualScreenLeft + $vs::VirtualScreenWidth - 100) -and
        $t -ge $vs::VirtualScreenTop - 50 -and $t -le ($vs::VirtualScreenTop + $vs::VirtualScreenHeight - 100)) {
        $window.Left = $l; $window.Top = $t; $script:Placed = $true
    }
}
if (-not $script:Placed) {
    $wa = $vs::WorkArea
    $window.Left = $wa.Right - $window.Width - 16
    $window.Top  = $wa.Bottom - $window.Height - 8
}

$Card.Add_MouseLeftButtonDown({ try { $window.DragMove(); Save-Position } catch { } })
$window.Add_SizeChanged({ Update-Layout })
$script:SnapTimer = New-Object Windows.Threading.DispatcherTimer
$script:SnapTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:SnapTimer.Add_Tick({
    # wait until the mouse button is released before trimming
    if ([System.Windows.Forms.Control]::MouseButtons -ne 'None') { return }
    $script:SnapTimer.Stop()
    Snap-ToContent
})
$window.Add_SizeChanged({
    param($sender, $e)
    if ($script:Snapping) { return }
    if ($e.HeightChanged -and -not $e.WidthChanged) { $script:LastDim = 'H' } else { $script:LastDim = 'W' }
    $script:SnapTimer.Stop(); $script:SnapTimer.Start()
})
$window.Dispatcher.Add_UnhandledException({ Write-Log "Unhandled: $($_.Exception.Message)"; $_.Handled = $true })

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.Add_Tick({ Update-Clocks })

$window.Add_ContentRendered({
    Update-Layout
    $script:LastDim = 'W'
    Snap-ToContent
    $timer.Start()
})
$window.Add_Closed({
    try { $timer.Stop(); Save-Position } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
})

Update-Clocks
try { [void]$window.ShowDialog() }
catch {
    Write-Log "Fatal: $($_.Exception.Message)"
    [Windows.MessageBox]::Show("The clock widget stopped: $($_.Exception.Message)", 'Triple Clock') | Out-Null
}
