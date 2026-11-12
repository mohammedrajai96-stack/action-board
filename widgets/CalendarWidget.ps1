# =====================================================================
#  Calendar Widget for Windows
#  Shows your Google Calendar on the desktop. No browser needed.
#  Uses only what is already built into Windows (PowerShell + WPF).
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, Microsoft.VisualBasic

# ---------- only one copy at a time ----------
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\GoogleCalendarDesktopWidget', [ref]$createdNew)
if (-not $createdNew) { exit }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ScriptDir  = Split-Path -Parent $PSCommandPath
$AppDir     = Join-Path $env:APPDATA 'CalendarWidget'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
$ConfigPath = Join-Path $AppDir 'config.json'
$LogPath    = Join-Path $AppDir 'widget.log'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Calendar Widget.lnk'
$Launcher   = Join-Path $ScriptDir 'Start Calendar Widget.vbs'

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

# ---------- culture (keep Gregorian dates even on Arabic Windows) ----------
$script:Culture = [Globalization.CultureInfo]::CurrentCulture
if (-not ($script:Culture.Calendar -is [Globalization.GregorianCalendar])) {
    $script:Culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
}

# ---------- settings ----------
$script:Config = [ordered]@{
    Calendars = @()
    DaysAhead = 7
    Left      = $null
    Top       = $null
    Topmost   = $false
    Use24h    = $false
    Width     = 360
    Height    = 600
    Scale     = 1.0
}

function Load-Config {
    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $j = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.Calendars) {
            # flatten (older versions could save the list nested) and split into separate links
            $flat = @($j.Calendars | ForEach-Object { $_ } | ForEach-Object { [string]$_ }) -join ' '
            $script:Config.Calendars = [string[]]@($flat -split '\s+' | Where-Object { $_ -match '^(https?|webcal)://' } | Select-Object -Unique)
        }
        if ($j.DaysAhead) { $script:Config.DaysAhead = [int]$j.DaysAhead }
        if ($null -ne $j.Left) { $script:Config.Left = [double]$j.Left }
        if ($null -ne $j.Top)  { $script:Config.Top  = [double]$j.Top }
        if ($null -ne $j.Topmost) { $script:Config.Topmost = [bool]$j.Topmost }
        if ($null -ne $j.Use24h)  { $script:Config.Use24h  = [bool]$j.Use24h }
        if ($j.Width -gt 0)  { $script:Config.Width  = [double]$j.Width }
        if ($j.Height -gt 0) { $script:Config.Height = [double]$j.Height }
        if ($j.Scale -gt 0)  { $script:Config.Scale  = [double]$j.Scale }
    } catch { Write-Log "Could not read settings: $($_.Exception.Message)" }
}

function Save-Config {
    try { $script:Config | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8 }
    catch { Write-Log "Could not save settings: $($_.Exception.Message)" }
}

# ---------- time zones ----------
$IanaMap = @{
    'Asia/Riyadh'='Arab Standard Time'; 'Asia/Kuwait'='Arab Standard Time'; 'Asia/Qatar'='Arab Standard Time'
    'Asia/Bahrain'='Arab Standard Time'; 'Asia/Aden'='Arab Standard Time'; 'Asia/Baghdad'='Arabic Standard Time'
    'Asia/Dubai'='Arabian Standard Time'; 'Asia/Muscat'='Arabian Standard Time'
    'Africa/Cairo'='Egypt Standard Time'; 'Asia/Amman'='Jordan Standard Time'; 'Asia/Beirut'='Middle East Standard Time'
    'Europe/Istanbul'='Turkey Standard Time'; 'Asia/Karachi'='Pakistan Standard Time'; 'Asia/Kolkata'='India Standard Time'
    'Asia/Calcutta'='India Standard Time'; 'Asia/Singapore'='Singapore Standard Time'; 'Asia/Tokyo'='Tokyo Standard Time'
    'Asia/Shanghai'='China Standard Time'; 'Asia/Hong_Kong'='China Standard Time'
    'Europe/London'='GMT Standard Time'; 'Europe/Dublin'='GMT Standard Time'; 'Europe/Lisbon'='GMT Standard Time'
    'Europe/Paris'='Romance Standard Time'; 'Europe/Madrid'='Romance Standard Time'; 'Europe/Brussels'='Romance Standard Time'
    'Europe/Berlin'='W. Europe Standard Time'; 'Europe/Amsterdam'='W. Europe Standard Time'; 'Europe/Rome'='W. Europe Standard Time'
    'Europe/Zurich'='W. Europe Standard Time'; 'Europe/Vienna'='W. Europe Standard Time'; 'Europe/Stockholm'='W. Europe Standard Time'
    'Europe/Athens'='GTB Standard Time'; 'Europe/Moscow'='Russian Standard Time'
    'America/Toronto'='Eastern Standard Time'; 'America/New_York'='Eastern Standard Time'; 'America/Detroit'='Eastern Standard Time'
    'America/Chicago'='Central Standard Time'; 'America/Winnipeg'='Central Standard Time'
    'America/Denver'='Mountain Standard Time'; 'America/Edmonton'='Mountain Standard Time'
    'America/Los_Angeles'='Pacific Standard Time'; 'America/Vancouver'='Pacific Standard Time'
    'America/Halifax'='Atlantic Standard Time'; 'Australia/Sydney'='AUS Eastern Standard Time'
    'UTC'='UTC'; 'Etc/UTC'='UTC'; 'Etc/GMT'='UTC'; 'GMT'='UTC'
}
$script:TzCache = @{}

function Get-WinTz([string]$tzid) {
    if (-not $tzid) { return $null }
    if ($script:TzCache.ContainsKey($tzid)) { return $script:TzCache[$tzid] }
    $id = $tzid
    if ($IanaMap.ContainsKey($tzid)) { $id = $IanaMap[$tzid] }
    $tz = $null
    try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { $tz = $null }
    $script:TzCache[$tzid] = $tz
    return $tz
}

