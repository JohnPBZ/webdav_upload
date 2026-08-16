# Upload-To-WebDAV.ps1
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$FilePath,

    [Parameter(Mandatory = $false)]
    [string]$Username,

    [Parameter(Mandatory = $false)]
    [Alias('e')]
    [switch]$Encryption
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile   = Join-Path $ScriptDir ".env"

# 檢查拖入的檔案
if (-not $FilePath) {
    Write-Host "請把檔案拖曳到 Upload-To-WebDAV.bat 上執行。" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $FilePath)) {
    Write-Host "找不到檔案：$FilePath" -ForegroundColor Red
    exit 1
}

$FilePath = (Resolve-Path -LiteralPath $FilePath).Path
$FileName = Split-Path -Leaf $FilePath

Write-Host "準備上傳檔案：$FileName" -ForegroundColor Cyan
Write-Host "完整路徑：$FilePath" -ForegroundColor Gray
Write-Host ""

# -------------------------------------------------
# 上傳記錄（本機路徑以 SHA256 雜湊儲存，避免記事本直接看出路徑）
# -------------------------------------------------
$RecordFile = Join-Path $ScriptDir "upload-record.txt"

function ConvertTo-PathHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLower()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FolderFingerprint {
    param([string]$Path)

    $root = $Path.TrimEnd('\')
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $manifest = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\')
            "$rel|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
        } | Sort-Object
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($manifest -join "`n"))
        return ([BitConverter]::ToString($md5.ComputeHash($bytes))).Replace('-', '').ToLower()
    }
    finally {
        $md5.Dispose()
    }
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

function Protect-FileWithAes {
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Password
    )

    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($salt)
    }
    finally {
        $rng.Dispose()
    }

    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $key = $derive.GetBytes(32)
    $derive.Dispose()

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $key
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.GenerateIV()

        $encryptor  = $aes.CreateEncryptor()
        $inStream   = [System.IO.File]::OpenRead($InputFile)
        $outStream  = [System.IO.File]::Create($OutputFile)
        try {
            $outStream.Write($salt, 0, $salt.Length)
            $outStream.Write($aes.IV, 0, $aes.IV.Length)

            $cryptoStream = New-Object System.Security.Cryptography.CryptoStream($outStream, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)
            try {
                $inStream.CopyTo($cryptoStream)
                $cryptoStream.FlushFinalBlock()
            }
            finally {
                $cryptoStream.Dispose()
            }
        }
        finally {
            $inStream.Dispose()
            $outStream.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }
}

$PathHash = ConvertTo-PathHash -Path $FilePath
$Item     = Get-Item -LiteralPath $FilePath
$IsFolder = $Item.PSIsContainer
$FileSize = $Item.Length

if ($IsFolder) {
    $Md5 = Get-FolderFingerprint -Path $FilePath
}
else {
    $Md5 = (Get-FileHash -LiteralPath $FilePath -Algorithm MD5).Hash.ToLower()
}

if ($IsFolder -and -not $Encryption) {
    Write-Host "資料夾上傳需要先加密壓縮：請改用 -Encryption（或 Upload-To-WebDAV-Enc.bat）" -ForegroundColor Red
    exit 1
}

$records = @{}
if (Test-Path -LiteralPath $RecordFile) {
    foreach ($line in (Get-Content -LiteralPath $RecordFile -Encoding UTF8)) {
        $line = $line.Trim()
        if ($line -eq '') { continue }
        $fields = $line -split ';'
        if ($fields.Count -ge 4) {
            $records[$fields[0]] = @($fields[1], $fields[2], $fields[3])
        }
    }
}

$existing = $null
if ($records.ContainsKey($PathHash)) {
    $existing = $records[$PathHash]
}
else {
    foreach ($key in $records.Keys) {
        if ($records[$key][0] -ieq $Md5) {
            $existing = $records[$key]
            break
        }
    }
}

