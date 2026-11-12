$ErrorActionPreference = 'Stop'
Start-Process -FilePath "$PSScriptRoot\..\WhatsAppDesk-bridge.exe" -WindowStyle Hidden
Start-Sleep 5
$tok = (Get-Content "$env:APPDATA\WhatsAppDesk\token.txt" -Raw).Trim()
function W { $wc = New-Object System.Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8; $wc.Headers.Add('X-Token', $tok); $wc }
$wc = W; "status: " + $wc.DownloadString('http://127.0.0.1:47321/api/status')
$wc = W; $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
"read: " + $wc.UploadString('http://127.0.0.1:47321/api/read', 'POST', (@{ account = 'x'; chat = 'مرحبا@s.whatsapp.net' } | ConvertTo-Json -Compress))
$wc = W; $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
"add: " + $wc.UploadString('http://127.0.0.1:47321/api/accounts/add', 'POST', '{}')
Start-Sleep 6
$wc = W; "status: " + $wc.DownloadString('http://127.0.0.1:47321/api/status')
$wc = W; $b = $wc.DownloadData('http://127.0.0.1:47321/api/accounts/qr?id=new-1'); "qr bytes: $($b.Length)"
$ms = New-Object IO.MemoryStream(, $b)
Add-Type -AssemblyName PresentationCore
$bmp = New-Object Windows.Media.Imaging.BitmapImage; $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $ms; $bmp.EndInit()
"qr image: $($bmp.PixelWidth)x$($bmp.PixelHeight)"
$wc = W; $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
"remove: " + $wc.UploadString('http://127.0.0.1:47321/api/accounts/remove?id=new-1', 'POST', '{}')
$wc = W; "chats: " + $wc.DownloadString('http://127.0.0.1:47321/api/chats')
$wc = W; $wc.Headers.Add('Content-Type', 'application/json; charset=utf-8')
"quit: " + $wc.UploadString('http://127.0.0.1:47321/api/quit', 'POST', '{}')
