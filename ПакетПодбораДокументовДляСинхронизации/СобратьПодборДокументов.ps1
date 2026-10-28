[CmdletBinding()]
param(
    [string]$DesignerPath,
    [string]$OutputPath = '.\output\ПодборДокументовДляСинхронизации.epf',
    [ValidateRange(30, 1800)]
    [int]$DesignerTimeoutSeconds = 180,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

$packageRoot = $PSScriptRoot
$configPath = Join-Path $packageRoot 'epf-template.json'
$config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$templateModulePath = Join-Path $packageRoot 'Forms\Форма\Ext\Form\Module.bsl'
$definitionPath = Join-Path $packageRoot 'ОпределениеФормы.json'
$builderPath = Join-Path $packageRoot 'New-EpfFromDefinition.ps1'

foreach ($requiredPath in @($templateModulePath, $definitionPath, $builderPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required package file not found: $requiredPath"
    }
}

if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $packageRoot $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if (-not $ValidateOnly -and -not $DesignerPath) {
    $candidatePaths = @()
    $programFilesRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($programFilesRoot in $programFilesRoots) {
        $oneCInstallRoot = Join-Path $programFilesRoot '1cv8'
        if (Test-Path -LiteralPath $oneCInstallRoot -PathType Container) {
            $candidatePaths += Get-ChildItem -LiteralPath $oneCInstallRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'bin\1cv8.exe' }
        }
    }

    $requiredVersion = [string]$config.requiredPlatformVersion
    $DesignerPath = @($candidatePaths | Where-Object {
        if (Test-Path -LiteralPath $_ -PathType Leaf) {
            (Get-Item -LiteralPath $_).VersionInfo.ProductVersion -match [regex]::Escape($requiredVersion)
        }
    } | Select-Object -First 1)
    if (-not $DesignerPath) {
        throw "Designer $requiredVersion was not found. Rerun with -DesignerPath 'C:\Path\To\1cv8.exe'."
    }
    $DesignerPath = [string]$DesignerPath
}

$buildParameters = @{
    ModulePath = $templateModulePath
    DefinitionPath = $definitionPath
    TemplateDirectory = $packageRoot
    OutputPath = $OutputPath
    DesignerTimeoutSeconds = $DesignerTimeoutSeconds
    NoInfobase = $true
}

if ($ValidateOnly) {
    $buildParameters.ValidateOnly = $true
}
else {
    $buildParameters.DesignerPath = (Resolve-Path -LiteralPath $DesignerPath).Path
}

& $builderPath @buildParameters
