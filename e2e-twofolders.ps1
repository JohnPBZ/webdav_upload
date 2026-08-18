# 端到端測試：兩個資料夾各自建立/更新 fingerprint，-d 差異上傳互不干擾
param(
    [string]$ServerRoot = (Join-Path $env:TEMP ('davtest_twofolder_' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'

$workspace = 'C:/Users/Junan/Documents/John/Tools/webdav_upload'
$serverRoot = $ServerRoot
$testDir    = Join-Path $env:TEMP ("e2e_twofolders_" + [guid]::NewGuid().ToString('N'))
$folderA    = Join-Path $env:TEMP ("srcA_" + [guid]::NewGuid().ToString('N'))
$folderB    = Join-Path $env:TEMP ("srcB_" + [guid]::NewGuid().ToString('N'))
$port       = 18081

function Assert-True($cond, $msg) {
    if (-not $cond) { throw "ASSERT FAIL: $msg" }
    Write-Host "  OK $msg" -ForegroundColor Green
}

New-Item -ItemType Directory -Path $serverRoot, $testDir, $folderA, $folderB -Force | Out-Null
Set-Content (Join-Path $folderA 'a1.md')  'AAA one'
Set-Content (Join-Path $folderA 'a2.md')  'AAA two'
Set-Content (Join-Path $folderB 'b1.md')  'BBB one'
New-Item -ItemType Directory -Path (Join-Path $folderB 'sub') -Force | Out-Null
Set-Content (Join-Path $folderB 'sub\b2.md') 'BBB nested'

Copy-Item (Join-Path $workspace 'Upload-To-WebDAV.ps1') $testDir
Copy-Item (Join-Path $workspace 'fingerprint-core.ps1') $testDir
@"
WEBDAV_PASSWORD=testpw
WEBDAV_BASE_URL=http://127.0.0.1:$port/
WEBDAV_TARGET_DIR=/Uploads/
ENCRYPT_PASSWORD=testencpassword123
"@ | Set-Content (Join-Path $testDir '.env') -Encoding UTF8

Push-Location $testDir
try {
    $script = Join-Path $testDir 'Upload-To-WebDAV.ps1'

    # 階段1：兩個資料夾各跑 -e，皆應成功且各自產生 fingerprint-<root_hash>.json
    Write-Host '=== 階段1: 兩個資料夾 -e ===' -ForegroundColor Cyan
    & pwsh -NoProfile -File $script -FilePath $folderA -Username tester -Encryption | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '資料夾A -e 成功'
    & pwsh -NoProfile -File $script -FilePath $folderB -Username tester -Encryption | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '資料夾B -e 成功'

    $fpFiles = @(Get-ChildItem -LiteralPath $testDir -File -Filter 'fingerprint-*.json')
    Assert-True ($fpFiles.Count -eq 2) "各自一份 per-root fingerprint (實際 $($fpFiles.Count))"
    Assert-True (-not (Test-Path (Join-Path $testDir 'fingerprint.json'))) '未產生舊版單一 fingerprint.json'

    Start-Sleep -Milliseconds 1000

    # 階段2：兩資料夾各改一個檔案
    Write-Host '=== 階段2: 各改一個檔案 ===' -ForegroundColor Cyan
    Set-Content (Join-Path $folderA 'a1.md')  "[A-EDIT]`nAAA one" -NoNewline
    Set-Content (Join-Path $folderB 'b1.md')  "[B-EDIT]`nBBB one" -NoNewline

    # 階段3：兩個資料夾各 -e -d，皆應成功，不得出現 root_hash 不符
    Write-Host '=== 階段3: 兩個資料夾 -e -d ===' -ForegroundColor Cyan
    & pwsh -NoProfile -File $script -FilePath $folderA -Username tester -Encryption -Diff | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '資料夾A -e -d 成功'
    & pwsh -NoProfile -File $script -FilePath $folderB -Username tester -Encryption -Diff | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '資料夾B -e -d 成功'

    # 驗證：伺服器上應有 2 個 .diff.enc，且 per-root fingerprint 各剩一份、內容各自獨立
    $diffFiles = @(Get-ChildItem -LiteralPath $serverRoot -Recurse -File -Filter '*.diff.enc')
    Assert-True ($diffFiles.Count -eq 2) "伺服器僅 2 個 .diff.enc (實際 $($diffFiles.Count))"

    $fpAfter = @(Get-ChildItem -LiteralPath $testDir -File -Filter 'fingerprint-*.json')
    Assert-True ($fpAfter.Count -eq 2) "diff 後 per-root fingerprint 仍各一份 (實際 $($fpAfter.Count))"
    foreach ($f in $fpAfter) {
        $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($j.root_hash -match '^[0-9a-f]{64}$') "fingerprint root_hash 格式正確"
        Assert-True ($j.files.Count -eq 2) "fingerprint 內 2 個檔案 (實際 $($j.files.Count))"
    }

    # 階段4：A 再改一個檔、只 diff A，B 不應受影響
    Write-Host '=== 階段4: 只對 A 再 diff ===' -ForegroundColor Cyan
    Set-Content (Join-Path $folderA 'a2.md')  "[A2-EDIT]`nAAA two" -NoNewline
    & pwsh -NoProfile -File $script -FilePath $folderA -Username tester -Encryption -Diff | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '資料夾A 二次 -e -d 成功'
    $diffAfter = @(Get-ChildItem -LiteralPath $serverRoot -Recurse -File -Filter '*.diff.enc')
    Assert-True ($diffAfter.Count -eq 3) "共 3 個 .diff.enc (實際 $($diffAfter.Count))"

    Write-Host '兩個資料夾差異上傳測試通過 ✓' -ForegroundColor Green
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $testDir, $folderA, $folderB, $serverRoot -Recurse -Force -ErrorAction SilentlyContinue
}
