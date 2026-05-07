#requires -Version 7.0

$ErrorActionPreference = "Stop"

# =========================================================
# CONFIG
# =========================================================

$source = "C:\Users\YUDonno\Downloads\Completed"
$dest   = "\\yudonno-nas\Media\TV Shows\test"

$baseDir  = "B:\Scripts\Working"
$logDir   = Join-Path $baseDir "logs"
$debugLog = Join-Path $baseDir "debug.log"

$folderQuietSeconds = 15
$loopDelay = 5
$pauseOnError = $false

$ignoreExtensions = @(
    ".part",
    ".tmp",
    ".crdownload",
    ".!qb",
    ".partial"
)

# =========================================================
# STARTUP
# =========================================================

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# =========================================================
# LOGGING
# =========================================================

function Write-Log {
    param([string]$Message)

    $logFile = Join-Path $logDir (
        "move-files-" + (Get-Date -Format "yyyy-MM-dd") + ".log"
    )

    Add-Content -Path $logFile -Value (
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    )
}

function Write-DebugLog {
    param([string]$Message)

    Add-Content -Path $debugLog -Value (
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    )
}

# =========================================================
# HELPERS
# =========================================================

function Test-FileStable {
    param([string]$Path)

    try {

        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        $size1 = (Get-Item -LiteralPath $Path).Length

        Start-Sleep -Milliseconds 750

        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        $size2 = (Get-Item -LiteralPath $Path).Length

        return ($size1 -eq $size2)
    }
    catch {
        return $false
    }
}

