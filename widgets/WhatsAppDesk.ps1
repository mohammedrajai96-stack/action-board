# =====================================================================
#  WhatsApp Desk - desktop widget for up to 3 personal WhatsApp numbers
#  Talks to WhatsAppDesk-bridge.exe (same folder), which links the numbers
#  as "linked devices" and keeps their chats on this computer.
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\WhatsAppDeskWidget', [ref]$createdNew)
if (-not $createdNew) { exit }

$ScriptDir  = Split-Path -Parent $PSCommandPath
$BridgeExe  = Join-Path $ScriptDir 'WhatsAppDesk-bridge.exe'
$DataDir    = Join-Path $env:APPDATA 'WhatsAppDesk'
$TokenPath  = Join-Path $DataDir 'token.txt'
$ConfigPath = Join-Path $DataDir 'widget.json'
$LogPath    = Join-Path $DataDir 'widget.log'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'WhatsApp Desk.lnk'
$Launcher   = Join-Path $ScriptDir 'Start WhatsApp Desk.vbs'
$Api        = 'http://127.0.0.1:47321'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

$script:Culture = [Globalization.CultureInfo]::CurrentCulture
if (-not ($script:Culture.Calendar -is [Globalization.GregorianCalendar])) {
    $script:Culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
}

# ---------- settings ----------
$script:Config = [ordered]@{
    Left = $null; Top = $null; Width = 380; Height = 620
    Topmost = $false; Alpha = 'F2'; Scale = 1.0; Sound = $true; Labels = @{}
}
function Load-Config {
    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $j = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @('Left', 'Top', 'Width', 'Height', 'Scale')) { if ($null -ne $j.$k) { $script:Config[$k] = [double]$j.$k } }
        foreach ($k in @('Topmost', 'Sound')) { if ($null -ne $j.$k) { $script:Config[$k] = [bool]$j.$k } }
        if ($j.Alpha -match '^[0-9A-Fa-f]{2}$') { $script:Config.Alpha = ([string]$j.Alpha).ToUpper() }
        if ($j.Labels) { $h = @{}; foreach ($p in $j.Labels.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }; $script:Config.Labels = $h }
    } catch { Write-Log "Could not read settings: $($_.Exception.Message)" }
}
function Save-Config {
    try { $script:Config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8 } catch { Write-Log "Save failed: $($_.Exception.Message)" }
}

# ---------- talking to the bridge ----------
$script:Token = $null
function Get-Token {
    if (-not $script:Token -and (Test-Path $TokenPath)) { $script:Token = (Get-Content $TokenPath -Raw).Trim() }
    return $script:Token
}
function New-Web {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers.Add('X-Token', (Get-Token))
    return $wc
}
function Api-Get([string]$path) {
    $wc = New-Web
    try { return ($wc.DownloadString($Api + $path) | ConvertFrom-Json) } finally { $wc.Dispose() }
}
function Api-Post([string]$path, $body) {
    $wc = New-Web
    try {
        $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
        $json = '{}'; if ($null -ne $body) { $json = $body | ConvertTo-Json -Compress }
        return ($wc.UploadString($Api + $path, 'POST', $json) | ConvertFrom-Json)
    } finally { $wc.Dispose() }
}
function Api-Bytes([string]$path) {
    $wc = New-Web
    try { return $wc.DownloadData($Api + $path) } finally { $wc.Dispose() }
}

function Test-Bridge {
    try { [void](Api-Get '/api/status'); return $true } catch { return $false }
}

function Start-Bridge {
    if (Test-Bridge) { return $true }
    if (-not (Test-Path $BridgeExe)) {
        [Windows.MessageBox]::Show("WhatsAppDesk-bridge.exe is missing from this folder:`n$ScriptDir", 'WhatsApp Desk') | Out-Null
        return $false
    }
    Start-Process -FilePath $BridgeExe -WorkingDirectory $ScriptDir -WindowStyle Hidden
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $script:Token = $null
        if (Test-Bridge) { return $true }
    }
    return $false
}

