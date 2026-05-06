$source = "C:\Users\YUDonno\Downloads\Completed"
$dest   = "T:\test"
$intervalSeconds = 60
$logDir = "B:\Scripts\Working\logs"

if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Get-LogPath {
    $date = Get-Date -Format "yyyy-MM-dd"
    Join-Path $logDir "move-files-$date.log"
}

function Write-Log {
    param ($message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp - $message"
    Write-Host $entry
    Add-Content -Path (Get-LogPath) -Value $entry
}

function Format-Size {
    param ([long]$bytes)
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else { "$bytes Bytes" }
}

function Copy-WithProgress {
    param ($sourcePath, $destPath)

    $bufferSize = 4MB
    $fileSize = (Get-Item $sourcePath).Length

    $in  = [System.IO.File]::OpenRead($sourcePath)
    $out = [System.IO.File]::Create($destPath)

    $buffer = New-Object byte[] $bufferSize
    $total = 0

    while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $out.Write($buffer, 0, $read)
        $total += $read

        $percent = [math]::Round(($total / $fileSize) * 100, 2)

        Write-Progress `
            -Activity "Moving file: $(Split-Path $sourcePath -Leaf)" `
            -Status "$percent% ($(Format-Size $total) / $(Format-Size $fileSize))" `
            -PercentComplete $percent
    }

    $in.Close()
    $out.Close()
}

function Test-FileReady {
    param ($path)
    try {
        $s = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
        $s.Close()
        return $true
    } catch { return $false }
}

function Test-FolderReady {
    param ($folder)
    $files = Get-ChildItem $folder -File -Recurse -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) { return $false }

    foreach ($f in $files) {
        if ($f.LastWriteTime -gt (Get-Date).AddMinutes(-2)) { return $false }
        if (-not (Test-FileReady $f.FullName)) { return $false }
    }
    return $true
}

New-Item -ItemType Directory -Path $dest -Force | Out-Null
$global:idleCounter = 0

Write-Log "===== Script started ====="

while ($true) {

    $cycleFiles = 0
    $cycleFolders = 0
    $cycleBytes = 0

    # -------------------------
    # FOLDER HANDLING
    # -------------------------
    $folders = Get-ChildItem $source -Directory

    foreach ($folder in $folders) {

        if (-not (Test-FolderReady $folder.FullName)) { continue }

        $destPath = Join-Path $dest $folder.Name
        if (Test-Path $destPath) { continue }

        Write-Log "START folder: $($folder.Name)"

        try {
            $files = Get-ChildItem $folder.FullName -File -Recurse
            $i = 0

            foreach ($file in $files) {
                $i++

                $rel = $file.FullName.Substring($source.Length).TrimStart("\")
                $target = Join-Path $dest $rel
                $dir = Split-Path $target

                New-Item -ItemType Directory -Path $dir -Force | Out-Null

                Write-Log "  [$i/$($files.Count)] Moving: $($file.Name)"

                Copy-WithProgress $file.FullName $target

                Remove-Item $file.FullName -Force

                $cycleFiles++
                $cycleBytes += $file.Length
            }

            Remove-Item $folder.FullName -Force -Recurse

            Write-Log "DONE folder: $($folder.Name)"

            $cycleFolders++
        }
        catch {
            Write-Log "FAILED folder: $($folder.Name)"
            Write-Log $_.Exception.Message
        }
    }

    # -------------------------
    # LOOSE FILES
    # -------------------------
    $files = Get-ChildItem $source -File -Recurse | Where-Object {
        $_.LastWriteTime -lt (Get-Date).AddMinutes(-2) -and
        (Test-FileReady $_.FullName)
    }

    foreach ($file in $files) {

        $rel = $file.FullName.Substring($source.Length).TrimStart("\")
        $destPath = Join-Path $dest $rel
        $dir = Split-Path $destPath

        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        Write-Log "START file: $rel ($(Format-Size $file.Length))"

        try {
            Copy-WithProgress $file.FullName $destPath
            Remove-Item $file.FullName -Force

            Write-Log "DONE file: $rel"

            $cycleFiles++
            $cycleBytes += $file.Length
        }
        catch {
            Write-Log "FAILED file: $rel"
            Write-Log $_.Exception.Message
        }
    }

    # -------------------------
    # SUMMARY / IDLE
    # -------------------------
    if ($cycleFiles -gt 0 -or $cycleFolders -gt 0) {
        Write-Log "Summary: $cycleFolders folders, $cycleFiles files, $(Format-Size $cycleBytes)"
        $global:idleCounter = 0
    }
    else {
        $global:idleCounter++
        if ($global:idleCounter -ge 10) {
            Write-Log "Idle: no activity in last $($global:idleCounter) cycles"
            $global:idleCounter = 0
        }
    }

    Start-Sleep -Seconds $intervalSeconds
}