function Test-FolderReady {
    param([string]$Folder)

    try {

        $files = Get-ChildItem `
            -LiteralPath $Folder `
            -Recurse `
            -File `
            -ErrorAction Stop

        foreach ($file in $files) {

            if (-not (Test-FileStable $file.FullName)) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-FolderSize {
    param([string]$Folder)

    try {

        $bytes = (
            Get-ChildItem `
                -LiteralPath $Folder `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum
        ).Sum

        if (-not $bytes) {
            $bytes = 0
        }

        return [math]::Round($bytes / 1GB, 2)
    }
    catch {
        return 0
    }
}

# =========================================================
# TRACKING
# =========================================================

$folderTracker = New-Object 'System.Collections.Generic.Dictionary[string,datetime]'
$processing = New-Object 'System.Collections.Generic.HashSet[string]'

# =========================================================
# STATS
# =========================================================

$stats = [PSCustomObject]@{
    MovedFolders = 0
    MovedFiles   = 0
    Failed       = 0
}

function Show-Dashboard {

    Write-Host ""
    Write-Host "========== STATUS ==========" -ForegroundColor Cyan
    Write-Host "Folders moved : $($stats.MovedFolders)"
    Write-Host "Loose files   : $($stats.MovedFiles)"
    Write-Host "Failures      : $($stats.Failed)"
    Write-Host "Tracked items : $($folderTracker.Count)"
    Write-Host "============================"
    Write-Host ""
}

# =========================================================
# PRELOAD
# =========================================================

Write-Host ""
Write-Host "Preloading folders..." -ForegroundColor Yellow

$existingFolders = Get-ChildItem `
    -LiteralPath $source `
    -Directory `
    -ErrorAction SilentlyContinue

foreach ($folder in $existingFolders) {
    $folderTracker[$folder.FullName] = [datetime]::Now
}

Write-Host "Preload complete" -ForegroundColor Green

# =========================================================
# MAIN LOOP
# =========================================================

Write-Host ""
Write-Host "Running (FINAL STABLE MODE)..." -ForegroundColor Green

while ($true) {

    # -----------------------------------------------------
    # DISCOVER NEW FOLDERS
    # -----------------------------------------------------

    $discoveredFolders = Get-ChildItem `
        -LiteralPath $source `
        -Directory `
        -ErrorAction SilentlyContinue

    foreach ($dir in $discoveredFolders) {

        if (-not $folderTracker.ContainsKey($dir.FullName)) {

            Write-Host ""
            Write-Host "Discovered new folder:" -ForegroundColor Cyan
            Write-Host "  $($dir.Name)"

            $folderTracker[$dir.FullName] = [datetime]::Now
        }
    }

    # -----------------------------------------------------
    # PROCESS FOLDERS
    # -----------------------------------------------------

    foreach ($folder in @($folderTracker.Keys)) {

        try {

            if ([string]::IsNullOrWhiteSpace($folder)) {
                continue
            }

            if (-not (Test-Path -LiteralPath $folder)) {

                $folderTracker.Remove($folder)

                continue
            }

            if ($processing.Contains($folder)) {
                continue
            }

            $lastSeen = $folderTracker[$folder]

            $age = (Get-Date) - $lastSeen

            if ($age.TotalSeconds -lt $folderQuietSeconds) {
                continue
            }

            $processing.Add($folder) | Out-Null

            if (-not (Test-FolderReady $folder)) {

                $folderTracker[$folder] = [datetime]::Now

                [void]$processing.Remove($folder)

                continue
            }

            $relative = $folder.Replace($source, "").TrimStart("\")

            $destPath = Join-Path $dest $relative

            # =================================================
            # MERGE MODE
            # =================================================

            if (Test-Path -LiteralPath $destPath) {

                Write-Host ""
                Write-Host "MERGING INTO EXISTING FOLDER" -ForegroundColor Yellow
                Write-Host "  $relative"

                $sourceFiles = Get-ChildItem `
                    -LiteralPath $folder `
                    -Recurse `
                    -File `
                    -ErrorAction SilentlyContinue

                foreach ($srcFile in $sourceFiles) {

                    try {

                        $relativeFile = $srcFile.FullName.Substring(
                            $folder.Length
                        ).TrimStart("\")

                        $targetFile = Join-Path $destPath $relativeFile

                        $targetDir = Split-Path $targetFile -Parent

                        New-Item `
                            -ItemType Directory `
                            -Path $targetDir `
                            -Force | Out-Null

                        if (Test-Path -LiteralPath $targetFile) {
                            continue
                        }

                        Move-Item `
                            -LiteralPath $srcFile.FullName `
                            -Destination $targetFile `
                            -ErrorAction Stop
                    }
                    catch {

                        Write-DebugLog $_.Exception.Message
                    }
                }

                try {

                    Remove-Item `
                        -LiteralPath $folder `
                        -Force `
                        -Recurse `
                        -ErrorAction SilentlyContinue
                }
                catch {}

                $stats.MovedFolders++

                $folderTracker.Remove($folder)

                [void]$processing.Remove($folder)

                continue
            }

            # =================================================
            # NORMAL MOVE
            # =================================================

            $sizeGB = Get-FolderSize $folder

            Write-Host ""
            Write-Host "MOVING FOLDER" -ForegroundColor Green
            Write-Host "  Name : $relative"
            Write-Host "  Size : $sizeGB GB"

            Move-Item `
                -LiteralPath $folder `
                -Destination $destPath `
                -ErrorAction Stop

            Write-Host "MOVE COMPLETE" -ForegroundColor Green

            Write-Log "Moved folder: $relative ($sizeGB GB)"

            $stats.MovedFolders++

            $folderTracker.Remove($folder)

            [void]$processing.Remove($folder)
        }
        catch {

            Write-Host ""
            Write-Host "=========== FOLDER ERROR ===========" -ForegroundColor Red
            Write-Host $_
            Write-Host ""

            Write-DebugLog $_.Exception.Message

            $stats.Failed++

            [void]$processing.Remove($folder)
        }
    }

    # -----------------------------------------------------
    # PROCESS LOOSE FILES
    # -----------------------------------------------------

    $looseFiles = Get-ChildItem `
        -LiteralPath $source `
        -File `
        -ErrorAction SilentlyContinue

    foreach ($file in $looseFiles) {

        try {

            if ($ignoreExtensions -contains $file.Extension) {
                continue
            }

            if (-not (Test-FileStable $file.FullName)) {
                continue
            }

            $destPath = Join-Path $dest $file.Name

            if (Test-Path -LiteralPath $destPath) {
                continue
            }

            Move-Item `
                -LiteralPath $file.FullName `
                -Destination $destPath `
                -ErrorAction Stop

            $stats.MovedFiles++
        }
        catch {

            Write-DebugLog $_.Exception.Message

            $stats.Failed++
        }
    }

    Show-Dashboard

    Start-Sleep -Seconds $loopDelay
}