function Convert-Wall([datetime]$wall, [string]$kind, [string]$tzid, [hashtable]$tzOffsets) {
    if ($kind -eq 'utc') {
        return ([DateTime]::SpecifyKind($wall, [DateTimeKind]::Utc)).ToLocalTime()
    }
    if ($kind -eq 'tz') {
        $tz = Get-WinTz $tzid
        if ($null -ne $tz) {
            try {
                return [TimeZoneInfo]::ConvertTime([DateTime]::SpecifyKind($wall, [DateTimeKind]::Unspecified), $tz, [TimeZoneInfo]::Local)
            } catch { }
        }
        if ($tzOffsets -and $tzOffsets.ContainsKey($tzid)) {
            return ([DateTime]::SpecifyKind(($wall - $tzOffsets[$tzid]), [DateTimeKind]::Utc)).ToLocalTime()
        }
        return $wall
    }
    return $wall
}

function To-Local($d, [hashtable]$tzOffsets) {
    return Convert-Wall $d.Wall $d.Kind $d.TzId $tzOffsets
}

# ---------- reading the calendar file (iCal / .ics) ----------
$script:WantedProps = '^(BEGIN|END|DTSTART|DTEND|DURATION|SUMMARY|LOCATION|RRULE|EXDATE|RECURRENCE-ID|UID|STATUS|TZID|TZOFFSETTO)[;:]'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Split-IcsLine([string]$line) {
    $colon = $line.IndexOf(':')
    if ($colon -lt 0) { return $null }
    $quote = $line.IndexOf('"')
    if ($quote -ge 0 -and $quote -lt $colon) {
        $inQ = $false; $colon = -1
        for ($i = 0; $i -lt $line.Length; $i++) {
            $c = $line[$i]
            if ($c -eq '"') { $inQ = -not $inQ }
            elseif ($c -eq ':' -and -not $inQ) { $colon = $i; break }
        }
        if ($colon -lt 0) { return $null }
    }
    $left  = $line.Substring(0, $colon)
    $value = $line.Substring($colon + 1)
    $parts = $left.Split(';')
    $params = @{}
    for ($k = 1; $k -lt $parts.Length; $k++) {
        $kv = $parts[$k].Split([char[]]'=', 2)
        if ($kv.Length -eq 2) { $params[$kv[0].ToUpperInvariant()] = $kv[1] }
    }
    return @{ Name = $parts[0].ToUpperInvariant(); Params = $params; Value = $value }
}

function Parse-IcsDateValue([string]$value, [hashtable]$params) {
    $v = $value.Trim()
    if ((($params) -and $params['VALUE'] -eq 'DATE') -or ($v -match '^\d{8}$')) {
        if ($v.Length -lt 8) { return $null }
        return @{ Wall = [DateTime]::ParseExact($v.Substring(0, 8), 'yyyyMMdd', $Inv); Kind = 'allday'; TzId = $null; AllDay = $true }
    }
    if ($v -match '^(\d{8}T\d{6})(Z?)$') {
        $wall = [DateTime]::ParseExact($matches[1], 'yyyyMMddTHHmmss', $Inv)
        $kind = 'float'; $tzid = $null
        if ($matches[2] -eq 'Z') { $kind = 'utc' }
        elseif ($params -and $params['TZID']) { $kind = 'tz'; $tzid = $params['TZID'].Trim('"') }
        return @{ Wall = $wall; Kind = $kind; TzId = $tzid; AllDay = $false }
    }
    return $null
}

function Parse-Duration([string]$v) {
    if ($v -match '^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$') {
        return New-TimeSpan -Days ([int]$matches[3] + 7 * [int]$matches[2]) -Hours ([int]$matches[4]) -Minutes ([int]$matches[5]) -Seconds ([int]$matches[6])
    }
    return $null
}

function Unescape-Ics([string]$s) {
    if (-not $s) { return '' }
    $s = $s -replace '\\[nN]', ' '
    $s = $s -replace '\\,', ','
    $s = $s -replace '\\;', ';'
    $s = $s -replace '\\\\', '\'
    return $s.Trim()
}

$DayMap = @{ SU = 0; MO = 1; TU = 2; WE = 3; TH = 4; FR = 5; SA = 6 }
$DayCode = @('SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA')