# ---------- window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WhatsApp Desk" Width="380" Height="620" MinWidth="270" MinHeight="220"
        WindowStyle="None" AllowsTransparency="True" Background="#01000000"
        ShowInTaskbar="False" ResizeMode="CanResize" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="12" GlassFrameThickness="0" CornerRadius="0"/>
  </WindowChrome.WindowChrome>
  <Border x:Name="Card" CornerRadius="18" Background="#F215181E" BorderBrush="#26FFFFFF"
          BorderThickness="1" Padding="0" Margin="10">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.35" Color="Black"/>
    </Border.Effect>
    <Grid x:Name="Root">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- header (drag here) -->
      <Border x:Name="Header" Grid.Row="0" Background="#01000000" Padding="18,14,18,10">
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="BackBtn" Grid.Column="0" Text="&#x2039;" FontSize="30" Foreground="#25D366" Margin="-4,-10,10,-6"
                       Cursor="Hand" Visibility="Collapsed" VerticalAlignment="Center"/>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="Title" Text="WhatsApp" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="SubTitle" FontSize="11" Foreground="#8A93A3" TextTrimming="CharacterEllipsis" Visibility="Collapsed"/>
            </StackPanel>
            <Border x:Name="TotalBadge" Grid.Column="2" Background="#25D366" CornerRadius="10" Padding="8,1,8,2"
                    VerticalAlignment="Center" Visibility="Collapsed">
              <TextBlock x:Name="TotalText" FontSize="11.5" FontWeight="Bold" Foreground="#0B141A"/>
            </Border>
          </Grid>
          <WrapPanel x:Name="Chips" Margin="0,8,0,0"/>
        </StackPanel>
      </Border>

      <!-- chat list -->
      <Grid x:Name="ListView" Grid.Row="1">
        <ScrollViewer x:Name="ListScroll" VerticalScrollBarVisibility="Auto" Margin="6,0,6,12">
          <StackPanel x:Name="ChatList"/>
        </ScrollViewer>
      </Grid>

      <!-- one conversation -->
      <Grid x:Name="ChatView" Grid.Row="1" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <ScrollViewer x:Name="MsgScroll" Grid.Row="0" VerticalScrollBarVisibility="Auto" Margin="10,0,10,0">
          <StackPanel x:Name="MsgList" Margin="4,4,4,8"/>
        </ScrollViewer>
        <Border Grid.Row="1" Background="#14FFFFFF" CornerRadius="0,0,17,17" Padding="12,10,12,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="Input" Grid.Column="0" MinHeight="34" MaxHeight="120" AcceptsReturn="True" TextWrapping="Wrap"
                     VerticalScrollBarVisibility="Auto" FontSize="13" Padding="10,6" Background="#26FFFFFF" Foreground="#FFFFFF"
                     BorderThickness="0" CaretBrush="#FFFFFF" VerticalContentAlignment="Center"/>
            <Border x:Name="SendBtn" Grid.Column="1" Width="36" Height="36" CornerRadius="18" Background="#25D366"
                    Margin="8,0,0,0" Cursor="Hand" VerticalAlignment="Bottom">
              <TextBlock Text="&#x27A4;" FontSize="16" Foreground="#0B141A" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="2,0,0,1"/>
            </Border>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in @('Card', 'Root', 'Header', 'BackBtn', 'Title', 'SubTitle', 'TotalBadge', 'TotalText', 'Chips', 'ListView', 'ListScroll',
                 'ChatList', 'ChatView', 'MsgScroll', 'MsgList', 'Input', 'SendBtn')) {
    Set-Variable -Name $n -Value $window.FindName($n) -Scope Script
}

$script:BrushConv = New-Object Windows.Media.BrushConverter
function Brush([string]$hex) { return $script:BrushConv.ConvertFromString($hex) }
function Set-CardAlpha { $Card.Background = Brush ('#' + $script:Config.Alpha + '15181E') }
$Palette = @('#25D366', '#4F8EF7', '#F7B84B', '#F46A6A', '#A66EF7')

function T([string]$text, [double]$size, [string]$color) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = Brush $color
    return $tb
}
function Is-Arabic([string]$s) { return ($s -match '[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]') }
function Set-Dir($tb, [string]$s) { if (Is-Arabic $s) { $tb.FlowDirection = 'RightToLeft'; $tb.TextAlignment = 'Left' } }

function To-Local([long]$ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime }
function Fmt-ListTime([long]$ms) {
    $t = To-Local $ms; $now = Get-Date
    if ($t.Date -eq $now.Date) { return $t.ToString('h:mm tt', $script:Culture) }
    if ($t.Date -eq $now.Date.AddDays(-1)) { return 'Yesterday' }
    if (($now.Date - $t.Date).TotalDays -lt 7) { return $t.ToString('dddd', $script:Culture) }
    return $t.ToString('d/M/yy', $script:Culture)
}

# ---------- state ----------
$script:Accounts = @()
$script:AccColor = @{}
$script:Filter = $null
$script:Open = $null          # @{ Account; Chat; Name }
$script:LastChatsJson = ''
$script:LastMsgsJson = ''
$script:LastUnread = -1
$script:BridgeOk = $false

function Account-Label([string]$id) {
    if ($script:Config.Labels.ContainsKey($id) -and $script:Config.Labels[$id]) { return $script:Config.Labels[$id] }
    $a = $script:Accounts | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if ($a -and $a.name) { return $a.name }
    if ($a -and $a.phone) { return $a.phone }
    return $id
}

