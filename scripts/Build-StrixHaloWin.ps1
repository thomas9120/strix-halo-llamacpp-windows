<#
.SYNOPSIS
    Downloads the latest strix-halo-vulkan source from Nathanw1014/llama.cpp and builds
    llama-server / llama-cli / llama-bench for Windows (MSVC + Vulkan, AMD Strix Halo tuned).

.DESCRIPTION
    Steps:
      1. Clone or update the fork (default ref: strix-halo-vulkan branch tip).
      2. Locate MSVC (vcvars64.bat via vswhere), the Vulkan SDK (glslc + headers), and ninja.
      3. CMake configure + build, all inside a vcvars64 shell with cl.exe forced (so stray
         MinGW/gcc on PATH, e.g. Strawberry Perl, can never be picked up).
      4. Copy the portable binaries (exe + dll) to a dist folder and smoke-test device pickup.

    Requirements: git, cmake, ninja (or VS-bundled ninja), MSVC with C++ workload,
    Vulkan SDK with glslc (e.g. C:\VulkanSDK\<ver>).

.EXAMPLE
    .\Build-StrixHaloWin.ps1
    Builds the latest strix-halo-vulkan branch tip.

.EXAMPLE
    .\Build-StrixHaloWin.ps1 -Ref baf6360b
    Build a specific release payload (baf6360b = v0.6.4).

.EXAMPLE
    .\Build-StrixHaloWin.ps1 -Clean
    Wipe the build directory first for a from-scratch build.
#>
[CmdletBinding()]
param(
    [string]$Ref          = "strix-halo-vulkan",                       # branch, tag, or commit
    [string]$RepoUrl      = "https://github.com/Nathanw1014/llama.cpp.git",
    [string]$WorkDir      = $PSScriptRoot,                             # clone + dist live here
    [string]$BuildDirName = "build-win-vk",
    [string]$DistDirName  = "strix-halo-win",
    [string]$VcVars       = "",    # explicit path to vcvars64.bat (otherwise auto-detected)
    [string]$VulkanSdk    = "",    # explicit Vulkan SDK root (otherwise auto-detected)
    [switch]$Clean,              # delete build dir before configuring
    [switch]$NoDist            # skip copying binaries to the dist folder
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off

function Fail([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}
function Step([string]$msg) {
    Write-Host "`n== $msg ==" -ForegroundColor Cyan
}

# ---------------------------------------------------------------- toolchain discovery

function Find-VcVars([string]$explicit) {
    if ($explicit) {
        if (Test-Path $explicit) { return (Resolve-Path $explicit).Path }
        Fail "vcvars64.bat not found at '$explicit'"
    }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $installs = @()
    if (Test-Path $vswhere) {
        $json = & $vswhere -products * -format json
        if ($LASTEXITCODE -eq 0 -and $json) {
            $installs = ($json | ConvertFrom-Json) |
                Sort-Object { [version](($_.installationVersion -split '-')[0]) } -Descending
        }
    }
    foreach ($i in $installs) {
        $p = Join-Path $i.installationPath "VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path $p) { return $p }
    }
    # last resort: scan the usual locations
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        $hits = Get-ChildItem (Join-Path $root "Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvars64.bat") -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending
        foreach ($h in $hits) { return $h.FullName }
    }
    Fail "No Visual Studio with C++ build tools found. Install VS BuildTools with the 'Desktop development with C++' workload, or pass -VcVars <path>."
}

function Find-VulkanSdk([string]$explicit) {
    $candidates = @()
    if ($explicit)        { $candidates += $explicit }
    if ($env:VULKAN_SDK)  { $candidates += $env:VULKAN_SDK }
    if (Test-Path "C:\VulkanSDK") {
        $candidates += Get-ChildItem "C:\VulkanSDK" -Directory |
            Sort-Object { [version](($_.Name -replace '[^0-9.].*$','').TrimEnd('.')) } -Descending |
            ForEach-Object { $_.FullName }
    }
    foreach ($c in $candidates) {
        if ((Test-Path (Join-Path $c "Bin\glslc.exe")) -and
            (Test-Path (Join-Path $c "Include\vulkan")) -and
            (Test-Path (Join-Path $c "Lib\vulkan-1.lib"))) {
            return (Resolve-Path $c).Path
        }
    }
    Fail "No usable Vulkan SDK found (needs Bin\glslc.exe, Include\vulkan, Lib\vulkan-1.lib). Install the Vulkan SDK or pass -VulkanSdk <path>."
}

function Find-Ninja([string]$vsInstallPath) {
    $n = Get-Command ninja.exe -ErrorAction SilentlyContinue
    if ($n) { return $n.Source }
    if ($vsInstallPath) {
        $vs = Join-Path $vsInstallPath "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
        if (Test-Path $vs) { return $vs }
    }
    Fail "ninja.exe not found. Install it (winget install Ninja-build.Ninja) or use a VS installation that bundles it."
}

# ---------------------------------------------------------------- prerequisites

foreach ($tool in @("git", "cmake")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "'$tool' is not on PATH." }
}