# Works out every date a repeating event happens on.
function Expand-RRule([datetime]$dtStart, [string]$rule, [datetime]$from, [datetime]$to) {
    $r = @{}
    foreach ($part in $rule.Split(';')) {
        $kv = $part.Split([char[]]'=', 2)
        if ($kv.Length -eq 2) { $r[$kv[0].ToUpperInvariant()] = $kv[1].ToUpperInvariant() }
    }
    $out = New-Object System.Collections.Generic.List[datetime]
    $freq = $r['FREQ']
    $interval = 1; if ($r['INTERVAL']) { $interval = [int]$r['INTERVAL'] }; if ($interval -lt 1) { $interval = 1 }
    $count = 0; if ($r['COUNT']) { $count = [int]$r['COUNT'] }
    $limit = $to
    if ($r['UNTIL'] -and ($r['UNTIL'] -match '^(\d{8})(T(\d{6}))?')) {
        if ($matches[3]) { $until = [DateTime]::ParseExact($matches[1] + 'T' + $matches[3], 'yyyyMMddTHHmmss', $Inv) }
        else { $until = [DateTime]::ParseExact($matches[1], 'yyyyMMdd', $Inv).AddDays(1).AddTicks(-1) }
        if ($until -lt $limit) { $limit = $until }
    }
    $byDay = @(); if ($r['BYDAY']) { $byDay = @($r['BYDAY'].Split(',')) }
    $byMonthDay = @(); if ($r['BYMONTHDAY']) { $byMonthDay = @($r['BYMONTHDAY'].Split(',') | ForEach-Object { [int]$_ }) }
    $tod = $dtStart.TimeOfDay
    $emitted = 0; $guard = 0
    $canJump = ($count -eq 0 -and $from -gt $dtStart)

    if ($freq -eq 'DAILY') {
        $codes = @($byDay | ForEach-Object { $_ -replace '^[+-]?\d+', '' })
        $d = $dtStart
        if ($canJump) { $k = [math]::Floor(($from - $dtStart).TotalDays / $interval); $d = $dtStart.AddDays($k * $interval) }
        while ($guard++ -lt 20000) {
            if ($d -gt $limit) { break }
            if ($count -gt 0 -and $emitted -ge $count) { break }
            if ($codes.Count -eq 0 -or ($codes -contains $DayCode[[int]$d.DayOfWeek])) { $out.Add($d); $emitted++ }
            $d = $d.AddDays($interval)
        }
    }
    elseif ($freq -eq 'WEEKLY') {
        $codes = @($byDay | ForEach-Object { $_ -replace '^[+-]?\d+', '' })
        if ($codes.Count -eq 0) { $codes = @($DayCode[[int]$dtStart.DayOfWeek]) }
        $offsets = @($codes | Where-Object { $DayMap.ContainsKey($_) } | ForEach-Object { ($DayMap[$_] + 6) % 7 } | Sort-Object -Unique)
        $weekStart = $dtStart.Date.AddDays(-(([int]$dtStart.DayOfWeek + 6) % 7))
        if ($canJump) {
            $weeks = [math]::Floor(($from - $weekStart).TotalDays / 7)
            $k = [math]::Floor($weeks / $interval)
            $weekStart = $weekStart.AddDays(7 * $interval * $k)
        }
        $stop = $false
        while (-not $stop -and $guard++ -lt 20000) {
            if ($weekStart.Add($tod) -gt $limit) { break }
            foreach ($o in $offsets) {
                $c = $weekStart.AddDays($o).Add($tod)
                if ($c -lt $dtStart) { continue }
                if ($c -gt $limit -or ($count -gt 0 -and $emitted -ge $count)) { $stop = $true; break }
                $out.Add($c); $emitted++
            }
            $weekStart = $weekStart.AddDays(7 * $interval)
        }
    }
    elseif ($freq -eq 'MONTHLY') {
        $m0 = New-Object DateTime ([int]$dtStart.Year), ([int]$dtStart.Month), 1
        if ($canJump) {
            $months = ($from.Year - $m0.Year) * 12 + $from.Month - $m0.Month
            $k = [math]::Floor($months / $interval)
            if ($k -gt 0) { $m0 = $m0.AddMonths([int]($k * $interval)) }
        }
        $stop = $false
        while (-not $stop -and $guard++ -lt 5000) {
            if ($m0 -gt $limit) { break }
            $dim = [DateTime]::DaysInMonth($m0.Year, $m0.Month)
            $days = New-Object System.Collections.Generic.List[int]
            if ($byDay.Count -gt 0) {
                foreach ($bd in $byDay) {
                    if ($bd -match '^([+-]?\d+)?([A-Z]{2})$' -and $DayMap.ContainsKey($matches[2])) {
                        $n = 0; if ($matches[1]) { $n = [int]$matches[1] }
                        $wd = $DayMap[$matches[2]]
                        $first = (($wd - [int]$m0.DayOfWeek) + 7) % 7 + 1
                        $all = @(); for ($dd = $first; $dd -le $dim; $dd += 7) { $all += $dd }
                        if ($n -eq 0) { foreach ($a in $all) { $days.Add($a) } }
                        elseif ($n -gt 0 -and $n -le $all.Count) { $days.Add($all[$n - 1]) }
                        elseif ($n -lt 0 -and (-$n) -le $all.Count) { $days.Add($all[$all.Count + $n]) }
                    }
                }
            }
            elseif ($byMonthDay.Count -gt 0) {
                foreach ($md in $byMonthDay) {
                    if ($md -gt 0 -and $md -le $dim) { $days.Add($md) }
                    elseif ($md -lt 0 -and (-$md) -le $dim) { $days.Add($dim + $md + 1) }
                }
            }
            elseif ($dtStart.Day -le $dim) { $days.Add($dtStart.Day) }
            foreach ($dd in ($days | Sort-Object -Unique)) {
                $c = $m0.AddDays($dd - 1).Add($tod)
                if ($c -lt $dtStart) { continue }
                if ($c -gt $limit -or ($count -gt 0 -and $emitted -ge $count)) { $stop = $true; break }
                $out.Add($c); $emitted++
            }
            $m0 = $m0.AddMonths($interval)
        }
    }
    elseif ($freq -eq 'YEARLY') {
        $y = $dtStart.Year
        if ($canJump) { $k = [math]::Floor(($from.Year - $y) / $interval); if ($k -gt 0) { $y += [int]($k * $interval) } }
        while ($guard++ -lt 2000) {
            if ($y -gt $limit.Year) { break }
            if (-not ($dtStart.Month -eq 2 -and $dtStart.Day -eq 29 -and -not [DateTime]::IsLeapYear($y))) {
                $c = (New-Object DateTime ([int]$y), ([int]$dtStart.Month), ([int]$dtStart.Day)).Add($tod)
                if ($c -ge $dtStart) {
                    if ($c -gt $limit -or ($count -gt 0 -and $emitted -ge $count)) { break }
                    $out.Add($c); $emitted++
                }
            }
            $y += $interval
        }
    }
    else { $out.Add($dtStart) }
    return , $out
}