if ($existing) {
    Write-Host "此檔案先前已上傳過：" -ForegroundColor Yellow
    Write-Host "  上次上傳日期：$($existing[2])" -ForegroundColor Yellow
    Write-Host "  MD5：$($existing[0])" -ForegroundColor Yellow
    Write-Host "  檔案大小：$(Format-FileSize -Bytes $existing[1])" -ForegroundColor Yellow
    Write-Host ""
    $answer = Read-Host "是否覆蓋上傳？(Y/N，直接按 Enter 預設為 Y)"
    if ($answer -ne '' -and $answer -notmatch '^[Yy]') {
        Write-Host "已取消上傳。" -ForegroundColor Gray
        exit 0
    }
    Write-Host ""
}

# 讀取 .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "找不到 .env 檔案：$EnvFile" -ForegroundColor Red
    exit 1
}

$envContent = Get-Content $EnvFile -Encoding UTF8
$WebDavPassword  = $null
$WebDavBaseUrl   = $null
$WebDavTargetDir = $null
$EncryptPassword = $null

foreach ($line in $envContent) {
    $line = $line.Trim()
    if ($line -match '^\s*#' -or $line -eq '') { continue }

    if ($line -match '^WEBDAV_PASSWORD=(.*)$') {
        $WebDavPassword = $matches[1].Trim()
    }
    elseif ($line -match '^WEBDAV_BASE_URL=(.*)$') {
        $WebDavBaseUrl = $matches[1].Trim().TrimEnd('/')
    }
    elseif ($line -match '^WEBDAV_TARGET_DIR=(.*)$') {
        $WebDavTargetDir = $matches[1].Trim()
        if (-not $WebDavTargetDir.StartsWith('/')) {
            $WebDavTargetDir = '/' + $WebDavTargetDir
        }
        if (-not $WebDavTargetDir.EndsWith('/')) {
            $WebDavTargetDir += '/'
        }
    }
    elseif ($line -match '^ENCRYPT_PASSWORD=(.*)$') {
        $EncryptPassword = $matches[1].Trim()
    }
}

if (-not $WebDavPassword -or -not $WebDavBaseUrl -or -not $WebDavTargetDir) {
    Write-Host ".env 檔案缺少必要設定（WEBDAV_PASSWORD / WEBDAV_BASE_URL / WEBDAV_TARGET_DIR）" -ForegroundColor Red
    exit 1
}

if ($Encryption -and [string]::IsNullOrEmpty($EncryptPassword)) {
    Write-Host "使用 -Encryption 需要 .env 設定 ENCRYPT_PASSWORD" -ForegroundColor Red
    exit 1
}

