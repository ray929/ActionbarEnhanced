@echo off
setlocal
set "SrcDir=%~dp0"
set "ScriptName=%~nx0"
set "FilePath=%~f0"
set "PsFile=%TEMP%\pack-addon-%RANDOM%.ps1"
powershell -NoProfile -Command "$s=[IO.File]::ReadAllText($env:FilePath); $m='##POWERHELL_CODE##'; $i=$s.LastIndexOf($m); if($i -ge 0){ [IO.File]::WriteAllText($env:PsFile, $s.Substring($i+$m.Length)) }"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PsFile%"
set "exitcode=%ERRORLEVEL%"
del "%PsFile%" 2>nul
endlocal
exit /b %exitcode%

##POWERHELL_CODE##

$SrcDir = $env:SrcDir.TrimEnd('\')
$ScriptName = $env:ScriptName
$addon = Split-Path -Leaf $SrcDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$desktop = [Environment]::GetFolderPath("Desktop")
$zip = Join-Path $desktop "$addon-$timestamp.zip"

$staging = Join-Path $env:TEMP "$addon-$timestamp"
$addonDir = Join-Path $staging $addon
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
$null = New-Item -ItemType Directory -Path $addonDir -Force

Push-Location $SrcDir
$files = git ls-files --cached --others --exclude-standard
Pop-Location

$exclude = @('AGENTS.md', 'docs/*', 'reasonix.toml', '.reasonix/*', '.codebuddy/*', '.workbuddy/*', '.trae/*', '.trae-cn/*', '.temp/*', '.test/*', $ScriptName)

foreach ($file in $files) {
    $skip = $false
    $fileUnix = $file -replace '\\', '/'
    foreach ($pat in $exclude) {
        if ($fileUnix -like $pat) { $skip = $true; break }
    }
    if ($skip) { continue }
    $srcFile = Join-Path $SrcDir $file
    $dstFile = Join-Path $addonDir $file
    $dstParent = Split-Path -Parent $dstFile
    if (-not (Test-Path $dstParent)) { $null = New-Item -ItemType Directory -Path $dstParent -Force }
    Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
}

if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$compression = [System.IO.Compression.CompressionLevel]::Optimal
[System.IO.Compression.ZipFile]::CreateFromDirectory($addonDir, $zip, $compression, $true)
Remove-Item $staging -Recurse -Force
Write-Host "Created: $zip"