function Parse-Ics([string]$text, [string]$color, [datetime]$winStart, [datetime]$winEnd) {
    $text  = $text -replace "\r?\n[ \t]", ''
    $lines = $text -split "\r?\n"
    $tzOffsets = @{}
    $raw = New-Object System.Collections.Generic.List[object]
    $cur = $null; $inTz = $false; $tzId = $null; $tzSub = $null; $inAlarm = $false

    foreach ($line in $lines) {
        if ($line -notmatch $script:WantedProps) { continue }
        $p = Split-IcsLine $line
        if ($null -eq $p) { continue }
        $name = $p.Name; $val = $p.Value

        if ($name -eq 'BEGIN') {
            $v = $val.Trim().ToUpperInvariant()
            if ($v -eq 'VEVENT') { $cur = @{ ExDates = (New-Object System.Collections.Generic.List[object]) }; $inAlarm = $false }
            elseif ($v -eq 'VTIMEZONE') { $inTz = $true; $tzId = $null; $tzSub = $null }
            elseif ($inTz) { $tzSub = $v }
            elseif ($null -ne $cur) { $inAlarm = $true }
        }
        elseif ($name -eq 'END') {
            $v = $val.Trim().ToUpperInvariant()
            if ($v -eq 'VEVENT') { if ($null -ne $cur) { $raw.Add($cur) }; $cur = $null; $inAlarm = $false }
            elseif ($v -eq 'VTIMEZONE') { $inTz = $false; $tzSub = $null }
            elseif ($inTz) { $tzSub = $null }
            elseif ($null -ne $cur) { $inAlarm = $false }
        }
        elseif ($inTz) {
            if ($name -eq 'TZID' -and -not $tzSub) { $tzId = $val.Trim() }
            elseif ($name -eq 'TZOFFSETTO' -and $tzSub -eq 'STANDARD' -and $tzId) {
                if ($val.Trim() -match '^([+-])(\d{2})(\d{2})') {
                    $ts = New-TimeSpan -Hours ([int]$matches[2]) -Minutes ([int]$matches[3])
                    if ($matches[1] -eq '-') { $ts = $ts.Negate() }
                    $tzOffsets[$tzId] = $ts
                }
            }
        }
        elseif ($null -ne $cur -and -not $inAlarm) {
            switch ($name) {
                'DTSTART'       { $cur.Start = Parse-IcsDateValue $val $p.Params }
                'DTEND'         { $cur.End = Parse-IcsDateValue $val $p.Params }
                'DURATION'      { $cur.Duration = Parse-Duration $val.Trim() }
                'SUMMARY'       { $cur.Title = Unescape-Ics $val }
                'LOCATION'      { $cur.Location = Unescape-Ics $val }
                'RRULE'         { $cur.RRule = $val.Trim() }
                'EXDATE'        { foreach ($x in $val.Split(',')) { $d = Parse-IcsDateValue $x $p.Params; if ($d) { $cur.ExDates.Add($d) } } }
                'RECURRENCE-ID' { $cur.RecurId = Parse-IcsDateValue $val $p.Params }
                'UID'           { $cur.Uid = $val.Trim() }
                'STATUS'        { $cur.Status = $val.Trim().ToUpperInvariant() }
            }
        }
    }

    # single changed/cancelled instances of a repeating event
    $overrideKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $raw) {
        if ($e.RecurId -and $e.Uid) { [void]$overrideKeys.Add($e.Uid + '|' + (To-Local $e.RecurId $tzOffsets).Ticks) }
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $raw) {
        if (-not $e.Start) { continue }
        if ($e.Status -eq 'CANCELLED') { continue }
        $title = '(No title)'; if ($e.Title) { $title = $e.Title }
        $allDay = [bool]$e.Start.AllDay
        $startLocal = To-Local $e.Start $tzOffsets

        if ($allDay) {
            $dur = New-TimeSpan -Days 1
            if ($e.End) { $dur = $e.End.Wall - $e.Start.Wall } elseif ($e.Duration) { $dur = $e.Duration }
            if ($dur.TotalDays -lt 1) { $dur = New-TimeSpan -Days 1 }
        } else {
            $dur = [TimeSpan]::Zero
            if ($e.End) { $dur = (To-Local $e.End $tzOffsets) - $startLocal } elseif ($e.Duration) { $dur = $e.Duration }
            if ($dur.Ticks -lt 0) { $dur = [TimeSpan]::Zero }
        }

        $starts = New-Object System.Collections.Generic.List[datetime]
        if ($e.RRule -and -not $e.RecurId) {
            $ex = New-Object 'System.Collections.Generic.HashSet[long]'
            foreach ($x in $e.ExDates) { [void]$ex.Add((To-Local $x $tzOffsets).Ticks) }
            $walls = Expand-RRule $e.Start.Wall $e.RRule $winStart.AddDays(-2) $winEnd.AddDays(2)
            foreach ($w in $walls) {
                $l = Convert-Wall $w $e.Start.Kind $e.Start.TzId $tzOffsets
                if ($ex.Contains($l.Ticks)) { continue }
                if ($e.Uid -and $overrideKeys.Contains($e.Uid + '|' + $l.Ticks)) { continue }
                $starts.Add($l)
            }
        } else {
            $starts.Add($startLocal)
        }

        foreach ($s in $starts) {
            $en = $s + $dur
            if ($dur.Ticks -eq 0) { $visible = ($s -ge $winStart -and $s -lt $winEnd) }
            else { $visible = ($en -gt $winStart -and $s -lt $winEnd) }
            if ($visible) {
                $out.Add([pscustomobject]@{ Start = $s; End = $en; AllDay = $allDay; Title = $title; Location = $e.Location; Color = $color })
            }
        }
    }
    return , $out
}

# ---------- downloading ----------
function Get-UrlKey([string]$url) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($url))
    return (-join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') }))
}

function Get-IcsText([string]$url) {
    $cacheFile = Join-Path $AppDir ('cache_' + (Get-UrlKey $url) + '.ics')
    $u = $url.Trim()
    if ($u -like 'webcal://*') { $u = 'https://' + $u.Substring(9) }
    try {
        $req = [Net.HttpWebRequest]::Create($u)
        $req.Timeout = 20000
        $req.UserAgent = 'CalendarWidget/1.0'
        $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $resp = $req.GetResponse()
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
        if ($text -notmatch 'BEGIN:VCALENDAR') { throw 'That link did not return a calendar.' }
        [IO.File]::WriteAllText($cacheFile, $text, [Text.Encoding]::UTF8)
        return @{ Text = $text; Ok = $true; Err = $null }
    } catch {
        $err = $_.Exception.Message
        Write-Log "Download failed: $err"
        if (Test-Path $cacheFile) { return @{ Text = [IO.File]::ReadAllText($cacheFile, [Text.Encoding]::UTF8); Ok = $false; Err = $err } }
        return @{ Text = $null; Ok = $false; Err = $err }
    }
}