$vcvars     = Find-VcVars $VcVars
$vsRoot     = Split-Path (Split-Path (Split-Path (Split-Path $vcvars)))   # ...\Microsoft Visual Studio\<ver>\<edition>
$sdk        = Find-VulkanSdk $VulkanSdk
$ninja      = Find-Ninja $vsRoot

Step "Toolchain"
Write-Host "  MSVC env   : $vcvars"
Write-Host "  Vulkan SDK : $sdk"
Write-Host "  ninja      : $ninja"
Write-Host "  Ref        : $Ref"

# ---------------------------------------------------------------- fetch source

$src = Join-Path $WorkDir "llama.cpp"
Step "Source"
if (-not (Test-Path (Join-Path $src ".git"))) {
    Write-Host "Cloning $RepoUrl ..."
    git clone $RepoUrl $src
    if ($LASTEXITCODE -ne 0) { Fail "git clone failed" }
} else {
    Write-Host "Updating existing clone at $src ..."
    git -C $src fetch origin --prune --tags
    if ($LASTEXITCODE -ne 0) { Fail "git fetch failed" }
}

# sync to the requested ref: branch tip if it exists on origin, else tag/commit
$remoteSha = git -C $src rev-parse --verify --quiet "origin/$Ref" 2>$null
if ($LASTEXITCODE -eq 0 -and $remoteSha) {
    git -C $src checkout -f -B $Ref "origin/$Ref"
} else {
    git -C $src checkout -f $Ref
}
if ($LASTEXITCODE -ne 0) { Fail "could not check out '$Ref'" }

if ((Test-Path (Join-Path $src ".gitmodules")) -and (Get-Item (Join-Path $src ".gitmodules")).Length -gt 0) {
    git -C $src submodule update --init --recursive
}

$commit = git -C $src rev-parse --short HEAD
Write-Host "Building $Ref @ $commit"

# ---------------------------------------------------------------- configure + build

$buildDir = Join-Path $src $BuildDirName
if ($Clean -and (Test-Path $buildDir)) {
    Step "Clean"
    Remove-Item $buildDir -Recurse -Force
}

$logFile = Join-Path $WorkDir "build-strix-halo-win.log"
$batFile = Join-Path $env:TEMP "build-strix-halo-win.bat"
$batContent = @"
@echo off
call "$vcvars" >nul || exit 1
where cl >nul 2>nul || exit 1
set PATH=$(Split-Path $ninja);%PATH%
cmake -S "$src" -B "$buildDir" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER=cl.exe -DCMAKE_CXX_COMPILER=cl.exe ^
  -DCMAKE_C_COMPILER_LAUNCHER= -DCMAKE_CXX_COMPILER_LAUNCHER= ^
  -DGGML_VULKAN=ON -DGGML_NATIVE=ON -DLLAMA_CURL=OFF ^
  -DVulkan_INCLUDE_DIR="$sdk\Include" ^
  -DVulkan_LIBRARY="$sdk\Lib\vulkan-1.lib" ^
  -DVulkan_GLSLC_EXECUTABLE="$sdk\Bin\glslc.exe" || exit 1
cmake --build "$buildDir" --target llama-server llama-cli llama-bench -j || exit 1
echo BUILD_OK
"@
Set-Content -Path $batFile -Value $batContent -Encoding ASCII

Step "Configure + build (log: $logFile)"
cmd /c "`"$batFile`"" 2>&1 | Tee-Object -FilePath $logFile
if ($LASTEXITCODE -ne 0) { Fail "build failed - see $logFile" }

# ---------------------------------------------------------------- package

$dist = Join-Path $WorkDir $DistDirName
if (-not $NoDist) {
    Step "Package -> $dist"
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Copy-Item (Join-Path $buildDir "bin\*.exe") $dist -Force
    Copy-Item (Join-Path $buildDir "bin\*.dll") $dist -Force
    $lic = Join-Path $src "LICENSE"
    if (Test-Path $lic) { Copy-Item $lic $dist -Force }
}

# ---------------------------------------------------------------- smoke test

Step "Smoke test"
& (Join-Path $buildDir "bin\llama-bench.exe") --version
& (Join-Path $buildDir "bin\llama-bench.exe") --list-devices
if ($LASTEXITCODE -ne 0) { Fail "Vulkan device pickup failed - check your AMD driver" }

Step "Done"
Write-Host "  Source : $src ($Ref @ $commit)"
Write-Host "  Build  : $buildDir"
if (-not $NoDist) { Write-Host "  Dist   : $dist" }
Write-Host ""
Write-Host "Run e.g.:"
Write-Host "  $(Join-Path $dist 'llama-server.exe') -m <model.gguf> -ngl 99 -ctk q8_0 -ctv q8_0"
