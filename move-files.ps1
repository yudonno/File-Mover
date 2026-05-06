#requires -Version 7.0

$source = "C:\Users\YUDonno\Downloads\Completed"
$dest   = "\\yudonno-nas\Media\TV Shows\test"
$baseDir = "B:\Scripts\Working"

$logDir     = Join-Path $baseDir "logs"
$stateFile  = Join-Path $baseDir "state.json"
$reportFile = Join-Path $baseDir "daily-report.txt"

$intervalSeconds = 60
$throttle = 4

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# -------- UTIL --------

function Get-LogPath {
    Join-Path $logDir ("move-files-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
}

function Write-Log {
    param($msg)
    Add-Content (Get-LogPath) "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $msg"
}

function Format-Size {
    param([long]$b)
    if ($b -ge 1GB) { "{0:N2} GB" -f ($b/1GB) }
    elseif ($b -ge 1MB) { "{0:N2} MB" -f ($b/1MB) }
    else { "$b Bytes" }
}

function Test-FileReady {
    param($path)
    try {
        $s = [System.IO.File]::Open($path,'Open','Read','None')
        $s.Close()
        return $true
    } catch { return $false }
}

function Send-Alert {
    param($msg)
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($msg)
}

function Update-State {
    param($files,$folders,$bytes,$idle)

    @{
        time = Get-Date
        files = $files
        folders = $folders
        data = $bytes
        idle = $idle
    } | ConvertTo-Json | Set-Content $stateFile
}

function Show-Console {
    param($files,$folders,$bytes,$idle)

    Clear-Host
    Write-Host "==== FILE MOVER ====" -ForegroundColor Cyan
    Write-Host "Files   : $files"
    Write-Host "Folders : $folders"
    Write-Host "Data    : $(Format-Size $bytes)"
    Write-Host "Idle    : $idle"
}

# -------- WEB DASHBOARD --------

Start-Job -ScriptBlock {
    param($stateFile)

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://+:8080/")
    $listener.Start()

    while ($true) {
        $ctx = $listener.GetContext()
        $res = $ctx.Response

        $json = if (Test-Path $stateFile) {
            Get-Content $stateFile -Raw
        } else { "{}" }

        $html = @"
<html>
<head><meta http-equiv='refresh' content='2'></head>
<body style='background:#111;color:#0f0;font-family:Consolas'>
<h2>File Mover</h2>
<pre>$json</pre>
</body>
</html>
"@

        $buf = [Text.Encoding]::UTF8.GetBytes($html)
        $res.OutputStream.Write($buf,0,$buf.Length)
        $res.Close()
    }

} -ArgumentList $stateFile | Out-Null

# -------- SESSION --------

$sessionFiles = 0
$sessionFolders = 0
$sessionBytes = 0
$idleCounter = 0

Write-Log "===== START ====="

# -------- MAIN LOOP --------

while ($true) {

    $cycleFiles = 0

    # -------- PARALLEL FILES --------
    $files = Get-ChildItem -LiteralPath $source -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -lt (Get-Date).AddMinutes(-2) -and
        (Test-FileReady $_.FullName)
    }

    if ($files.Count -gt 0) {

        $results = $files | ForEach-Object -Parallel {

            $file   = $_
            $source = $using:source
            $dest   = $using:dest

            try {
                $rel = $file.FullName.Substring($source.Length).TrimStart("\")
                $destPath = Join-Path $dest $rel
                $dir = Split-Path $destPath

                New-Item -ItemType Directory -Path $dir -Force | Out-Null

                Copy-Item -LiteralPath $file.FullName -Destination $destPath -Force

                if ((Get-Item -LiteralPath $destPath).Length -eq $file.Length) {
                    Remove-Item -LiteralPath $file.FullName -Force
                    return @{ ok=$true; name=$rel; size=$file.Length }
                }

                return @{ ok=$false; name=$rel }

            } catch {
                return @{ ok=$false; name=$file.FullName }
            }

        } -ThrottleLimit $throttle

        foreach ($r in $results) {
            if ($r.ok) {
                $sessionFiles++
                $sessionBytes += $r.size
                $cycleFiles++
                Write-Log "Moved file: $($r.name) ($(Format-Size $r.size))"
            } else {
                Write-Log "FAILED file: $($r.name)"
                Send-Alert "FAILED: $($r.name)"
            }
        }
    }

    # -------- FOLDERS --------
    Get-ChildItem -LiteralPath $source -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $destPath = Join-Path $dest $_.Name
            if (!(Test-Path -LiteralPath $destPath)) {
                Move-Item -LiteralPath $_.FullName -Destination $destPath
                $sessionFolders++
                Write-Log "Moved folder: $($_.Name)"
            }
        } catch {
            Write-Log "FAILED folder: $($_.Name)"
            Send-Alert "FAILED folder: $($_.Name)"
        }
    }

    # -------- CLEANUP --------
    Get-ChildItem -LiteralPath $source -Directory -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) {
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }

    # -------- DASHBOARD --------
    if ($cycleFiles -eq 0) { $idleCounter++ } else { $idleCounter = 0 }

    Update-State $sessionFiles $sessionFolders $sessionBytes $idleCounter
    Show-Console $sessionFiles $sessionFolders $sessionBytes $idleCounter

    if ($idleCounter -ge 10) {
        Write-Log "Idle for $idleCounter cycles"
        $idleCounter = 0
    }

    # -------- DAILY REPORT --------
    $today = Get-Date -Format "yyyy-MM-dd"
    $log = Join-Path $logDir "move-files-$today.log"

    if (Test-Path $log) {
        $count = (Select-String -Path $log -Pattern "Moved file").Count
        Set-Content $reportFile "Date: $today`nFiles moved: $count"
    }

    Start-Sleep $intervalSeconds
}