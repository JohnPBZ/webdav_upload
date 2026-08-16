# Upload-To-WebDAV.ps1
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$FilePath,

    [Parameter(Mandatory = $false)]
    [string]$Username
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

# 讀取 .env
if (-not (Test-Path $EnvFile)) {
    Write-Host "找不到 .env 檔案：$EnvFile" -ForegroundColor Red
    exit 1
}

$envContent = Get-Content $EnvFile -Encoding UTF8
$WebDavPassword  = $null
$WebDavBaseUrl   = $null
$WebDavTargetDir = $null

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
}

if (-not $WebDavPassword -or -not $WebDavBaseUrl -or -not $WebDavTargetDir) {
    Write-Host ".env 檔案缺少必要設定（WEBDAV_PASSWORD / WEBDAV_BASE_URL / WEBDAV_TARGET_DIR）" -ForegroundColor Red
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
# 使用 curl 上傳（自帶進度條）
# -------------------------------------------------
$TargetUrl = "$WebDavBaseUrl$WebDavTargetDir$([Uri]::EscapeDataString($FileName))"

Write-Host "上傳目標：$TargetUrl" -ForegroundColor Gray
Write-Host "正在上傳..." -ForegroundColor Yellow
Write-Host ""

$curlArgs = @(
    "-T", $FilePath,
    "-u", $Auth,
    "-o", "NUL",                              # 關鍵：丟棄回應，進度條才會出現
    "-#",                                     # 進度條
    "-f",
    "-S",
    "-H", "Content-Type: application/octet-stream",
    $TargetUrl
)

& curl.exe @curlArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "上傳成功！" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "上傳失敗（curl 結束代碼：$LASTEXITCODE）" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "完成。" -ForegroundColor Cyan