# 詢問帳號（如果沒有透過參數傳入才問）
if ([string]::IsNullOrWhiteSpace($Username)) {
    $Username = Read-Host "請輸入 WebDAV 帳號"
    if ([string]::IsNullOrWhiteSpace($Username)) {
        Write-Host "帳號不能為空。" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Host "使用傳入的帳號：$Username" -ForegroundColor DarkGray
}

$Auth = "${Username}:${WebDavPassword}"

# -------------------------------------------------
# 自動建立目錄（支援多層，強制使用尾隨斜線）
# -------------------------------------------------
function Ensure-WebDavDirectory {
    param(
        [string]$BaseUrl,
        [string]$TargetDir,
        [string]$AuthString
    )

    $parts = $TargetDir.Trim('/').Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
    $currentPath = ""

    foreach ($part in $parts) {
        $currentPath += "/$part"
        $dirUrl = "$BaseUrl$currentPath/"

        Write-Host "檢查目錄：$currentPath/" -ForegroundColor Gray

        $checkArgs = @(
            "-s", "-o", "NUL", "-w", "%{http_code}",
            "-u", $AuthString,
            "-X", "PROPFIND",
            "-H", "Depth: 0",
            $dirUrl
        )

        $status = & curl.exe @checkArgs 2>$null

        if ($status -eq "207" -or $status -eq "200" -or $status -eq "301" -or $status -eq "302") {
            Write-Host "  → 目錄已存在" -ForegroundColor DarkGreen
            continue
        }

        Write-Host "  → 目錄不存在，正在建立..." -ForegroundColor Yellow

        $mkcolArgs = @(
            "-s", "-o", "NUL", "-w", "%{http_code}",
            "-u", $AuthString,
            "-X", "MKCOL",
            $dirUrl
        )

        $mkStatus = & curl.exe @mkcolArgs 2>$null

        if ($mkStatus -eq "201" -or $mkStatus -eq "405" -or $mkStatus -eq "200" -or $mkStatus -eq "301") {
            Write-Host "  → 建立成功（或已存在）" -ForegroundColor Green
        }
        else {
            Write-Host "  → 建立失敗（HTTP $mkStatus）" -ForegroundColor Red
            return $false
        }
    }
    return $true
}

Write-Host "正在檢查並建立目標目錄..." -ForegroundColor Cyan
$ok = Ensure-WebDavDirectory -BaseUrl $WebDavBaseUrl -TargetDir $WebDavTargetDir -AuthString $Auth

if (-not $ok) {
    Write-Host "無法建立目標目錄，上傳中止。" -ForegroundColor Red
    exit 1
}

Write-Host ""

# -------------------------------------------------
# 加密壓縮（-Encryption）：先 zip 再 AES-256 加密
# -------------------------------------------------
$UploadFile = $FilePath
$UploadName = $FileName
$TempDir    = $null

if ($Encryption) {
    $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("PrivateUpload_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    $TempZip = Join-Path $TempDir "$FileName.zip"
    $TempEnc = Join-Path $TempDir "$FileName.zip.enc"

    Write-Host "正在壓縮：$FileName ..." -ForegroundColor Yellow
    Compress-Archive -Path $FilePath -DestinationPath $TempZip -CompressionLevel Optimal
    Write-Host "壓縮完成：$(Split-Path -Leaf $TempZip)（$(Format-FileSize -Bytes (Get-Item $TempZip).Length)）" -ForegroundColor Green

    Write-Host "正在加密（AES-256，密碼來自 .env）..." -ForegroundColor Yellow
    Protect-FileWithAes -InputFile $TempZip -OutputFile $TempEnc -Password $EncryptPassword

    $UploadFile = $TempEnc
    $UploadName = Split-Path -Leaf $TempEnc
    Write-Host "加密完成：$UploadName（$(Format-FileSize -Bytes (Get-Item $TempEnc).Length)）" -ForegroundColor Green
    Write-Host ""
}

# -------------------------------------------------
# 使用 curl 上傳（自帶進度條）
# -------------------------------------------------
$TargetUrl = "$WebDavBaseUrl$WebDavTargetDir$([Uri]::EscapeDataString($UploadName))"

Write-Host "上傳目標：$TargetUrl" -ForegroundColor Gray
Write-Host "正在上傳..." -ForegroundColor Yellow
Write-Host ""

$curlArgs = @(
    "-T", $UploadFile,
    "-u", $Auth,
    "-o", "NUL",                              # 關鍵：丟棄回應，進度條才會出現
    "-#",                                     # 進度條
    "-f",
    "-S",
    "-H", "Content-Type: application/octet-stream",
    $TargetUrl
)

try {
    & curl.exe @curlArgs

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "上傳成功！" -ForegroundColor Green

        # 更新上傳記錄（移除舊的相同路徑雜湊或相同 MD5 記錄，再寫入新的一筆）
        # 注意：記錄存的是「原始檔案」的 MD5/大小，讓改名/移動後仍能比對去重
        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $newLine = "$PathHash;$Md5;$FileSize;$now"

        $oldLines = @()
        if (Test-Path -LiteralPath $RecordFile) {
            foreach ($line in (Get-Content -LiteralPath $RecordFile -Encoding UTF8)) {
                $line = $line.Trim()
                if ($line -eq '') { continue }
                $fields = $line -split ';'
                if ($fields.Count -ge 4 -and $fields[0] -ne $PathHash -and $fields[1] -ine $Md5) {
                    $oldLines += $line
                }
            }
        }
        $oldLines += $newLine
        $oldLines | Set-Content -LiteralPath $RecordFile -Encoding UTF8

        Write-Host "已更新上傳記錄：$RecordFile" -ForegroundColor DarkGray
    }
    else {
        Write-Host ""
        Write-Host "上傳失敗（curl 結束代碼：$LASTEXITCODE）" -ForegroundColor Red
        exit 1
    }
}
finally {
    if ($TempDir -and (Test-Path -LiteralPath $TempDir)) {
        Remove-Item -LiteralPath $TempDir -Recurse -Force
        Write-Host "已刪除暫存檔：$TempDir" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "完成。" -ForegroundColor Cyan