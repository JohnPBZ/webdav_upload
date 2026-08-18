# 端到端測試:修改兩個檔案 → 單一差異包 .diff.enc
$ErrorActionPreference = 'Stop'

$workspace = 'C:/Users/Junan/Documents/John/Tools/webdav_upload'
$sourceDir = 'C:/Users/Junan/Downloads/quick note'
$devRoot   = Join-Path $workspace '.davtest_root'
$testDir   = Join-Path $env:TEMP ("e2e_twodiff_" + [guid]::NewGuid().ToString('N'))

function Assert-True($cond, $msg) {
    if (-not $cond) { throw "ASSERT FAIL: $msg" }
    Write-Host "  OK $msg" -ForegroundColor Green
}

New-Item -ItemType Directory -Path $testDir -Force | Out-Null
Copy-Item (Join-Path $workspace 'Upload-To-WebDAV.ps1') $testDir
Copy-Item (Join-Path $workspace 'fingerprint-core.ps1') $testDir
@"
WEBDAV_PASSWORD=testpw
WEBDAV_BASE_URL=http://127.0.0.1:18080/
WEBDAV_TARGET_DIR=/Uploads/
ENCRYPT_PASSWORD=testencpassword123
"@ | Set-Content (Join-Path $testDir '.env') -Encoding UTF8

Push-Location $testDir
try {
    # 階段1: -e 全量上傳
    Write-Host '=== 階段1: -e 全量上傳 ===' -ForegroundColor Cyan
    & pwsh -NoProfile -File (Join-Path $testDir 'Upload-To-WebDAV.ps1') -FilePath $sourceDir -Username tester -Encryption | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '-e 成功'

    Start-Sleep -Milliseconds 1500

    # 記住原始內容
    $orig1 = Get-Content (Join-Path $sourceDir '1.md') -Raw
    $orig2 = Get-Content (Join-Path $sourceDir '2.md') -Raw

    # 階段2: 修改 2 個檔案
    Write-Host '=== 階段2: 修改 1.md + 2.md ===' -ForegroundColor Cyan
    Set-Content (Join-Path $sourceDir '1.md') -Value ("[EDIT1 $(Get-Date -Format 'HH:mm:ss')]`n" + $orig1) -NoNewline
    Set-Content (Join-Path $sourceDir '2.md') -Value ("[EDIT2 $(Get-Date -Format 'HH:mm:ss')]`n" + $orig2) -NoNewline

    # 階段3: -e -d 差異上傳
    Write-Host '=== 階段3: -e -d 差異上傳 ===' -ForegroundColor Cyan
    & pwsh -NoProfile -File (Join-Path $testDir 'Upload-To-WebDAV.ps1') -FilePath $sourceDir -Username tester -Encryption -Diff | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) '-e -d 成功'

    # 驗證:只有一個 .diff.enc,命名為 quick note_時間戳.diff.enc
    $diffFiles = @(Get-ChildItem -LiteralPath (Join-Path $devRoot 'Uploads') -Recurse -File -Filter '*.diff.enc')
    Assert-True ($diffFiles.Count -eq 1) "僅 1 個 .diff.enc(實際 $($diffFiles.Count))"
    $name = $diffFiles[0].Name
    Assert-True ($name -match '^quick note_\d{8}_\d{6}\.diff\.enc$') "命名正確(實際:$name)"

    # 驗證內容:解密後 zip 內有 1.md 與 2.md(保留根層)
    $encPath = $diffFiles[0].FullName
    $work = Join-Path $env:TEMP ("verify_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        # 內建 AES 解密(與 Decrypt-File.ps1 相同演算法:salt|iv|cipher, PBKDF2 100k SHA256)
        Add-Type -AssemblyName System.Security
        $bytes = [System.IO.File]::ReadAllBytes($encPath)
        $salt = New-Object byte[] 16
        $iv   = New-Object byte[] 16
        [Array]::Copy($bytes, 0, $salt, 0, 16)
        [Array]::Copy($bytes, 16, $iv, 0, 16)
        $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes('testencpassword123', $salt, 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $derive.GetBytes(32)
        $aes.IV = $iv
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $dec = $aes.CreateDecryptor()
        $ms = New-Object System.IO.MemoryStream
        $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $dec, [System.Security.Cryptography.CryptoStreamMode]::Write)
        $cs.Write($bytes, 32, $bytes.Length - 32)
        $cs.FlushFinalBlock()
        $zipPath = Join-Path $work 'diff.zip'
        [System.IO.File]::WriteAllBytes($zipPath, $ms.ToArray())
        $cs.Dispose(); $ms.Dispose(); $aes.Dispose(); $derive.Dispose()

        Expand-Archive -LiteralPath $zipPath -DestinationPath (Join-Path $work 'x') -Force
        $expanded = Get-ChildItem -LiteralPath (Join-Path $work 'x') -File -Recurse
        $names = @($expanded | ForEach-Object { $_.FullName.Replace((Join-Path $work 'x'), '').TrimStart('\').Replace('\', '/') } | Sort-Object)
        Write-Host "  zip 內檔案:$($names -join ', ')"
        Assert-True ($names -contains '1.md' -and $names -contains '2.md') 'zip 內含 1.md 與 2.md'
        Assert-True ($expanded.Count -eq 2) "zip 內僅 2 個變動檔案(實際 $($expanded.Count))"
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force
    }

    # 還原
    Set-Content (Join-Path $sourceDir '1.md') -Value $orig1 -NoNewline
    Set-Content (Join-Path $sourceDir '2.md') -Value $orig2 -NoNewline

    Write-Host '`n兩個檔案差異測試通過 ✓' -ForegroundColor Green
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $testDir -Recurse -Force
}