# ---------- drawing ----------
function Draw-Chips {
    $Chips.Children.Clear()
    $linked = @($script:Accounts | Where-Object { $_.logged_in -or $_.phone })
    if ($linked.Count -le 1 -and -not $script:Filter) { $Chips.Visibility = 'Collapsed'; return }
    $Chips.Visibility = 'Visible'
    foreach ($a in $linked) {
        $chip = New-Object Windows.Controls.Border
        $chip.CornerRadius = New-Object Windows.CornerRadius(11)
        $chip.Padding = New-Object Windows.Thickness(9, 2, 10, 3)
        $chip.Margin = New-Object Windows.Thickness(0, 0, 6, 4)
        $chip.Cursor = 'Hand'; $chip.Tag = $a.id
        $active = ($script:Filter -eq $a.id)
        if ($active) { $chip.Background = Brush '#33FFFFFF' } else { $chip.Background = Brush '#14FFFFFF' }
        $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 8; $dot.Height = 8; $dot.Margin = New-Object Windows.Thickness(0, 0, 6, 0); $dot.VerticalAlignment = 'Center'
        if ($a.connected -and $a.logged_in) { $dot.Fill = Brush $script:AccColor[$a.id] }
        else { $dot.Fill = Brush '#00000000'; $dot.Stroke = Brush $script:AccColor[$a.id]; $dot.StrokeThickness = 1.5 }
        [void]$sp.Children.Add($dot)
        $lbl = T (Account-Label $a.id) 11.5 '#D5DAE3'
        if ($a.error) { $lbl.Foreground = Brush '#F7B84B'; $chip.ToolTip = $a.error }
        elseif (-not $a.connected) { $chip.ToolTip = 'Connecting...' }
        else { $chip.ToolTip = "$($a.phone)  -  click to show only this number" }
        [void]$sp.Children.Add($lbl)
        $chip.Child = $sp
        $chip.Add_MouseLeftButtonUp({
            param($s, $e)
            if ($script:Filter -eq $s.Tag) { $script:Filter = $null } else { $script:Filter = $s.Tag }
            $script:LastChatsJson = ''; Refresh-List; $e.Handled = $true
        })
        [void]$Chips.Children.Add($chip)
    }
}

function Show-Empty([string]$text) {
    $ChatList.Children.Clear()
    $tb = T $text 12.5 '#AEB6C4'
    $tb.TextWrapping = 'Wrap'; $tb.Margin = New-Object Windows.Thickness(14, 16, 14, 8)
    [void]$ChatList.Children.Add($tb)
}

