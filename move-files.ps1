# Moves completed downloads:
# - Moves full folders when ready
# - Moves loose files individually
# - Skips in-use files
# - Cleans up empty folders
# Created: 2026-05-05
$source = "C:\Users\YUDonno\Downloads\Completed"
$dest   = "T:\test"
$intervalSeconds = 60

New-Item -ItemType Directory -Path $dest -Force | Out-Null

function Test-FileReady {
    param ($path)
    try {
        $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
        $stream.Close()
        return $true
    } catch {
        return $false
    }
}

function Test-FolderReady {
    param ($folder)

    $files = Get-ChildItem -Path $folder -File -Recurse -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) { return $false }

    foreach ($file in $files) {
        if ($file.LastWriteTime -gt (Get-Date).AddMinutes(-2)) { return $false }
        if (-not (Test-FileReady $file.FullName)) { return $false }
    }

    return $true
}

while ($true) {

    Write-Host "`nScanning at $(Get-Date)..."

    # -------------------------
    # 1. MOVE COMPLETE FOLDERS
    # -------------------------
    $folders = Get-ChildItem -Path $source -Directory -ErrorAction SilentlyContinue

    foreach ($folder in $folders) {

        if (-not (Test-FolderReady $folder.FullName)) {
            Write-Host "Skipping folder (not ready): $($folder.Name)"
            continue
        }

        try {
            $destPath = Join-Path $dest $folder.Name

            if (Test-Path $destPath) {
                Write-Host "Skipped folder (exists): $($folder.Name)"
                continue
            }

            Move-Item -Path $folder.FullName -Destination $destPath -Force
            Write-Host "Moved folder: $($folder.Name)"
        }
        catch {
            Write-Host "Failed folder: $($folder.Name)"
            Write-Host $_.Exception.Message
        }
    }

    # -------------------------
    # 2. MOVE LOOSE FILES
    # -------------------------
    $files = Get-ChildItem -Path $source -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -lt (Get-Date).AddMinutes(-2) -and
        (Test-FileReady $_.FullName)
    }

    foreach ($file in $files) {

        $sourcePath = $file.FullName

        if (!(Test-Path $sourcePath)) { continue }

        try {
            # Preserve relative structure
            $relativePath = $sourcePath.Substring($source.Length).TrimStart("\")
            $destPath = Join-Path $dest $relativePath

            $destDir = Split-Path $destPath
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null

            if (Test-Path $destPath) {
                Write-Host "Skipped file (exists): $relativePath"
                continue
            }

            Copy-Item -Path $sourcePath -Destination $destPath -Force

            if ((Get-Item $destPath).Length -eq $file.Length) {
                Remove-Item $sourcePath -Force
                Write-Host "Moved file: $relativePath"
            } else {
                Write-Host "Verification failed: $relativePath"
            }
        }
        catch {
            Write-Host "Failed file: $sourcePath"
            Write-Host $_.Exception.Message
        }
    }

    # -------------------------
    # 3. CLEAN EMPTY FOLDERS
    # -------------------------
    Get-ChildItem -Path $source -Directory -Recurse |
    Sort-Object FullName -Descending |
    ForEach-Object {
        if (-not (Get-ChildItem $_.FullName -Force)) {
            try {
                Remove-Item $_.FullName -Force
                Write-Host "Removed empty folder: $($_.FullName)"
            } catch {}
        }
    }

    Write-Host "Waiting $intervalSeconds seconds..."
    Start-Sleep -Seconds $intervalSeconds
}