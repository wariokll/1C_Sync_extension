[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,

    [string]$OutputPath,
    [string]$DesignerPath,
    [string]$TemplateDirectory = $PSScriptRoot,
    [switch]$ValidateOnly,
    [switch]$KeepWorkDirectory
)

$ErrorActionPreference = 'Stop'

function Get-FormHandlers {
    param([Parameter(Mandatory = $true)][string]$FormXmlPath)

    $document = New-Object System.Xml.XmlDocument
    $document.Load($FormXmlPath)
    $handlers = New-Object System.Collections.Generic.List[string]

    foreach ($action in $document.GetElementsByTagName('Action')) {
        $name = $action.InnerText.Trim()
        if ($name) {
            $handlers.Add($name)
        }
    }

    foreach ($event in $document.GetElementsByTagName('Event')) {
        $name = $event.InnerText.Trim()
        if ($name) {
            $handlers.Add($name)
        }
    }

    return $handlers | Sort-Object -Unique
}

function Assert-ModuleHandlers {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Handlers
    )

    $missing = foreach ($handler in $Handlers) {
        $pattern = '(?im)^\s*(?:\u041F\u0440\u043E\u0446\u0435\u0434\u0443\u0440\u0430|\u0424\u0443\u043D\u043A\u0446\u0438\u044F)\s+' + [regex]::Escape($handler) + '(?=\s|\()'
        if ($Source -notmatch $pattern) {
            $handler
        }
    }

    if ($missing) {
        throw ('The module does not define form handlers: ' + ($missing -join ', '))
    }
}

$configPath = Join-Path $PSScriptRoot 'epf-template.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Template config not found: $configPath"
}

$config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$templateRoot = (Resolve-Path -LiteralPath $TemplateDirectory).Path
$moduleSourcePath = (Resolve-Path -LiteralPath $ModulePath).Path
$rootMetadataPath = Join-Path $templateRoot $config.rootMetadata
$formMetadataPath = Join-Path $templateRoot $config.formMetadata
$templateModulePath = Join-Path $templateRoot $config.modulePath

foreach ($requiredFile in @($rootMetadataPath, $formMetadataPath, $templateModulePath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required template file not found: $requiredFile"
    }
}

$moduleSource = [System.IO.File]::ReadAllText($moduleSourcePath, [System.Text.Encoding]::UTF8)
$handlers = @(Get-FormHandlers -FormXmlPath $formMetadataPath)
Assert-ModuleHandlers -Source $moduleSource -Handlers $handlers

if ($ValidateOnly) {
    Write-Host "Module is compatible with the form. Checked handlers: $($handlers.Count)."
    return
}

if (-not $OutputPath) {
    throw 'OutputPath is required unless ValidateOnly is specified.'
}

if (-not $DesignerPath) {
    $designerCommand = Get-Command '1cv8.exe' -ErrorAction SilentlyContinue
    if ($designerCommand) {
        $DesignerPath = $designerCommand.Source
    }
    else {
        throw 'Specify DesignerPath, for example the full path to 1cv8.exe.'
    }
}

$designerPathResolved = (Resolve-Path -LiteralPath $DesignerPath).Path
$designerVersion = (Get-Item -LiteralPath $designerPathResolved).VersionInfo.ProductVersion
if ($designerVersion -notmatch [regex]::Escape($config.requiredPlatformVersion)) {
    throw "Expected platform $($config.requiredPlatformVersion), found '$designerVersion'."
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('epf-build-' + [guid]::NewGuid().ToString('N'))
$logPath = $outputFullPath + '.build.log'

try {
    New-Item -ItemType Directory -Path $workDirectory | Out-Null
    Copy-Item -LiteralPath $rootMetadataPath -Destination $workDirectory
    Copy-Item -LiteralPath (Join-Path $templateRoot 'Forms') -Destination $workDirectory -Recurse

    $workModulePath = Join-Path $workDirectory $config.modulePath
    Copy-Item -LiteralPath $moduleSourcePath -Destination $workModulePath -Force

    $designerArguments = @(
        'DESIGNER',
        '/LoadExternalDataProcessorOrReportFromFiles',
        $workDirectory,
        $outputFullPath,
        '/Out',
        $logPath,
        '/DisableStartupMessages'
    )

    & $designerPathResolved @designerArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Designer failed with exit code $LASTEXITCODE. See log: $logPath"
    }
    if (-not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
        throw "Designer exited successfully but did not create: $outputFullPath. See log: $logPath"
    }

    Write-Host "Created: $outputFullPath"
}
finally {
    if (-not $KeepWorkDirectory -and (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}