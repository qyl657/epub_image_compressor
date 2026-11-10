param(
    [switch]$Build,
    [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

if ($Build) {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
}

$ReleaseDir = Join-Path $RepoRoot "build\windows\x64\runner\Release"
if (-not (Test-Path $ReleaseDir)) { throw "Release dir not found: $ReleaseDir" }

# System32 里的 VC++ 2015-2022 运行时；干净系统默认没有，缺了会报丢失 MSVCP140.dll
$VcRuntime = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")

$Version = (Select-String -Path "pubspec.yaml" -Pattern "^version:\s*(\S+)\+").Matches[0].Groups[1].Value
$Stage = Join-Path $env:TEMP "epubpack_$(Get-Random)"
New-Item -ItemType Directory -Path $Stage | Out-Null

try {
    Get-ChildItem $ReleaseDir -Exclude "*.zip" | Copy-Item -Destination $Stage -Recurse -Force
    foreach ($dll in $VcRuntime) {
        $src = Join-Path $env:SystemRoot "System32\$dll"
        if (-not (Test-Path $src)) { throw "VC runtime missing on this machine: $src" }
        Copy-Item $src $Stage -Force
    }

    # 引擎启动硬性依赖，缺任何一个都会导致双击闪退
    $Required = @(
        "epub_image_compressor.exe", "flutter_windows.dll",
        "data\icudtl.dat", "data\app.so",
        "data\flutter_assets\AssetManifest.bin", "data\flutter_assets\FontManifest.json"
    ) + $VcRuntime
    foreach ($f in $Required) {
        if (-not (Test-Path (Join-Path $Stage $f))) { throw "打包校验失败，缺少 $f" }
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $ZipPath = Join-Path (Resolve-Path $OutDir) "epub_image_compressor_v${Version}_win64.zip"
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

    # 必须用 System32 的 bsdtar：Git 自带的 GNU tar 不支持 zip；
    # 而 .NET CreateFromDirectory 写反斜杠条目，非 Windows 解压工具会丢掉 data/ 目录
    $Tar = Join-Path $env:SystemRoot "System32\tar.exe"
    if (-not (Test-Path $Tar)) { throw "需要 Windows 10 1803+ 自带的 tar.exe" }

    $Entries = @(Get-ChildItem $Stage | ForEach-Object { $_.Name })
    & $Tar -a -c -f $ZipPath -C $Stage $Entries
    if ($LASTEXITCODE -ne 0) { throw "tar 打包失败，退出码 $LASTEXITCODE" }

    $Files = (Get-ChildItem $Stage -Recurse -File).Count
    $Size = [math]::Round((Get-Item $ZipPath).Length / 1MB, 1)
    Write-Host "OK -> $ZipPath  ($Size MB, $Files files)" -ForegroundColor Green
}
finally {
    Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
}
