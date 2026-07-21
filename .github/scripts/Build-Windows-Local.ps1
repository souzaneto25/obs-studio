<#
.SYNOPSIS
    Instala dependências e builda o OBS Studio com Dynamic Stream Delay para Windows x64.
.DESCRIPTION
    Script para build local. Requer PowerShell 7+ e execução como Administrador.
    Instala automaticamente: VS Build Tools 2026 (workload C++), Windows SDK, CMake, 7zip.
.EXAMPLE
    # Abra PowerShell 7 como Administrador e execute:
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\Build-Windows-Local.ps1
#>

[CmdletBinding()]
param(
    [ValidateSet('RelWithDebInfo', 'Release', 'Debug')]
    [string] $Config = 'RelWithDebInfo'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- helpers ----------------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "  OK  $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "  WARN  $msg" -ForegroundColor Yellow
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal] $id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WingetPackage([string]$id, [string]$displayName, [string]$override = '') {
    $already = winget list --id $id --accept-source-agreements 2>&1
    if ($already -match $id) {
        Write-Ok "$displayName já instalado."
        return
    }
    Write-Step "Instalando $displayName..."
    $args = @('install', '--id', $id,
              '--accept-package-agreements', '--accept-source-agreements',
              '--silent', '--disable-interactivity')
    if ($override) { $args += @('--override', $override) }
    winget @args
    if ($LASTEXITCODE -notin 0, 3010) {
        throw "Falha ao instalar $displayName (código $LASTEXITCODE)"
    }
    Write-Ok "$displayName instalado."
}

# ---- pré-requisitos ---------------------------------------------------------

Write-Step "Verificando requisitos..."

if ($PSVersionTable.PSVersion -lt [version]'7.0') {
    Write-Host @"
Este script requer PowerShell 7+.
Instale via: winget install Microsoft.PowerShell
Depois reabra como Administrador e execute novamente.
"@ -ForegroundColor Red
    exit 1
}

if (-not (Test-Admin)) {
    Write-Host "Execute este script como Administrador." -ForegroundColor Red
    exit 1
}

Write-Ok "PowerShell $($PSVersionTable.PSVersion), rodando como admin."

# ---- instalar dependências --------------------------------------------------

Write-Step "Verificando Visual Studio 2026 Build Tools com workload C++..."

$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) {
    $vsWhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
}

$hasVcTools = $false
if (Test-Path $vsWhere) {
    $vsInstalls = & $vsWhere -all -format json 2>$null | ConvertFrom-Json
    foreach ($vs in $vsInstalls) {
        if ($vs.installationVersion -like '18.*') {
            $comps = & $vsWhere -installationPath $vs.installationPath -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null
            if ($comps) { $hasVcTools = $true; break }
        }
    }
}

if (-not $hasVcTools) {
    Write-Step "Instalando VS Build Tools 2026 + C++ Desktop workload (~4-6 GB, pode demorar 10-20 min)..."
    Install-WingetPackage `
        -id 'Microsoft.VisualStudio.BuildTools' `
        -displayName 'Visual Studio Build Tools 2026' `
        -override (
            '--add Microsoft.VisualStudio.Workload.VCTools ' +
            '--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ' +
            '--add Microsoft.VisualStudio.Component.Windows11SDK.26100 ' +
            '--add Microsoft.VisualStudio.Component.VC.CMake.Project ' +
            '--quiet --wait --norestart'
        )
} else {
    Write-Ok "VS Build Tools 2026 com workload C++ já presente."
}

Install-WingetPackage -id 'Kitware.CMake'     -displayName 'CMake'
Install-WingetPackage -id '7zip.7zip'          -displayName '7-Zip'

# Atualiza PATH da sessão para pegar os novos executáveis
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') +
            ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# ---- localizar cmake --------------------------------------------------------

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    # Localização padrão do winget
    $cmakePath = "${env:ProgramFiles}\CMake\bin"
    if (Test-Path "$cmakePath\cmake.exe") {
        $env:Path = "$cmakePath;$env:Path"
        $cmake = Get-Command cmake
    }
}
if (-not $cmake) { throw "cmake não encontrado no PATH após instalação." }
Write-Ok "cmake: $($cmake.Source)"

# ---- configurar e buildar ---------------------------------------------------

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $repoRoot

try {
    Write-Step "Atualizando submódulos..."
    git submodule update --init --recursive

    Write-Step "Configurando (cmake --preset windows-x64)..."
    $env:CI = '1'   # requerido pelo Build-Windows.ps1; aqui usamos cmake diretamente
    cmake --preset windows-x64
    if ($LASTEXITCODE -ne 0) { throw "cmake configure falhou." }

    Write-Step "Compilando (config=$Config, paralelo)..."
    cmake --build build_x64 --config $Config --parallel
    if ($LASTEXITCODE -ne 0) { throw "cmake build falhou." }

    Write-Step "Instalando em build_x64\install..."
    cmake --install build_x64 --config $Config --prefix "$repoRoot\build_x64\install"
    if ($LASTEXITCODE -ne 0) { throw "cmake install falhou." }

    # ---- empacotar ----------------------------------------------------------
    Write-Step "Empacotando..."
    $version = git describe --always --tags --dirty=-modified 2>$null
    $pkgName = "obs-studio-$version-windows-x64"
    $pkgDir  = "$repoRoot\build_x64\package"
    $zipPath = "$repoRoot\build_x64\$pkgName.zip"

    if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force }
    New-Item -ItemType Directory -Path $pkgDir | Out-Null
    Copy-Item "$repoRoot\build_x64\install\*" $pkgDir -Recurse

    Compress-Archive -Path "$pkgDir\*" -DestinationPath $zipPath -Force
    Write-Ok "Zip criado: $zipPath"

    # ---- copiar para o Desktop do Windows -----------------------------------
    $desktop = [Environment]::GetFolderPath('Desktop')
    $destDir = "$desktop\OBS-Dynamic-Delay"
    if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }
    Copy-Item $pkgDir $destDir -Recurse
    Write-Ok "Build copiado para: $destDir"

    $destZip = "$desktop\$pkgName.zip"
    Copy-Item $zipPath $destZip -Force
    Write-Ok "Zip copiado para: $destZip"

    Write-Host "`n======================================================" -ForegroundColor Green
    Write-Host " BUILD CONCLUIDO COM SUCESSO" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
    Write-Host " Executavel: $destDir\bin\64bit\obs64.exe"
    Write-Host " Zip:        $destZip"
    Write-Host "======================================================`n" -ForegroundColor Green

} finally {
    Pop-Location
}
