$ErrorActionPreference = 'Stop'
. C:\Users\Junan\Documents\John\Tools\webdav_upload\fingerprint-core.ps1

$base = Join-Path $env:TEMP ("fptest_" + [guid]::NewGuid().ToString('N'))
$dir  = Join-Path $base 'records'
$r1   = Join-Path $base 'folderA'
$r2   = Join-Path $base 'folderB'
New-Item -ItemType Directory -Path $dir, $r1, $r2 -Force | Out-Null

function Chk($c, $m) {
    if (-not $c) { throw "ASSERT: $m" }
    Write-Host "  OK $m"
}

# 1) 每個 root 的 fingerprint 檔案路徑都不同、檔名格式正確
$p1 = Get-FingerprintFilePath -Root $r1 -Directory $dir
$p2 = Get-FingerprintFilePath -Root $r2 -Directory $dir
Chk ($p1 -ne $p2) 'two roots get different files'
Chk ((Split-Path -Leaf $p1) -match '^fingerprint-[0-9a-f]{64}\.json$') 'per-root name format'

# 2) 無紀錄時回傳 $null
Chk ($null -eq (Read-Fingerprint -Root $r1 -Directory $dir)) 'null when no record'

# 3) 模擬舊版單一 fingerprint.json（folderA）
New-Item -ItemType File -Path (Join-Path $r1 'a.txt') | Out-Null
$files = @{}
Get-ChildItem -LiteralPath $r1 -File | ForEach-Object {
    $rel = $_.FullName.Substring($r1.TrimEnd('\').Length).TrimStart('\').Replace('\', '/').ToLowerInvariant()
    $files[(ConvertTo-PathHash -Path $rel)] = @((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower(), [long]$_.Length, [long]$_.LastWriteTimeUtc.Ticks)
}
$fp = ConvertTo-FingerprintJson -Root $r1 -Files $files
$fp | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'fingerprint.json') -Encoding UTF8

# 4) legacy 沿用：folderA 讀得到且指向 per-root 寫入路徑；folderB 不受影響
$r1x = Read-Fingerprint -Root $r1 -Directory $dir
Chk ($null -ne $r1x) 'legacy fallback works'
Chk ($r1x.FilePath -eq (Get-FingerprintFilePath -Root $r1 -Directory $dir)) 'FilePath points to per-root'
Chk ($null -eq (Read-Fingerprint -Root $r2 -Directory $dir)) 'rootB unaffected by rootA record'

# 5) per-root 優先：folderA 已有 per-root 檔時，不再讀 legacy
$fp | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $r1x.FilePath -Encoding UTF8
Chk ((Read-Fingerprint -Root $r1 -Directory $dir).FilePath -eq $r1x.FilePath) 'per-root takes priority over legacy'

Write-Host 'FINGERPRINT UNIT TESTS PASSED'
Remove-Item -LiteralPath $base -Recurse -Force
