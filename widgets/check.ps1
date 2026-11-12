$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$fail = 0
foreach ($f in Get-ChildItem "$PSScriptRoot\*.ps1" | Where-Object Name -ne 'check.ps1') {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { $fail++; foreach ($e in $errs) { "PARSE ERROR $($f.Name) line $($e.Extent.StartLineNumber): $($e.Message)" } }
    else { "parse ok: $($f.Name)" }
    $text = Get-Content $f.FullName -Raw
    foreach ($m in [regex]::Matches($text, "(?s)\[xml\]\`$(\w+)\s*=\s*@'\r?\n(.*?)\r?\n'@")) {
        try { $x = [xml]$m.Groups[2].Value; [void][Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x)); "xaml ok: $($f.Name) / $($m.Groups[1].Value)" }
        catch { $fail++; "XAML ERROR $($f.Name) / $($m.Groups[1].Value): $($_.Exception.InnerException.Message) $($_.Exception.Message)" }
    }
}
if ($fail) { exit 1 }