# ---------- the window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Calendar Widget" Width="360" Height="600" MinWidth="230" MinHeight="96"
        WindowStyle="None" AllowsTransparency="True" Background="#01000000"
        ShowInTaskbar="False" ResizeMode="CanResize" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="12" GlassFrameThickness="0" CornerRadius="0"/>
  </WindowChrome.WindowChrome>
  <Border x:Name="Card" CornerRadius="18" Background="#EB15181E" BorderBrush="#26FFFFFF"
          BorderThickness="1" Padding="20,16,20,14" Margin="10">
    <Border.Effect>
      <DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.45" Color="Black"/>
    </Border.Effect>
    <DockPanel x:Name="Inner" LastChildFill="True">
      <Grid DockPanel.Dock="Top">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="BigDay" Grid.Column="0" FontSize="44" FontWeight="Light" Foreground="#FFFFFF"
                   VerticalAlignment="Center" Margin="0,-6,12,-4"/>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock x:Name="DayName" FontSize="12" FontWeight="SemiBold" Foreground="#7FB2FF"/>
          <TextBlock x:Name="MonthYear" FontSize="14" Foreground="#C9CFDA" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <TextBlock x:Name="Clock" Grid.Column="2" FontSize="22" FontWeight="Light" Foreground="#FFFFFF"
                   VerticalAlignment="Center" Margin="8,0,0,0"/>
      </Grid>
      <Border x:Name="NextBox" DockPanel.Dock="Top" CornerRadius="10" Background="#1F7FB2FF" Padding="10,7" Margin="0,12,0,0" Visibility="Collapsed">
        <TextBlock x:Name="NextText" FontSize="12" Foreground="#CFE1FF" TextTrimming="CharacterEllipsis"/>
      </Border>
      <Border x:Name="Divider" DockPanel.Dock="Top" Height="1" Background="#1FFFFFFF" Margin="0,12,0,2"/>
      <TextBlock x:Name="Status" DockPanel.Dock="Bottom" FontSize="10.5" Foreground="#6E7684" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
      <WrapPanel x:Name="Legend" DockPanel.Dock="Bottom" Margin="0,10,0,0"/>
      <ScrollViewer x:Name="Scroller" VerticalScrollBarVisibility="Hidden">
        <StackPanel x:Name="List"/>
      </ScrollViewer>
    </DockPanel>
  </Border>
</Window>
'@

$window    = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$Card      = $window.FindName('Card')
$BigDay    = $window.FindName('BigDay')
$DayName   = $window.FindName('DayName')
$MonthYear = $window.FindName('MonthYear')
$Clock     = $window.FindName('Clock')
$NextBox   = $window.FindName('NextBox')
$NextText  = $window.FindName('NextText')
$List      = $window.FindName('List')
$Status    = $window.FindName('Status')
$Legend    = $window.FindName('Legend')
$Inner     = $window.FindName('Inner')
$Divider   = $window.FindName('Divider')
$Scroller  = $window.FindName('Scroller')
$script:Compact = $false
$script:CalNames = @()

$script:BrushConv = New-Object Windows.Media.BrushConverter
function Brush([string]$hex) { return $script:BrushConv.ConvertFromString($hex) }
$Palette = @('#4F8EF7', '#34C38F', '#F7B84B', '#F46A6A', '#A66EF7', '#36C2CF', '#F78FB3', '#9BC53D',
             '#FF9F5A', '#7C8CF8', '#E0C341', '#5AD1A5')

function Fmt-Time([datetime]$t) {
    if ($script:Config.Use24h) { return $t.ToString('HH:mm', $script:Culture) }
    return $t.ToString('h:mm tt', $script:Culture)
}

function New-Text([string]$text, [double]$size, [string]$color) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = Brush $color
    return $tb
}

function New-EventRow($o, [datetime]$now) {
    $g = New-Object Windows.Controls.Grid
    $g.Margin = New-Object Windows.Thickness(0, 5, 0, 5)
    foreach ($w in @(4, 78)) {
        $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength($w); $g.ColumnDefinitions.Add($cd)
    }
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star); $g.ColumnDefinitions.Add($cd)

    $bar = New-Object Windows.Controls.Border
    $bar.Width = 4; $bar.CornerRadius = New-Object Windows.CornerRadius(2); $bar.Background = Brush $o.Color
    $bar.Margin = New-Object Windows.Thickness(0, 2, 0, 2)
    [Windows.Controls.Grid]::SetColumn($bar, 0); [void]$g.Children.Add($bar)

    $timePanel = New-Object Windows.Controls.StackPanel
    $timePanel.Margin = New-Object Windows.Thickness(10, 0, 6, 0)
    if ($o.AllDay) {
        [void]$timePanel.Children.Add((New-Text 'All day' 12 '#C9CFDA'))
    } else {
        $startTxt = Fmt-Time $o.Start
        if ($o.Start.Date -lt $now.Date) { $startTxt = $o.Start.ToString('d MMM', $script:Culture) }
        [void]$timePanel.Children.Add((New-Text $startTxt 12 '#E6E9EF'))
        if ($o.End -gt $o.Start) {
            $endTxt = Fmt-Time $o.End
            if ($o.End.Date -ne $o.Start.Date) { $endTxt = $o.End.ToString('d MMM', $script:Culture) + ' ' + $endTxt }
            [void]$timePanel.Children.Add((New-Text $endTxt 10.5 '#7D8594'))
        }
    }
    [Windows.Controls.Grid]::SetColumn($timePanel, 1); [void]$g.Children.Add($timePanel)

    $info = New-Object Windows.Controls.StackPanel
    $titleRow = New-Object Windows.Controls.WrapPanel
    $isNow = (-not $o.AllDay) -and $o.Start -le $now -and $o.End -gt $now
    if ($isNow) {
        $badge = New-Object Windows.Controls.Border
        $badge.Background = Brush '#7FB2FF'; $badge.CornerRadius = New-Object Windows.CornerRadius(4)
        $badge.Padding = New-Object Windows.Thickness(5, 0, 5, 1); $badge.Margin = New-Object Windows.Thickness(0, 1, 6, 0)
        $bt = New-Text 'NOW' 9.5 '#0E1116'; $bt.FontWeight = [Windows.FontWeights]::Bold
        $badge.Child = $bt; $badge.VerticalAlignment = 'Center'
        [void]$titleRow.Children.Add($badge)
    }
    $t = New-Text $o.Title 13 '#F2F4F8'
    $t.FontWeight = [Windows.FontWeights]::SemiBold; $t.TextWrapping = 'Wrap'
    [void]$titleRow.Children.Add($t)
    [void]$info.Children.Add($titleRow)
    if ($o.Location) {
        $loc = New-Text $o.Location 11 '#8A93A3'
        $loc.TextTrimming = 'CharacterEllipsis'; $loc.Margin = New-Object Windows.Thickness(0, 1, 0, 0)
        [void]$info.Children.Add($loc)
    }
    [Windows.Controls.Grid]::SetColumn($info, 2); [void]$g.Children.Add($info)

    $tip = $o.Title
    if ($o.AllDay) { $tip += "`nAll day" } else { $tip += "`n" + $o.Start.ToString('ddd d MMM', $script:Culture) + ', ' + (Fmt-Time $o.Start) + ' - ' + (Fmt-Time $o.End) }
    if ($o.Location) { $tip += "`n" + $o.Location }
    $g.ToolTip = $tip

    $isPast = (-not $o.AllDay) -and ($o.End -le $now) -and ($o.Start -lt $now)
    if ($isPast) { $g.Opacity = 0.42 }
    return $g
}

