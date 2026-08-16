# Decrypt-File.ps1
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$FilePath
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile   = Join-Path $ScriptDir ".env"

if (-not $FilePath) {
    Write-Host "請把 .enc 檔案拖曳到 Decrypt-File.bat 上執行。" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $FilePath)) {
    Write-Host "找不到檔案：$FilePath" -ForegroundColor Red
    exit 1
}

$FilePath = (Resolve-Path -LiteralPath $FilePath).Path
$FileName = Split-Path -Leaf $FilePath

if (-not $FileName.EndsWith('.enc')) {
    Write-Host "不是 .enc 檔案：$FileName" -ForegroundColor Red
    exit 1
}

# 讀取 .env 的加密密碼
if (-not (Test-Path $EnvFile)) {
    Write-Host "找不到 .env 檔案：$EnvFile" -ForegroundColor Red
    exit 1
}

$EncryptPassword = $null
foreach ($line in (Get-Content $EnvFile -Encoding UTF8)) {
    $line = $line.Trim()
    if ($line -match '^\s*#' -or $line -eq '') { continue }
    if ($line -match '^ENCRYPT_PASSWORD=(.*)$') {
        $EncryptPassword = $matches[1].Trim()
    }
}

if ([string]::IsNullOrEmpty($EncryptPassword)) {
    Write-Host ".env 缺少 ENCRYPT_PASSWORD 設定" -ForegroundColor Red
    exit 1
}

function Unprotect-FileFromAes {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Password
    )

    $fs = [System.IO.File]::OpenRead($InputFile)
    try {
        $header = New-Object byte[] 32
        if ($fs.Read($header, 0, 32) -lt 32) {
            throw "檔案格式錯誤或已損壞（標頭不完整）"
        }

        $salt = New-Object byte[] 16
        $iv   = New-Object byte[] 16
        [Array]::Copy($header, 0, $salt, 0, 16)
        [Array]::Copy($header, 16, $iv, 0, 16)

        $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $aes = [System.Security.Cryptography.Aes]::Create()
            try {
                $aes.Key = $derive.GetBytes(32)
                $aes.IV = $iv
                $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
                $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

                $decryptor  = $aes.CreateDecryptor()
                $cryptoStream = New-Object System.Security.Cryptography.CryptoStream($fs, $decryptor, [System.Security.Cryptography.CryptoStreamMode]::Read)
                $outStream  = [System.IO.File]::Create($OutputFile)
                try {
                    $cryptoStream.CopyTo($outStream)
                }
                finally {
                    $outStream.Dispose()
                    $cryptoStream.Dispose()
                }
            }
            finally {
                $aes.Dispose()
            }
        }
        finally {
            $derive.Dispose()
        }
    }
    finally {
        $fs.Dispose()
    }
}

$OutputFile = Join-Path (Split-Path -Parent $FilePath) ($FileName -replace '\.enc$', '.zip')

Write-Host "正在解密：$FileName ..." -ForegroundColor Yellow
try {
    Unprotect-FileFromAes -InputFile $FilePath -OutputFile $OutputFile -Password $EncryptPassword
    Write-Host ""
    Write-Host "解密成功：$OutputFile" -ForegroundColor Green
    Write-Host "這是 zip 檔，可用 Windows 內建解壓縮開啟（或 Expand-Archive 解壓）" -ForegroundColor Gray
}
catch {
    if (Test-Path -LiteralPath $OutputFile) {
        Remove-Item -LiteralPath $OutputFile -Force
    }
    Write-Host ""
    Write-Host "解密失敗：密碼錯誤或檔案損壞。" -ForegroundColor Red
    Write-Host "原始錯誤：$($_.Exception.Message)" -ForegroundColor DarkGray
    exit 1
}