function Draw-Chats($chats) {
    $ChatList.Children.Clear()
    $shown = @($chats | Where-Object { -not $script:Filter -or $_.account -eq $script:Filter })
    if ($shown.Count -eq 0) {
        if (@($script:Accounts).Count -eq 0) { Show-Empty "No WhatsApp number linked yet.`nRight-click here and choose `"Add a WhatsApp number`"." }
        else { Show-Empty "No chats yet. Right after linking, it can take a few minutes for your recent chats to arrive." }
        return
    }
    foreach ($c in $shown) {
        $row = New-Object Windows.Controls.Border
        $row.Padding = New-Object Windows.Thickness(10, 8, 10, 8)
        $row.CornerRadius = New-Object Windows.CornerRadius(10)
        $row.Background = Brush '#00FFFFFF'; $row.Cursor = 'Hand'
        $row.Tag = $c
        $row.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#14FFFFFF' })
        $row.Add_MouseLeave({ param($s, $e) $s.Background = Brush '#00FFFFFF' })
        $row.Add_MouseLeftButtonUp({ param($s, $e) Open-Chat $s.Tag; $e.Handled = $true })

        $g = New-Object Windows.Controls.Grid
        foreach ($w in @(4)) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength($w); $g.ColumnDefinitions.Add($cd) }
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($cd)
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = [Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($cd)

        $bar = New-Object Windows.Controls.Border
        $bar.CornerRadius = New-Object Windows.CornerRadius(2)
        $col = $script:AccColor[$c.account]; if (-not $col) { $col = '#5A6270' }
        $bar.Background = Brush $col; $bar.Margin = New-Object Windows.Thickness(0, 2, 0, 2)
        [Windows.Controls.Grid]::SetColumn($bar, 0); [void]$g.Children.Add($bar)

        $mid = New-Object Windows.Controls.StackPanel; $mid.Margin = New-Object Windows.Thickness(10, 0, 8, 0)
        $name = $c.name; if ($c.is_group) { $name = [string][char]0x2630 + '  ' + $name }
        $nt = T $name 13.5 '#F2F4F8'; $nt.TextTrimming = 'CharacterEllipsis'
        if ($c.unread -gt 0) { $nt.FontWeight = [Windows.FontWeights]::Bold } else { $nt.FontWeight = [Windows.FontWeights]::SemiBold }
        [void]$mid.Children.Add($nt)
        $prev = $c.last_text -replace '\s+', ' '
        if ($c.last_from_me) { $prev = 'You: ' + $prev }
        elseif ($c.is_group -and $c.last_sender) { $prev = $c.last_sender + ': ' + $prev }
        $pt = T $prev 12 '#8A93A3'; $pt.TextTrimming = 'CharacterEllipsis'; $pt.Margin = New-Object Windows.Thickness(0, 1, 0, 0)
        if ($c.unread -gt 0) { $pt.Foreground = Brush '#C9CFDA' }
        [void]$mid.Children.Add($pt)
        [Windows.Controls.Grid]::SetColumn($mid, 1); [void]$g.Children.Add($mid)

        $right = New-Object Windows.Controls.StackPanel; $right.HorizontalAlignment = 'Right'
        $tt = T (Fmt-ListTime $c.last_ts) 10.5 '#7D8594'; $tt.HorizontalAlignment = 'Right'
        if ($c.unread -gt 0) { $tt.Foreground = Brush '#25D366' }
        [void]$right.Children.Add($tt)
        if ($c.unread -gt 0) {
            $b = New-Object Windows.Controls.Border
            $b.Background = Brush '#25D366'; $b.CornerRadius = New-Object Windows.CornerRadius(9)
            $b.MinWidth = 18; $b.Padding = New-Object Windows.Thickness(5, 0, 5, 1); $b.Margin = New-Object Windows.Thickness(0, 3, 0, 0)
            $b.HorizontalAlignment = 'Right'
            $bt = T ([string]$c.unread) 10.5 '#0B141A'; $bt.FontWeight = [Windows.FontWeights]::Bold; $bt.HorizontalAlignment = 'Center'
            $b.Child = $bt; [void]$right.Children.Add($b)
        }
        [Windows.Controls.Grid]::SetColumn($right, 2); [void]$g.Children.Add($right)

        $row.Child = $g
        $row.ToolTip = "$($c.name)`nOn: $(Account-Label $c.account)"
        [void]$ChatList.Children.Add($row)
    }
}

function Draw-Messages($msgs, [bool]$stickToBottom) {
    $MsgList.Children.Clear()
    $lastDay = $null
    $isGroup = $script:Open.Chat -like '*@g.us'
    foreach ($m in $msgs) {
        $t = To-Local $m.ts
        if ($t.Date -ne $lastDay) {
            $lastDay = $t.Date
            $label = $t.ToString('ddd d MMM yyyy', $script:Culture)
            if ($t.Date -eq (Get-Date).Date) { $label = 'Today' } elseif ($t.Date -eq (Get-Date).Date.AddDays(-1)) { $label = 'Yesterday' }
            $d = T $label 10.5 '#8A93A3'; $d.HorizontalAlignment = 'Center'; $d.Margin = New-Object Windows.Thickness(0, 10, 0, 6)
            [void]$MsgList.Children.Add($d)
        }
        $bub = New-Object Windows.Controls.Border
        $bub.CornerRadius = New-Object Windows.CornerRadius(12)
        $bub.Padding = New-Object Windows.Thickness(10, 6, 10, 5)
        $bub.Margin = New-Object Windows.Thickness(0, 2, 0, 2)
        $bub.MaxWidth = [math]::Max(160, ($MsgScroll.ActualWidth - 50) * 0.82)
        if ($m.from_me) { $bub.Background = Brush '#005C4B'; $bub.HorizontalAlignment = 'Right' }
        else { $bub.Background = Brush '#262B33'; $bub.HorizontalAlignment = 'Left' }
        $sp = New-Object Windows.Controls.StackPanel
        if ($isGroup -and -not $m.from_me -and $m.sender_name) {
            $sn = T $m.sender_name 11 $script:AccColor[$script:Open.Account]; $sn.FontWeight = [Windows.FontWeights]::SemiBold
            [void]$sp.Children.Add($sn)
        }
        $body = T $m.body 13 '#ECEFF3'
        $body.TextWrapping = 'Wrap'
        if (Is-Arabic $m.body) { $body.FlowDirection = 'RightToLeft' }
        [void]$sp.Children.Add($body)
        $tm = T ($t.ToString('h:mm tt', $script:Culture)) 9.5 '#9AA9B4'; $tm.HorizontalAlignment = 'Right'; $tm.Margin = New-Object Windows.Thickness(0, 1, 0, 0)
        [void]$sp.Children.Add($tm)
        $bub.Child = $sp
        [void]$MsgList.Children.Add($bub)
    }
    if ($stickToBottom) { $MsgScroll.UpdateLayout(); $MsgScroll.ScrollToEnd() }
}

# ---------- refreshing ----------
function Refresh-Status {
    try {
        $st = Api-Get '/api/status'
        $script:BridgeOk = $true
        $script:Accounts = @($st.accounts)
        $i = 0
        foreach ($a in $script:Accounts) {
            if (-not $script:AccColor.ContainsKey($a.id)) { $script:AccColor[$a.id] = $Palette[$i % $Palette.Count] }
            $i++
        }
        Draw-Chips
    } catch {
        $script:BridgeOk = $false
        Write-Log "Status failed: $($_.Exception.Message)"
    }
}

function Refresh-List {
    if (-not $script:BridgeOk) { Show-Empty 'Starting WhatsApp Desk...'; return }
    try {
        $wc = New-Web
        try { $raw = $wc.DownloadString($Api + '/api/chats?limit=120') } finally { $wc.Dispose() }
        $data = $raw | ConvertFrom-Json
        $chats = @($data.chats)
        $unread = 0; foreach ($c in $chats) { $unread += [int]$c.unread }
        if ($unread -gt 0) { $TotalText.Text = [string]$unread; $TotalBadge.Visibility = 'Visible' } else { $TotalBadge.Visibility = 'Collapsed' }
        if ($script:LastUnread -ge 0 -and $unread -gt $script:LastUnread -and $script:Config.Sound) { [System.Media.SystemSounds]::Asterisk.Play() }
        $script:LastUnread = $unread
        $key = $raw + '|' + $script:Filter + '|' + (Get-Date).ToString('yyyyMMddHH')
        if ($key -ne $script:LastChatsJson) {
            $script:LastChatsJson = $key
            $off = $ListScroll.VerticalOffset
            Draw-Chats $chats
            $ListScroll.ScrollToVerticalOffset($off)
        }
    } catch { Write-Log "Chats failed: $($_.Exception.Message)" }
}

function Refresh-Messages([bool]$force) {
    if (-not $script:Open) { return }
    try {
        $q = '/api/messages?limit=150&account=' + [Uri]::EscapeDataString($script:Open.Account) + '&chat=' + [Uri]::EscapeDataString($script:Open.Chat)
        $wc = New-Web
        try { $raw = $wc.DownloadString($Api + $q) } finally { $wc.Dispose() }
        if ($force -or $raw -ne $script:LastMsgsJson) {
            $atBottom = $force -or ($MsgScroll.VerticalOffset -ge $MsgScroll.ScrollableHeight - 30)
            $script:LastMsgsJson = $raw
            Draw-Messages @(($raw | ConvertFrom-Json).messages) $atBottom
            if (-not $force) { [void](Api-Post '/api/read' @{ account = $script:Open.Account; chat = $script:Open.Chat }) }
        }
    } catch { Write-Log "Messages failed: $($_.Exception.Message)" }
}

function Open-Chat($c) {
    $script:Open = @{ Account = $c.account; Chat = $c.chat; Name = $c.name }
    $Title.Text = $c.name
    $SubTitle.Text = 'on ' + (Account-Label $c.account); $SubTitle.Visibility = 'Visible'
    $BackBtn.Visibility = 'Visible'; $Chips.Visibility = 'Collapsed'
    $ListView.Visibility = 'Collapsed'; $ChatView.Visibility = 'Visible'
    $script:LastMsgsJson = ''
    $window.UpdateLayout()
    Refresh-Messages $true
    try { [void](Api-Post '/api/read' @{ account = $c.account; chat = $c.chat }) } catch { }
    $Input.Text = ''
    $window.Activate() | Out-Null
    $Input.Focus() | Out-Null
}

function Close-Chat {
    $script:Open = $null
    $Title.Text = 'WhatsApp'; $SubTitle.Visibility = 'Collapsed'; $BackBtn.Visibility = 'Collapsed'
    $ChatView.Visibility = 'Collapsed'; $ListView.Visibility = 'Visible'
    Draw-Chips
    $script:LastChatsJson = ''; Refresh-List
}

function Send-Current {
    $text = $Input.Text.Trim()
    if (-not $text -or -not $script:Open) { return }
    try {
        $r = Api-Post '/api/send' @{ account = $script:Open.Account; chat = $script:Open.Chat; text = $text }
        if ($r.ok) { $Input.Text = ''; Refresh-Messages $true }
        else { [Windows.MessageBox]::Show("Not sent: $($r.error)", 'WhatsApp Desk') | Out-Null }
    } catch { [Windows.MessageBox]::Show("Not sent: $($_.Exception.Message)", 'WhatsApp Desk') | Out-Null }
}

# ---------- linking a number ----------
[xml]$linkXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Link a WhatsApp number" Width="440" SizeToContent="Height" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Topmost="True" FontFamily="Segoe UI" Background="#F7F8FA">
  <StackPanel Margin="22">
    <TextBlock FontSize="17" FontWeight="SemiBold" Text="Link a WhatsApp number"/>
    <TextBlock TextWrapping="Wrap" FontSize="13" Margin="0,10,0,0" Foreground="#333" LineHeight="20">
      1. On the phone with that number, open WhatsApp.<LineBreak/>
      2. Tap the three dots (Android) or Settings (iPhone) &gt; Linked devices &gt; Link a device.<LineBreak/>
      3. Point the phone at this code.
    </TextBlock>
    <Border Background="White" Margin="0,16,0,0" Padding="10" HorizontalAlignment="Center" CornerRadius="8" BorderBrush="#DDD" BorderThickness="1">
      <Grid Width="300" Height="300">
        <Image x:Name="QrImg" Stretch="Uniform" RenderOptions.BitmapScalingMode="NearestNeighbor"/>
        <TextBlock x:Name="QrWait" Text="Getting a code from WhatsApp..." HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#666"/>
      </Grid>
    </Border>
    <TextBlock x:Name="LinkStatus" TextWrapping="Wrap" FontSize="12.5" Margin="0,12,0,0" Foreground="#555" HorizontalAlignment="Center" TextAlignment="Center"
               Text="The code refreshes by itself every few seconds."/>
    <Button x:Name="LinkClose" Content="Cancel" Width="100" Height="30" Margin="0,14,0,0" HorizontalAlignment="Right" IsCancel="True"/>
  </StackPanel>
</Window>
'@

function Show-LinkDialog {
    if (-not $script:BridgeOk) { [Windows.MessageBox]::Show('WhatsApp Desk is still starting. Try again in a few seconds.', 'WhatsApp Desk') | Out-Null; return }
    try { $r = Api-Post '/api/accounts/add' $null } catch {
        [Windows.MessageBox]::Show("Couldn't start linking: $($_.Exception.Message)", 'WhatsApp Desk') | Out-Null; return
    }
    $script:LinkId = [string]$r.id
    $script:LinkDone = $false
    $script:LBefore = @($script:Accounts | Where-Object { $_.phone } | ForEach-Object { $_.id })
    $script:LDlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $linkXaml))
    $script:LImg = $script:LDlg.FindName('QrImg'); $script:LWait = $script:LDlg.FindName('QrWait')
    $script:LStatus = $script:LDlg.FindName('LinkStatus'); $script:LBtn = $script:LDlg.FindName('LinkClose')
    $script:LBtn.Add_Click({ $script:LDlg.Close() })
    $script:LTimer = New-Object Windows.Threading.DispatcherTimer
    $script:LTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:LTimer.Add_Tick({
        $img = $script:LImg; $wait = $script:LWait; $status = $script:LStatus; $btn = $script:LBtn; $before = $script:LBefore
        try {
            $st = Api-Get '/api/status'
            $me = @($st.accounts) | Where-Object { $_.id -eq $script:LinkId } | Select-Object -First 1
            $newOne = @($st.accounts) | Where-Object { $_.phone -and ($before -notcontains $_.id) } | Select-Object -First 1
            if ($newOne -and -not $me) {
                $script:LinkDone = $true
                $img.Source = $null; $wait.Text = [string][char]0x2714 + '  Linked'; $wait.Visibility = 'Visible'; $wait.FontSize = 22; $wait.Foreground = Brush '#1DA851'
                $status.Text = "$($newOne.phone) is linked. Your recent chats will appear in the widget over the next few minutes."
                $btn.Content = 'Done'
                $script:LTimer.Stop(); return
            }
            if ($me -and $me.error) { $status.Text = $me.error; $status.Foreground = Brush '#C0392B' }
            if ($me -and $me.has_qr) {
                $bytes = Api-Bytes ('/api/accounts/qr?id=' + [Uri]::EscapeDataString($script:LinkId))
                $ms = New-Object IO.MemoryStream(, $bytes)
                $bmp = New-Object Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $ms; $bmp.EndInit()
                $img.Source = $bmp; $wait.Visibility = 'Collapsed'
            }
        } catch { Write-Log "Link poll: $($_.Exception.Message)" }
    })
    $script:LDlg.Add_ContentRendered({ $script:LTimer.Start() })
    $script:LDlg.Add_Closed({
        $script:LTimer.Stop()
        if (-not $script:LinkDone) { try { [void](Api-Post ('/api/accounts/remove?id=' + [Uri]::EscapeDataString($script:LinkId)) $null) } catch { } }
    })
    [void]$script:LDlg.ShowDialog()
    Refresh-Status; $script:LastChatsJson = ''; Refresh-List
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
            $lnk.Description = 'WhatsApp Desk desktop widget'
            $lnk.Save()
        } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    } catch { [Windows.MessageBox]::Show("Couldn't change the startup setting: $($_.Exception.Message)", 'WhatsApp Desk') | Out-Null }
}
function Save-Position {
    $script:Config.Left = $window.Left; $script:Config.Top = $window.Top
    if ($window.ActualWidth -gt 0) { $script:Config.Width = $window.ActualWidth; $script:Config.Height = $window.ActualHeight }
    Save-Config
}
function Set-Scale { $Root.LayoutTransform = New-Object Windows.Media.ScaleTransform($script:Config.Scale, $script:Config.Scale) }

