# ODM_batch_repair_makernote_batch.ps1
$baseInput   = "C:\Users\dj_kone\dataset\opendrone\images"
$baseOutput  = "D:\resultats_odm"
$summaryCsv  = Join-Path $baseOutput "odm_batch_summary.csv"

# Paramètres ODM
$maxConcurrency    = 8
$dockerMemory      = "26g"
$dockerMemorySwap  = "34g"
$dockerShm         = "8g"
$odmImage          = "opendronemap/odm:latest"

New-Item -ItemType Directory -Path $baseOutput -Force | Out-Null

if (-not (Test-Path $summaryCsv)) {
    "Projet,NombreImagesBrut,ImagesRepareesMakerNote,ImagesEncoreFautivesApresReparation,Split,MaxConcurrency,DateDebut,DateFin,DureeMinutes,Statut,CodeRetour,LogFile,OutputPath" |
        Out-File -FilePath $summaryCsv -Encoding utf8
}

function Get-SplitValue {
    param([int]$ImageCount)

    if ($ImageCount -gt 1000) { return 300 }
    elseif ($ImageCount -gt 500) { return 250 }
    else { return $null }
}

function Invoke-ODMRunDirectSource {
    param(
        [string]$ProjectName,
        [string]$ProjectOutputPath,
        [string]$SourceFolder,
        [string]$RunLogFile
    )

    $imageCount = (Get-ChildItem -Path $SourceFolder -File | Where-Object { $_.Extension -match '^\.(jpg|jpeg|JPG|JPEG)$' }).Count
    $splitValue = Get-SplitValue -ImageCount $imageCount

    $dockerArgs = @(
        "run", "--rm",
        "--memory=$dockerMemory",
        "--memory-swap=$dockerMemorySwap",
        "--shm-size=$dockerShm",
        "--gpus", "all",
        "-v", "${SourceFolder}:/datasets/$ProjectName/images",
        "-v", "${ProjectOutputPath}:/datasets/$ProjectName",
        $odmImage,
        "--project-path", "/datasets",
        $ProjectName,
        "--max-concurrency", "$maxConcurrency",
        "--dsm",
        "--dtm",
        "--pc-las",
        "--fast-orthophoto",
        "--skip-3dmodel",
        "--orthophoto-resolution", "5",
        "--dem-resolution", "5",
        "--feature-quality", "medium",
        "--pc-quality", "medium"
    )

    if ($splitValue) {
        $dockerArgs += @("--split", "$splitValue", "--split-overlap", "50")
    }

    "----------------------------------------" | Out-File -FilePath $RunLogFile -Append -Encoding utf8
    "Commande ODM :" | Out-File -FilePath $RunLogFile -Append -Encoding utf8
    ("docker " + ($dockerArgs -join " ")) | Out-File -FilePath $RunLogFile -Append -Encoding utf8
    "----------------------------------------" | Out-File -FilePath $RunLogFile -Append -Encoding utf8

    & docker @dockerArgs 2>&1 | Tee-Object -FilePath $RunLogFile -Append
    return $LASTEXITCODE
}

function Test-IsMakerNoteCrash {
    param([string]$LogFile)

    if (-not (Test-Path $LogFile)) { return $false }

    $content = Get-Content $LogFile -Raw
    $patterns = @(
        "MakerNote",
        "decode_maker_note",
        "dji.TAGS",
        "IndexError",
        "exifread"
    )

    foreach ($p in $patterns) {
        if ($content -match [regex]::Escape($p)) {
            return $true
        }
    }
    return $false
}

function Invoke-EXIFPrecheckByManifest {
    param(
        [string]$InputFolder,
        [string[]]$CandidateNames,
        [string]$ProjectOutputPath,
        [string]$LogFile,
        [string]$ResultFileName
    )

    $scannerPy   = Join-Path $ProjectOutputPath "_scan_exif_manifest.py"
    $manifestTxt = Join-Path $ProjectOutputPath "_manifest_images.txt"
    $resultTxt   = Join-Path $ProjectOutputPath $ResultFileName

    if (Test-Path $manifestTxt) { Remove-Item $manifestTxt -Force }
    if (Test-Path $resultTxt)   { Remove-Item $resultTxt -Force }

    $CandidateNames | Set-Content -Path $manifestTxt -Encoding UTF8

    $pyCode = @'
import os
import sys
import exifread

folder = sys.argv[1]
manifest = sys.argv[2]
out_file = sys.argv[3]

bad = []

with open(manifest, "r", encoding="utf-8") as f:
    names = [line.strip() for line in f if line.strip()]

for name in names:
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        bad.append((name, "FILE_NOT_FOUND"))
        continue

    try:
        with open(path, "rb") as imgf:
            exifread.process_file(imgf, details=True)
    except Exception as e:
        bad.append((name, str(e).replace("\n", " ")))

with open(out_file, "w", encoding="utf-8") as w:
    for name, err in bad:
        w.write(f"{name}\t{err}\n")

print(f"BAD_COUNT={len(bad)}")
'@

    Set-Content -Path $scannerPy -Value $pyCode -Encoding UTF8

    $dockerArgs = @(
        "run", "--rm",
        "--entrypoint", "python3",
        "-v", "${InputFolder}:/scan_input",
        "-v", "${ProjectOutputPath}:/scan_output",
        $odmImage,
        "/scan_output/_scan_exif_manifest.py",
        "/scan_input",
        "/scan_output/_manifest_images.txt",
        "/scan_output/$ResultFileName"
    )

    "----------------------------------------" | Out-File -FilePath $LogFile -Append -Encoding utf8
    "Commande scan EXIF ciblé :" | Out-File -FilePath $LogFile -Append -Encoding utf8
    ("docker " + ($dockerArgs -join " ")) | Out-File -FilePath $LogFile -Append -Encoding utf8
    "----------------------------------------" | Out-File -FilePath $LogFile -Append -Encoding utf8

    & docker @dockerArgs 2>&1 | Tee-Object -FilePath $LogFile -Append

    $badNames = @()

    if (Test-Path $resultTxt) {
        $badNames = Get-Content $resultTxt | ForEach-Object {
            $line = $_.ToString().Trim()
            if ($line -match "^(.*?)\t") {
                $matches[1].Trim()
            }
        } | Where-Object { $_ -and $_.Trim() -ne "" } | Sort-Object -Unique
    }

    return $badNames
}

