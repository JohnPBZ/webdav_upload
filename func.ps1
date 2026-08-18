function global:up {
    param(
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
        [string[]]$Files,

        [Parameter(Mandatory = $false)]
        [Alias('e')]
        [switch]$Encryption,

        [Parameter(Mandatory = $false)]
        [Alias('d')]
        [switch]$Diff
    )
    
    $script = "C:\Users\Junan\Documents\John\Tools\webdav_upload\Upload-To-WebDAV.ps1"

    # 只詢問一次，並設成環境變數（子程序會繼承）
    if ([string]::IsNullOrWhiteSpace($env:WEBDAV_USERNAME)) {
        $env:WEBDAV_USERNAME = Read-Host "請輸入 WebDAV 帳號"
        if ([string]::IsNullOrWhiteSpace($env:WEBDAV_USERNAME)) {
            Write-Host "帳號不能為空。" -ForegroundColor Red
            return
        }
    }

    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Host "找不到檔案：$f" -ForegroundColor Red
            continue
        }

        Write-Host "`n===== 上傳：$f =====" -ForegroundColor Cyan
        $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script, "-FilePath", $f, "-Username", $env:WEBDAV_USERNAME)
        if ($Encryption) {
            $args += "-Encryption"
        }
        if ($Diff) {
            $args += "-Diff"
        }
        & powershell.exe @args
    }

    # 可選：用完後清掉，避免殘留在目前的 PowerShell session
    Remove-Item Env:WEBDAV_USERNAME -ErrorAction SilentlyContinue
}