$menu = New-Object Windows.Controls.ContextMenu
function Add-Item($parent, [string]$header, [scriptblock]$action) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header; if ($action) { $mi.Add_Click($action) }
    [void]$parent.Items.Add($mi); return $mi
}

[void](Add-Item $menu 'Add a WhatsApp number...' { Show-LinkDialog })
$miNumbers = Add-Item $menu 'Your numbers' $null
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
$miSound = Add-Item $menu 'Sound on new messages' { $script:Config.Sound = $this.IsChecked; Save-Config }
$miSound.IsCheckable = $true

$sizeMenu = Add-Item $menu 'Text size' $null
foreach ($opt in @(@('Small', 0.9), @('Normal', 1.0), @('Large', 1.12), @('Extra large', 1.25))) {
    $sm = Add-Item $sizeMenu $opt[0] {
        $script:Config.Scale = [double]$this.Tag; Save-Config; Set-Scale
        foreach ($x in $sizeMenu.Items) { $x.IsChecked = ([double]$x.Tag -eq $script:Config.Scale) }
    }
    $sm.Tag = [double]$opt[1]; $sm.IsCheckable = $true
}
$alphaMenu = Add-Item $menu 'Transparency' $null
foreach ($opt in @(@('Solid', 'F2'), @('Slightly transparent', 'D9'), @('More transparent', 'A6'))) {
    $am = Add-Item $alphaMenu $opt[0] {
        $script:Config.Alpha = [string]$this.Tag; Save-Config; Set-CardAlpha
        foreach ($x in $alphaMenu.Items) { $x.IsChecked = ([string]$x.Tag -eq $script:Config.Alpha) }
    }
    $am.Tag = $opt[1]; $am.IsCheckable = $true
}
$miTop = Add-Item $menu 'Keep on top of other windows' { $script:Config.Topmost = $this.IsChecked; $window.Topmost = $this.IsChecked; Save-Config }
$miTop.IsCheckable = $true
$miStart = Add-Item $menu 'Start with Windows' { Set-Startup $this.IsChecked; $this.IsChecked = (Test-Path $StartupLnk) }
$miStart.IsCheckable = $true
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-Item $menu 'Close WhatsApp Desk' { $window.Close() })