$script:Occurrences = New-Object System.Collections.Generic.List[object]
$script:LastSync = $null
$script:SyncErrors = @()

function Render {
    try {
        $now = Get-Date
        $BigDay.Text    = $now.Day.ToString()
        $DayName.Text   = $now.ToString('dddd', $script:Culture).ToUpper()
        $MonthYear.Text = $now.ToString('MMMM yyyy', $script:Culture)
        $Clock.Text     = Fmt-Time $now
        $List.Children.Clear()

        if (@($script:Config.Calendars).Count -eq 0) {
            $h = New-Text "No calendar connected yet.`nRight-click here and choose `"Add or remove calendars`"." 12.5 '#C9CFDA'
            $h.TextWrapping = 'Wrap'; $h.Margin = New-Object Windows.Thickness(0, 10, 0, 4)
            [void]$List.Children.Add($h)
            $NextBox.Visibility = 'Collapsed'
            $Legend.Children.Clear()
            $Status.Text = 'Right-click for options'
            return
        }

        $occ = $script:Occurrences
        for ($d = 0; $d -lt $script:Config.DaysAhead; $d++) {
            $day = $now.Date.AddDays($d); $next = $day.AddDays(1)
            $items = @($occ | Where-Object {
                ($_.AllDay -and $_.Start -lt $next -and $_.End -gt $day) -or
                ((-not $_.AllDay) -and (($_.Start -ge $day -and $_.Start -lt $next) -or ($d -eq 0 -and $_.Start -lt $day -and $_.End -gt $now)))
            } | Sort-Object @{ Expression = { -not $_.AllDay } }, Start, Title)

            if ($items.Count -eq 0 -and $d -ne 0) { continue }

            $label = $day.ToString('ddd d MMM', $script:Culture).ToUpper()
            if ($d -eq 0) { $label = 'TODAY  ·  ' + $label }
            elseif ($d -eq 1) { $label = 'TOMORROW  ·  ' + $label }
            $hdr = New-Text $label 10.5 '#8A93A3'
            $hdr.FontWeight = [Windows.FontWeights]::SemiBold
            $hdr.Margin = New-Object Windows.Thickness(0, 12, 0, 3)
            [void]$List.Children.Add($hdr)

            if ($items.Count -eq 0) {
                $e = New-Text 'Nothing scheduled' 12.5 '#6E7684'
                $e.Margin = New-Object Windows.Thickness(0, 4, 0, 4); $e.FontStyle = [Windows.FontStyles]::Italic
                [void]$List.Children.Add($e)
            }
            foreach ($o in $items) { [void]$List.Children.Add((New-EventRow $o $now)) }
        }

        # colour key: which colour is which calendar
        $Legend.Children.Clear()
        if (@($script:CalNames).Count -gt 1) {
            foreach ($c in $script:CalNames) {
                $sp = New-Object Windows.Controls.StackPanel
                $sp.Orientation = 'Horizontal'; $sp.Margin = New-Object Windows.Thickness(0, 2, 12, 2)
                $dot = New-Object Windows.Shapes.Ellipse
                $dot.Width = 8; $dot.Height = 8; $dot.Fill = Brush $c.Color
                $dot.Margin = New-Object Windows.Thickness(0, 0, 5, 0); $dot.VerticalAlignment = 'Center'
                [void]$sp.Children.Add($dot)
                $nameColor = '#9AA3B2'; if (-not $c.Ok) { $nameColor = '#F7B84B' }
                [void]$sp.Children.Add((New-Text $c.Name 10.5 $nameColor))
                [void]$Legend.Children.Add($sp)
            }
        }

        # "Next up" banner
        $up = $occ | Where-Object { (-not $_.AllDay) -and $_.Start -gt $now } | Sort-Object Start | Select-Object -First 1
        if ($up) {
            $mins = [math]::Ceiling(($up.Start - $now).TotalMinutes)
            if ($mins -lt 60) { $when = "in $mins min" }
            elseif ($up.Start.Date -eq $now.Date) { $when = 'at ' + (Fmt-Time $up.Start) }
            elseif ($up.Start.Date -eq $now.Date.AddDays(1)) { $when = 'tomorrow, ' + (Fmt-Time $up.Start) }
            else { $when = $up.Start.ToString('ddd', $script:Culture) + ', ' + (Fmt-Time $up.Start) }
            $NextText.Text = "Next:  $($up.Title)  ·  $when"
            if ($script:Compact) { $NextBox.Visibility = 'Collapsed'; $MonthYear.Text = "Next: $($up.Title) · $when" }
            else { $NextBox.Visibility = 'Visible' }
        } else {
            $NextBox.Visibility = 'Collapsed'
            if ($script:Compact) { $MonthYear.Text = 'No upcoming events' }
        }

        if ($script:SyncErrors.Count -gt 0) {
            $bad = @($script:SyncErrors | Where-Object { $_ -match '404|403|did not return' }).Count
            if ($bad -gt 0) { $Status.Text = "$bad calendar link(s) not working - copy them again from Google" }
            else { $Status.Text = "Offline - showing last saved copy. Right-click > Refresh now" }
            $Status.Foreground = Brush '#F7B84B'
            $Status.ToolTip = ($script:SyncErrors -join "`n")
        } elseif ($script:LastSync) {
            $Status.Text = 'Updated ' + (Fmt-Time $script:LastSync) + '  ·  right-click for options'
            $Status.Foreground = Brush '#6E7684'
        }
    } catch { Write-Log "Render error: $($_.Exception.Message)" }
}

