#Requires -Version 5.1
<#
  .SYNOPSIS
    Pacchettizza il driver Samsung TV (WebSocket) in un .c4z pronto per
    Composer Pro.

  .DESCRIPTION
    Un .c4z e' uno zip con driver.xml, driver.lua e le cartelle lib/, tv/,
    www/ alla RADICE dell'archivio (non annidate dentro "src"). Questo script:
      1. Incrementa <version> in driver.xml (formato YYMMDDNNN) e il default
         della proprieta' read-only "Driver Version". Composer Pro non
         ricarica la definizione di un driver gia' installato se <version>
         non aumenta (saltabile con -NoBump, per le build di release).
      2. Comprime il CONTENUTO di src/ in releases/samsung_tv_websocket.c4z.

    Lo zip e' creato con System.IO.Compression, SOLO file (nessuna voce di
    directory) e con "/" come separatore nei nomi delle voci: Compress-Archive
    su Windows PowerShell 5.1 scrive "\", contro lo standard ZIP, e Composer
    puo' non ricostruire la struttura a cartelle.

    Il nome del .c4z DEVE coincidere con <driver_name> in driver.xml.

  .EXAMPLE
    ./tools/build.ps1
    ./tools/build.ps1 -NoBump
#>
param(
    [switch]$NoBump
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$srcDir = Join-Path $repoRoot "src"
$buildDir = Join-Path $repoRoot "releases"
$driverName = "samsung_tv_websocket"
$c4zPath = Join-Path $buildDir "$driverName.c4z"
$driverXmlPath = Join-Path $srcDir "driver.xml"

if (-not (Test-Path $driverXmlPath)) {
    throw "driver.xml non trovato in $driverXmlPath"
}

# UTF-8 senza BOM, letto e scritto esplicitamente: Get-Content/Set-Content su
# Windows PowerShell 5.1 possono usare una code page diversa da quella del file.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$driverXmlContent = [System.IO.File]::ReadAllText($driverXmlPath, $utf8NoBom)

$nameMatch = [regex]::Match($driverXmlContent, '<driver_name>([^<]+)</driver_name>')
if (-not $nameMatch.Success -or $nameMatch.Groups[1].Value -ne $driverName) {
    throw "<driver_name> in driver.xml deve essere '$driverName'"
}

# ------------------------------------------------------------
# 1. Bump di <version> (YYMMDDNNN)
# ------------------------------------------------------------
if (-not $NoBump) {
    Write-Host "==> Aggiorno <version> in driver.xml..." -ForegroundColor Cyan
    $versionMatch = [regex]::Match($driverXmlContent, '<version>(\d{6})(\d{3})</version>')
    if (-not $versionMatch.Success) {
        throw "Tag <version>YYMMDDNNN</version> non trovato in $driverXmlPath"
    }
    $oldDatePart = $versionMatch.Groups[1].Value
    $oldSeq = [int]$versionMatch.Groups[2].Value
    $oldVersion = $oldDatePart + $versionMatch.Groups[2].Value

    $today = Get-Date -Format "yyMMdd"
    if ($oldDatePart -eq $today) { $newSeq = $oldSeq + 1 } else { $newSeq = 1 }
    $newVersion = $today + ("{0:D3}" -f $newSeq)
    if ([long]$newVersion -le [long]$oldVersion) {
        # orologio indietro rispetto alla versione corrente: mai diminuire
        $newVersion = [string]([long]$oldVersion + 1)
    }

    $driverXmlContent = $driverXmlContent.Substring(0, $versionMatch.Index) `
        + "<version>$newVersion</version>" `
        + $driverXmlContent.Substring($versionMatch.Index + $versionMatch.Length)
    $driverXmlContent = [regex]::Replace($driverXmlContent,
        '(<name>Driver Version</name>\s*<type>STRING</type>\s*<readonly>true</readonly>\s*<default>)\d+(</default>)',
        ('${1}' + $newVersion + '${2}'))
    [System.IO.File]::WriteAllText($driverXmlPath, $driverXmlContent, $utf8NoBom)
    Write-Host "    $oldVersion -> $newVersion"
}

# ------------------------------------------------------------
# 2. Pacchettizzazione
# ------------------------------------------------------------
Write-Host "==> Creo $driverName.c4z..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
if (Test-Path $c4zPath) { Remove-Item -Force -Confirm:$false $c4zPath }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tempZipPath = Join-Path $buildDir "$driverName.zip"
if (Test-Path $tempZipPath) { Remove-Item -Force -Confirm:$false $tempZipPath }

$zipArchive = [System.IO.Compression.ZipFile]::Open($tempZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Push-Location $srcDir
    try {
        foreach ($file in (Get-ChildItem -Recurse -File)) {
            $relativePath = Resolve-Path -LiteralPath $file.FullName -Relative
            if ($relativePath.StartsWith(".\") -or $relativePath.StartsWith("./")) {
                $relativePath = $relativePath.Substring(2)
            }
            $relativePath = $relativePath.Replace([char]92, [char]47)

            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zipArchive, $file.FullName, $relativePath, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            Write-Host "    + $relativePath"
        }
    } finally {
        Pop-Location
    }
} finally {
    $zipArchive.Dispose()
}

Rename-Item -Path $tempZipPath -NewName "$driverName.c4z"

Write-Host "==> Fatto: $c4zPath" -ForegroundColor Green
Write-Host "    Installa/aggiorna questo file in Composer Pro." -ForegroundColor Yellow