# "Your numbers" submenu is rebuilt each time the menu opens
$menu.Add_Opened({
    $miNumbers.Items.Clear()
    $list = @($script:Accounts | Where-Object { $_.phone })
    if ($list.Count -eq 0) { $e = Add-Item $miNumbers '(none linked yet)' $null; $e.IsEnabled = $false; return }
    foreach ($a in $list) {
        $state = 'connected'
        if ($a.error) { $state = 'needs attention' } elseif (-not $a.connected) { $state = 'connecting' }
        $sub = Add-Item $miNumbers ("{0}  ({1}, {2})" -f (Account-Label $a.id), $a.phone, $state) $null
        $rn = Add-Item $sub 'Rename...' {
            $id = [string]$this.Tag
            $cur = Account-Label $id
            Add-Type -AssemblyName Microsoft.VisualBasic
            $new = [Microsoft.VisualBasic.Interaction]::InputBox('Short name for this number (e.g. Saudi, Canada, Personal):', 'Rename number', $cur)
            if ($new -ne '') { $script:Config.Labels[$id] = $new.Trim(); Save-Config; Draw-Chips; $script:LastChatsJson = ''; Refresh-List }
        }
        $rn.Tag = $a.id
        $rm = Add-Item $sub 'Unlink this number...' {
            $id = [string]$this.Tag
            $ok = [Windows.MessageBox]::Show("Unlink $(Account-Label $id) from WhatsApp Desk?`nIts chats will be removed from this widget (nothing is deleted on your phone).", 'WhatsApp Desk', 'YesNo')
            if ($ok -eq 'Yes') {
                try { [void](Api-Post ('/api/accounts/remove?id=' + [Uri]::EscapeDataString($id)) $null) } catch { }
                if ($script:Filter -eq $id) { $script:Filter = $null }
                Refresh-Status; $script:LastChatsJson = ''; Refresh-List
            }
        }
        $rm.Tag = $a.id
    }
})
$Card.ContextMenu = $menu