function Refresh-Data {
    try {
        $Status.Text = 'Refreshing...'
        $window.Dispatcher.Invoke([Action] {}, [Windows.Threading.DispatcherPriority]::Render)
        $winStart = (Get-Date).Date.AddDays(-1)
        $winEnd   = (Get-Date).Date.AddDays($script:Config.DaysAhead + 1)
        $all = New-Object System.Collections.Generic.List[object]
        $errs = @()
        $names = @()
        $cals = @($script:Config.Calendars)
        for ($i = 0; $i -lt $cals.Count; $i++) {
            $res = Get-IcsText $cals[$i]
            if (-not $res.Ok) { $errs += "Calendar $($i + 1): $($res.Err)" }
            $calName = "Calendar $($i + 1)"
            if ($res.Text -and ($res.Text -match '(?m)^X-WR-CALNAME:(.+?)\r?$')) { $calName = Unescape-Ics $matches[1] }
            $names += [pscustomobject]@{ Name = $calName; Color = $Palette[$i % $Palette.Count]; Ok = [bool]$res.Ok }
            if ($res.Text) {
                try {
                    $occ = Parse-Ics $res.Text $Palette[$i % $Palette.Count] $winStart $winEnd
                    foreach ($o in $occ) { $all.Add($o) }
                } catch {
                    $errs += "Calendar $($i + 1): could not be read"
                    Write-Log "Parse error: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
                }
            }
        }
        $script:Occurrences = $all
        $script:SyncErrors = $errs
        $script:CalNames = $names
        if ($errs.Count -eq 0) { $script:LastSync = Get-Date }
    } catch { Write-Log "Refresh error: $($_.Exception.Message)" }
    Render
}

# ---------- menu actions ----------
[xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Your calendars" Width="640" Height="480" MinWidth="420" MinHeight="320"
        WindowStartupLocation="CenterScreen" Topmost="True" FontFamily="Segoe UI" Background="#F7F8FA">
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,10">
      <TextBlock FontSize="16" FontWeight="SemiBold" Text="Paste ALL your calendar links below - one link per line"/>
      <TextBlock TextWrapping="Wrap" Margin="0,8,0,0" FontSize="12.5" Foreground="#444">
        Google gives each calendar its own link. For every calendar you want to see:
        Google Calendar on the web &gt; gear icon &gt; Settings &gt; click the calendar on the left &gt;
        scroll to "Integrate calendar" &gt; copy "Secret address in iCal format"
        (for holiday calendars or calendars shared with you, use "Public address in iCal format" if there is no secret one).
        Paste each one on its own line here. To remove a calendar, delete its line.
      </TextBlock>
    </StackPanel>
    <TextBox x:Name="Links" Grid.Row="1" AcceptsReturn="True" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="6"/>
    <DockPanel Grid.Row="2" Margin="0,12,0,0" LastChildFill="False">
      <TextBlock x:Name="Count" DockPanel.Dock="Left" VerticalAlignment="Center" Foreground="#666"/>
      <Button x:Name="Cancel" DockPanel.Dock="Right" Content="Cancel" Width="90" Height="30" Margin="8,0,0,0" IsCancel="True"/>
      <Button x:Name="Save" DockPanel.Dock="Right" Content="Save" Width="90" Height="30" IsDefault="True"/>
    </DockPanel>
  </Grid>
</Window>
'@

function Get-LinksFromText([string]$text) {
    $seen = @{}; $list = @()
    foreach ($tok in ($text -split '\s+')) {
        $t = $tok.Trim().Trim('"', "'", ',', ';')
        if ($t -match '^(https?|webcal)://' -and -not $seen.ContainsKey($t)) { $seen[$t] = $true; $list += $t }
    }
    return $list
}

function Show-CalendarDialog {
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dlgXaml))
    $links = $dlg.FindName('Links'); $count = $dlg.FindName('Count')
    $links.Text = (@($script:Config.Calendars) -join "`r`n")
    $updateCount = { $n = (Get-LinksFromText $links.Text).Count; $count.Text = "$n calendar link(s) found" }
    $links.Add_TextChanged($updateCount)
    & $updateCount
    $script:DlgResult = $false
    $dlg.FindName('Save').Add_Click({ $script:DlgResult = $true; $dlg.Close() })
    $dlg.Add_ContentRendered({ $links.Focus(); $links.CaretIndex = $links.Text.Length })
    [void]$dlg.ShowDialog()
    if (-not $script:DlgResult) { return $false }
    $script:Config.Calendars = [string[]]@(Get-LinksFromText $links.Text)
    Save-Config
    return $true
}

function Set-Startup([bool]$on) {
    try {
        if ($on) {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut($StartupLnk)
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $lnk.Arguments = '"' + $Launcher + '"'
            $lnk.WorkingDirectory = $ScriptDir
            $lnk.Description = 'Google Calendar desktop widget'
            $lnk.Save()
        } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    } catch { [Windows.MessageBox]::Show("Couldn't change the startup setting: $($_.Exception.Message)", 'Calendar Widget') | Out-Null }
}

function Save-Position {
    $script:Config.Left = $window.Left; $script:Config.Top = $window.Top
    if ($window.ActualWidth -gt 0) { $script:Config.Width = $window.ActualWidth; $script:Config.Height = $window.ActualHeight }
    Save-Config
}

function Set-Scale {
    $Inner.LayoutTransform = New-Object Windows.Media.ScaleTransform($script:Config.Scale, $script:Config.Scale)
}

# Shrink it short enough and it becomes a single row (date, clock and next event only)
function Update-Layout {
    $compact = ($window.ActualHeight -lt (175 * $script:Config.Scale))
    if ($compact -ne $script:Compact) {
        $script:Compact = $compact
        $vis = 'Visible'; if ($compact) { $vis = 'Collapsed' }
        foreach ($el in @($Divider, $Scroller, $Legend, $Status)) { $el.Visibility = $vis }
        if ($compact) { $Card.Padding = New-Object Windows.Thickness(18, 8, 18, 8) }
        else { $Card.Padding = New-Object Windows.Thickness(20, 16, 20, 14) }
        Render
    }
}