function Repair-BadImagesMakerNoteBatch {
    param(
        [string]$SourceFolder,
        [string[]]$BadNames,
        [string]$LogFile
    )

    if (-not $BadNames -or $BadNames.Count -eq 0) {
        return
    }

    $paths = @()
    foreach ($name in $BadNames) {
        $imgPath = Join-Path $SourceFolder $name
        if (Test-Path $imgPath) {
            $paths += $imgPath
        }
    }

    if ($paths.Count -eq 0) {
        return
    }

    Write-Host "Réparation MakerNote en lot : $($paths.Count) image(s)" -ForegroundColor Yellow

    $args = @("-overwrite_original", "-MakerNotes=")
    $args += $paths

    & exiftool @args 2>&1 | Tee-Object -FilePath $LogFile -Append
}

function Hide-BadImages {
    param(
        [string]$SourceFolder,
        [string[]]$BadNames
    )

    foreach ($name in $BadNames) {
        $src = Join-Path $SourceFolder $name
        $dstName = "$name.bad"

        if (Test-Path $src) {
            Rename-Item -Path $src -NewName $dstName -Force
        }
    }
}

function Restore-HiddenBadImages {
    param([string]$SourceFolder)

    $hiddenFiles = Get-ChildItem -Path $SourceFolder -File | Where-Object {
        $_.Name -match '\.(jpg|jpeg|JPG|JPEG)\.bad$'
    }

    foreach ($file in $hiddenFiles) {
        $originalName = $file.Name -replace '\.bad$',''
        Rename-Item -Path $file.FullName -NewName $originalName -Force
    }
}

$dossiers = Get-ChildItem -Path $baseInput -Directory
$total = $dossiers.Count
$i = 1