# ---------- events ----------
$Header.Add_MouseLeftButtonDown({
    param($s, $e)
    $src = $e.OriginalSource
    $onControl = $false
    try { if ($src -eq $BackBtn -or $Chips.IsAncestorOf($src)) { $onControl = $true } } catch { }
    if (-not $onControl) { try { $window.DragMove(); Save-Position } catch { } }
})
$BackBtn.Add_MouseLeftButtonUp({ param($s, $e) Close-Chat; $e.Handled = $true })
$SendBtn.Add_MouseLeftButtonUp({ param($s, $e) Send-Current; $e.Handled = $true })
$Input.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return' -and -not ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)) { $e.Handled = $true; Send-Current }
    elseif ($e.Key -eq 'Escape') { $e.Handled = $true; Close-Chat }
})
$window.Dispatcher.Add_UnhandledException({ Write-Log "Unhandled: $($_.Exception.Message)"; $_.Handled = $true })

$script:SizeSaveTimer = New-Object Windows.Threading.DispatcherTimer
$script:SizeSaveTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:SizeSaveTimer.Add_Tick({ $script:SizeSaveTimer.Stop(); Save-Position })
$window.Add_SizeChanged({ $script:SizeSaveTimer.Stop(); $script:SizeSaveTimer.Start(); $script:LastMsgsJson = '' })