$menu = New-Object Windows.Controls.ContextMenu
function Add-Item([string]$header, [scriptblock]$action) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header; $mi.Add_Click($action)
    [void]$menu.Items.Add($mi); return $mi
}

[void](Add-Item 'Refresh now' { Refresh-Data })
[void](Add-Item 'Open Google Calendar' { Start-Process 'https://calendar.google.com' })
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-Item 'Add or remove calendars...' { if (Show-CalendarDialog) { Refresh-Data } })
[void](Add-Item 'Remove all calendar links' {
    $r = [Windows.MessageBox]::Show('Remove all calendar links from the widget?', 'Calendar Widget', 'YesNo')
    if ($r -eq 'Yes') { $script:Config.Calendars = @(); Save-Config; $script:Occurrences = New-Object System.Collections.Generic.List[object]; Render }
})

$daysMenu = New-Object Windows.Controls.MenuItem; $daysMenu.Header = 'Show days ahead'
foreach ($n in @(3, 7, 14)) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = "$n days"; $mi.Tag = $n; $mi.IsCheckable = $true
    $mi.IsChecked = ($script:Config.DaysAhead -eq $n)
    $mi.Add_Click({
        $script:Config.DaysAhead = [int]$this.Tag; Save-Config
        foreach ($s in $daysMenu.Items) { $s.IsChecked = ([int]$s.Tag -eq $script:Config.DaysAhead) }
        Refresh-Data
    })
    [void]$daysMenu.Items.Add($mi)
}
[void]$menu.Items.Add($daysMenu)

$sizeMenu = New-Object Windows.Controls.MenuItem; $sizeMenu.Header = 'Text size'
foreach ($opt in @(@('Small', 0.85), @('Normal', 1.0), @('Large', 1.15), @('Extra large', 1.3))) {
    $sm = New-Object Windows.Controls.MenuItem
    $sm.Header = $opt[0]; $sm.Tag = [double]$opt[1]; $sm.IsCheckable = $true
    $sm.Add_Click({
        $script:Config.Scale = [double]$this.Tag; Save-Config; Set-Scale
        foreach ($x in $sizeMenu.Items) { $x.IsChecked = ([double]$x.Tag -eq $script:Config.Scale) }
        Update-Layout
    })
    [void]$sizeMenu.Items.Add($sm)
}
[void]$menu.Items.Add($sizeMenu)

$mi24 = Add-Item '24-hour clock' { $script:Config.Use24h = $this.IsChecked; Save-Config; Render }
$mi24.IsCheckable = $true
$miTop = Add-Item 'Keep on top of other windows' { $script:Config.Topmost = $this.IsChecked; $window.Topmost = $this.IsChecked; Save-Config }
$miTop.IsCheckable = $true
$miStart = Add-Item 'Start with Windows' { Set-Startup $this.IsChecked; $this.IsChecked = (Test-Path $StartupLnk) }
$miStart.IsCheckable = $true
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-Item 'Close widget' { $window.Close() })
$Card.ContextMenu = $menu

# ---------- start up ----------
Load-Config
$mi24.IsChecked    = [bool]$script:Config.Use24h
$miTop.IsChecked   = [bool]$script:Config.Topmost
$miStart.IsChecked = (Test-Path $StartupLnk)
foreach ($s in $daysMenu.Items) { $s.IsChecked = ([int]$s.Tag -eq $script:Config.DaysAhead) }
foreach ($x in $sizeMenu.Items) { $x.IsChecked = ([double]$x.Tag -eq $script:Config.Scale) }
$window.Width  = [math]::Max(230, [double]$script:Config.Width)
$window.Height = [math]::Max(96, [double]$script:Config.Height)
Set-Scale
$window.Topmost = [bool]$script:Config.Topmost

$vs = [Windows.SystemParameters]
$placed = $false
if ($null -ne $script:Config.Left -and $null -ne $script:Config.Top) {
    $l = [double]$script:Config.Left; $t = [double]$script:Config.Top
    if ($l -ge $vs::VirtualScreenLeft - 50 -and $l -le ($vs::VirtualScreenLeft + $vs::VirtualScreenWidth - 100) -and
        $t -ge $vs::VirtualScreenTop - 50 -and $t -le ($vs::VirtualScreenTop + $vs::VirtualScreenHeight - 100)) {
        $window.Left = $l; $window.Top = $t; $placed = $true
    }
}
if (-not $placed) {
    $wa = $vs::WorkArea
    $window.Left = $wa.Right - $window.Width - 16
    $window.Top  = $wa.Top + 16
}

$Card.Add_MouseLeftButtonDown({ try { $window.DragMove(); Save-Position } catch { } })
$window.Add_SizeChanged({ Update-Layout })
$script:SizeSaveTimer = New-Object Windows.Threading.DispatcherTimer
$script:SizeSaveTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:SizeSaveTimer.Add_Tick({ $script:SizeSaveTimer.Stop(); Save-Position })
$window.Add_SizeChanged({ $script:SizeSaveTimer.Stop(); $script:SizeSaveTimer.Start() })

$window.Dispatcher.Add_UnhandledException({ Write-Log "Unhandled: $($_.Exception.Message)"; $_.Handled = $true })

$clockTimer = New-Object Windows.Threading.DispatcherTimer
$clockTimer.Interval = [TimeSpan]::FromSeconds(30)
$clockTimer.Add_Tick({ Render })

$syncTimer = New-Object Windows.Threading.DispatcherTimer
$syncTimer.Interval = [TimeSpan]::FromMinutes(10)
$syncTimer.Add_Tick({ Refresh-Data })

$window.Add_ContentRendered({
    Update-Layout
    if (@($script:Config.Calendars).Count -eq 0) { [void](Show-CalendarDialog) }
    Refresh-Data
    $clockTimer.Start(); $syncTimer.Start()
})
$window.Add_Closed({
    try { $clockTimer.Stop(); $syncTimer.Stop(); Save-Position } catch { }
    try { $script:Mutex.ReleaseMutex() } catch { }
})

Render
try { [void]$window.ShowDialog() }
catch {
    Write-Log "Fatal: $($_.Exception.Message)"
    [Windows.MessageBox]::Show("The calendar widget stopped: $($_.Exception.Message)", 'Calendar Widget') | Out-Null
}
