# fingerprint-core.ps1
# 資料夾檔案狀態掃描與差異比對核心函數(不含 WebDAV 上傳)。
# 由 Upload-To-WebDAV.ps1 dot-source 載入,可獨立測試。
#
# 隱私設計:所有真實路徑一律 SHA256 雜湊化後才寫入 fingerprint.json,
# 開啟紀錄檔無法得知上傳了哪些檔案與資料夾結構。

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

function ConvertTo-Sha256Hex {
    param([string]$FilePath)
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLower()
}

# 標準化路徑:去掉尾端分隔符、統一為 / 分隔、小寫,供雜湊與比對使用
function Get-NormalizedPath {
    param([string]$Path)
    return $Path.TrimEnd('\').Replace('\', '/').TrimEnd('/').ToLowerInvariant()
}

# 掃描資料夾並與舊紀錄比對。
# OldFiles:rel_hash -> @(sha256, size, mtimeTicks)(可為空 hashtable)。
# 回傳 @{ Changed = []; NewFiles = [] }:
#   Changed  每個項目:RelNorm(相對路徑,/ 分隔)、FullPath、RelHash、Sha256、Size、Mtime、Reason
#   NewFiles 每個項目:RelHash、Sha256、Size、Mtime(完整最新狀態,供寫回 fingerprint)
#
# 判定規則(只比對本地紀錄,不查伺服器):
#   - 紀錄無此檔案        -> 新檔案,需上傳
#   - size 或 mtime 不同   -> 重新計算 SHA256 確認;內容不同 -> 需上傳
#   - size 與 mtime 相同   -> 視為未變,沿用紀錄中的 SHA256,不重算
function Get-FolderDelta {
    param(
        [string]$Path,
        [hashtable]$OldFiles
    )

    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $changed  = @()
    $newFiles = @()

    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel     = $f.FullName.Substring($root.Length).TrimStart('\')
        $relNorm = $rel.Replace('\', '/').ToLowerInvariant()
        $relHash = ConvertTo-PathHash -Path $relNorm
        $size    = [long]$f.Length
        $mtime   = [long]$f.LastWriteTimeUtc.Ticks

        $sha    = $null
        $reason = $null

        if ($OldFiles.ContainsKey($relHash)) {
            $oldSha   = $OldFiles[$relHash][0]
            $oldSize  = [long]$OldFiles[$relHash][1]
            $oldMtime = [long]$OldFiles[$relHash][2]

            if ($size -eq $oldSize -and $mtime -eq $oldMtime) {
                # 大小與修改時間都相同,視為未變,沿用舊 SHA256(免重算)
                $sha = $oldSha
            }
            else {
                $sha = ConvertTo-Sha256Hex -FilePath $f.FullName
                if ($sha -ne $oldSha) {
                    $reason = '內容變動'
                }
            }
        }
        else {
            $sha    = ConvertTo-Sha256Hex -FilePath $f.FullName
            $reason = '新檔案'
        }

        $newFiles += @{
            RelHash = $relHash
            Sha256  = $sha
            Size    = $size
            Mtime   = $mtime
        }

        if ($reason) {
            $changed += @{
                RelNorm  = $relNorm
                FullPath = $f.FullName
                RelHash  = $relHash
                Sha256   = $sha
                Size     = $size
                Mtime    = $mtime
                Reason   = $reason
            }
        }
    }

    return @{ Changed = $changed; NewFiles = $newFiles }
}

# 將紀錄 hashtable(rel_hash -> @(sha256, size, mtimeTicks)) 轉換為 fingerprint.json 物件。
# RootHash:資料夾完整路徑的 SHA256(雜湊保護)。
# CreatedAt:保留上次建立時間,由外部傳入或自動產生。
function ConvertTo-FingerprintJson {
    param(
        [string]$Root,
        [hashtable]$Files,
        [string]$CreatedAt
    )

    if (-not $CreatedAt) {
        $CreatedAt = (Get-Date).ToString('o')
    }

    $rootHash = ConvertTo-PathHash -Path (Get-NormalizedPath -Path $Root)

    $fileList = @()
    foreach ($key in $Files.Keys) {
        $fileList += @{
            rel_hash = $key
            sha256   = $Files[$key][0]
            size     = [long]$Files[$key][1]
            mtime    = [long]$Files[$key][2]
        }
    }
    $fileList = $fileList | Sort-Object -Property rel_hash

    return @{
        fingerprint_version = '1.0'
        root_hash           = $rootHash
        created_at          = $CreatedAt
        files               = $fileList
    }
}

# 每個資料夾各自一份 fingerprint 檔案（檔名用 root_hash，不洩漏路徑），
# 支援多個資料夾各自獨立差異上傳。讀取時相容舊版單一 fingerprint.json。
function Get-FingerprintFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $rootHash = ConvertTo-PathHash -Path (Get-NormalizedPath -Path $Root)
    return (Join-Path $Directory ("fingerprint-" + $rootHash + ".json"))
}

# 讀取指定資料夾的 fingerprint。
# 回傳 @{ Json; FilePath }（FilePath 為應寫入的 per-root 路徑），找不到相符紀錄時回傳 $null。
# 舊版 fingerprint.json 僅在 root_hash 相符時沿用（讀取後下一次寫入會改存到 per-root 檔案）。
function Read-Fingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $rootHash = ConvertTo-PathHash -Path (Get-NormalizedPath -Path $Root)

    $perRoot = Join-Path $Directory ("fingerprint-" + $rootHash + ".json")
    if (Test-Path -LiteralPath $perRoot) {
        return @{
            Json     = Get-Content -LiteralPath $perRoot -Raw -Encoding UTF8 | ConvertFrom-Json
            FilePath = $perRoot
        }
    }

    $legacy = Join-Path $Directory "fingerprint.json"
    if (Test-Path -LiteralPath $legacy) {
        $fp = Get-Content -LiteralPath $legacy -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($fp.root_hash -eq $rootHash) {
            return @{
                Json     = $fp
                FilePath = $perRoot
            }
        }
    }

    return $null
}