# ---------- start ----------
Load-Config
Set-CardAlpha; Set-Scale
$miSound.IsChecked = [bool]$script:Config.Sound
$miTop.IsChecked = [bool]$script:Config.Topmost
$miStart.IsChecked = (Test-Path $StartupLnk)
foreach ($x in $sizeMenu.Items) { $x.IsChecked = ([double]$x.Tag -eq $script:Config.Scale) }
foreach ($x in $alphaMenu.Items) { $x.IsChecked = ([string]$x.Tag -eq $script:Config.Alpha) }
$window.Topmost = [bool]$script:Config.Topmost
$window.Width = [math]::Max(270, [double]$script:Config.Width)
$window.Height = [math]::Max(220, [double]$script:Config.Height)

$vs = [Windows.SystemParameters]
$placed = $false
if ($null -ne $script:Config.Left -and $null -ne $script:Config.Top) {
    $l = [double]$script:Config.Left; $t = [double]$script:Config.Top
    if ($l -ge $vs::VirtualScreenLeft - 50 -and $l -le ($vs::VirtualScreenLeft + $vs::VirtualScreenWidth - 100) -and
        $t -ge $vs::VirtualScreenTop - 50 -and $t -le ($vs::VirtualScreenTop + $vs::VirtualScreenHeight - 100)) {
        $window.Left = $l; $window.Top = $t; $placed = $true
    }
}
if (-not $placed) { $wa = $vs::WorkArea; $window.Left = $wa.Left + 16; $window.Top = $wa.Top + 16 }

$poll = New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromSeconds(3)
$script:Tick = 0
$poll.Add_Tick({
    $script:Tick++
    if (-not $script:BridgeOk -or ($script:Tick % 5 -eq 0)) { Refresh-Status }
    if (-not $script:BridgeOk) {
        if ($script:Tick % 10 -eq 0) { [void](Start-Bridge); Refresh-Status }
        return
    }
    if ($script:Open) { Refresh-Messages $false } else { Refresh-List }
})

$window.Add_ContentRendered({
    Show-Empty 'Starting WhatsApp Desk...'
    $window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Render)
    if (-not (Start-Bridge)) { Show-Empty "WhatsApp Desk couldn't start its background program. Check that Windows didn't block WhatsAppDesk-bridge.exe, then reopen." }
    Refresh-Status
    Refresh-List
    $poll.Start()
    if ($script:BridgeOk -and @($script:Accounts).Count -eq 0) { Show-LinkDialog }
})
$window.Add_Closed({
    try { $poll.Stop(); Save-Position } catch { }
    try { [void](Api-Post '/api/quit' $null) } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
})

try { [void]$window.ShowDialog() }
catch {
    Write-Log "Fatal: $($_.Exception.Message)"
    [Windows.MessageBox]::Show("WhatsApp Desk stopped: $($_.Exception.Message)", 'WhatsApp Desk') | Out-Null
}