foreach ($dossier in $dossiers) {
    $nom = $dossier.Name
    $projectInputPath   = $dossier.FullName
    $projectOutputPath  = Join-Path $baseOutput $nom
    $logFile            = Join-Path $projectOutputPath "odm_log.txt"
    $doneFlag           = Join-Path $projectOutputPath "_SUCCESS.txt"
    $beforeRepairFile   = "images_fautives_exif_before_repair.txt"
    $afterRepairFile    = "images_fautives_exif_after_repair.txt"

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "[$i/$total] Traitement : $nom" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    New-Item -ItemType Directory -Path $projectOutputPath -Force | Out-Null

    if (Test-Path $doneFlag) {
        Write-Host "Projet déjà traité, ignoré : $nom" -ForegroundColor DarkYellow
        $line = '"' + ($nom -replace '"','""') + '",' +
                '0,0,0,' +
                '"Déjà traité",' +
                "$maxConcurrency," +
                '"' + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + '",' +
                '"' + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + '",' +
                '0,' +
                '"SKIPPED",' +
                '0,' +
                '"' + ($logFile -replace '"','""') + '",' +
                '"' + ($projectOutputPath -replace '"','""') + '"'
        Add-Content -Path $summaryCsv -Value $line
        $i++
        continue
    }

    $allImages = Get-ChildItem -Path $projectInputPath -File |
        Where-Object { $_.Extension -match '^\.(jpg|jpeg|JPG|JPEG)$' } |
        Sort-Object Name

    $rawImageCount = $allImages.Count
    Write-Host "Nombre d'images brut : $rawImageCount" -ForegroundColor Yellow

    if ($rawImageCount -eq 0) {
        Write-Host "Aucune image trouvée. Projet ignoré." -ForegroundColor Red
        $line = '"' + ($nom -replace '"','""') + '",' +
                '0,0,0,' +
                '"Aucun",' +
                "$maxConcurrency," +
                '"' + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + '",' +
                '"' + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + '",' +
                '0,' +
                '"NO_IMAGES",' +
                '1,' +
                '"' + ($logFile -replace '"','""') + '",' +
                '"' + ($projectOutputPath -replace '"','""') + '"'
        Add-Content -Path $summaryCsv -Value $line
        $i++
        continue
    }

    "========================================" | Out-File -FilePath $logFile -Encoding utf8
    "Projet : $nom" | Out-File -FilePath $logFile -Append -Encoding utf8
    "Images brutes : $rawImageCount" | Out-File -FilePath $logFile -Append -Encoding utf8
    "========================================" | Out-File -FilePath $logFile -Append -Encoding utf8

    $dateDebut = Get-Date
    $returnCode = Invoke-ODMRunDirectSource -ProjectName $nom -ProjectOutputPath $projectOutputPath -SourceFolder $projectInputPath -RunLogFile $logFile

    $repairedCount = 0
    $stillBadCount = 0
    $usedImageCount = $rawImageCount

    if ($returnCode -ne 0) {
        Write-Host "Crash EXIF / MakerNote détecté. Début de la réparation ciblée..." -ForegroundColor Yellow

        $allNames = $allImages | ForEach-Object { $_.Name }

        $badExifNames = @(Invoke-EXIFPrecheckByManifest -InputFolder $projectInputPath -CandidateNames $allNames -ProjectOutputPath $projectOutputPath -LogFile $logFile -ResultFileName $beforeRepairFile)
        $badExifNames = $badExifNames |
            Where-Object { $_ -ne $null -and $_.ToString().Trim() -ne "" } |
            ForEach-Object { $_.ToString().Trim() } |
            Sort-Object -Unique

        $repairedCount = $badExifNames.Count
        Write-Host "Images à réparer (MakerNote) : $repairedCount" -ForegroundColor Yellow

        if ($repairedCount -gt 0) {
            Repair-BadImagesMakerNoteBatch -SourceFolder $projectInputPath -BadNames $badExifNames -LogFile $logFile

            $badAfterRepair = @(Invoke-EXIFPrecheckByManifest -InputFolder $projectInputPath -CandidateNames $allNames -ProjectOutputPath $projectOutputPath -LogFile $logFile -ResultFileName $afterRepairFile)
            $badAfterRepair = $badAfterRepair |
                Where-Object { $_ -ne $null -and $_.ToString().Trim() -ne "" } |
                ForEach-Object { $_.ToString().Trim() } |
                Sort-Object -Unique

            $stillBadCount = $badAfterRepair.Count
            Write-Host "Images encore fautives après réparation : $stillBadCount" -ForegroundColor Cyan

            if ($stillBadCount -gt 0) {
                Write-Host "Masquage temporaire du reliquat..." -ForegroundColor Gray
                Hide-BadImages -SourceFolder $projectInputPath -BadNames $badAfterRepair
                $usedImageCount = $rawImageCount - $stillBadCount
            }

            try {
                Write-Host "Relance ODM après réparation..." -ForegroundColor Cyan
                $returnCode = Invoke-ODMRunDirectSource -ProjectName $nom -ProjectOutputPath $projectOutputPath -SourceFolder $projectInputPath -RunLogFile $logFile
            }
            finally {
                Restore-HiddenBadImages -SourceFolder $projectInputPath
            }
        }
    }

    $dateFin = Get-Date
    $duree = [math]::Round((New-TimeSpan -Start $dateDebut -End $dateFin).TotalMinutes, 2)
    $splitLabel = if (Get-SplitValue -ImageCount $usedImageCount) { (Get-SplitValue -ImageCount $usedImageCount) } else { "Sans split" }

    if ($returnCode -eq 0) {
        Write-Host "[$i/$total] Terminé : $nom" -ForegroundColor Green
        Write-Host "Durée : $duree minutes" -ForegroundColor Green
        "Projet traité avec succès." | Out-File -FilePath $doneFlag -Encoding utf8
        $statut = "SUCCESS"
    }
    else {
        Write-Host "[$i/$total] ERREUR : $nom (code $returnCode)" -ForegroundColor Red
        Write-Host "Échec du projet $nom, passage au dossier suivant..." -ForegroundColor Yellow
        $statut = "FAILED"
    }

    $line = '"' + ($nom -replace '"','""') + '",' +
            "$rawImageCount," +
            "$repairedCount," +
            "$stillBadCount," +
            '"' + ($splitLabel.ToString() -replace '"','""') + '",' +
            "$maxConcurrency," +
            '"' + $dateDebut.ToString("yyyy-MM-dd HH:mm:ss") + '",' +
            '"' + $dateFin.ToString("yyyy-MM-dd HH:mm:ss") + '",' +
            "$duree," +
            '"' + $statut + '",' +
            "$returnCode," +
            '"' + ($logFile -replace '"','""') + '",' +
            '"' + ($projectOutputPath -replace '"','""') + '"'

    Add-Content -Path $summaryCsv -Value $line

    $i++
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tous les $total dossiers sont parcourus." -ForegroundColor Green
Write-Host "Résumé CSV : $summaryCsv" -ForegroundColor Green
Write-Host "Résultats : $baseOutput" -ForegroundColor Green