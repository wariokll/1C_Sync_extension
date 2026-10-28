[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [Parameter(Mandatory = $true)]
    [string]$DesignerPath,

    [string]$OutputDirectory = '.\output\import-probes',

    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

function Quote-1CArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Contains('"')) {
        throw 'A command-line argument contains a double quote.'
    }
    return '"' + $Value + '"'
}

function Invoke-ImportProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RootXml,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$DesignerExecutable,
        [Parameter(Mandatory = $true)][int]$Timeout
    )

    $logPath = $Destination + '.log'
    $arguments = @(
        'DESIGNER',
        '/DisableStartupDialogs',
        '/Out' + (Quote-1CArgument $logPath),
        '/LoadExternalDataProcessorOrReportFromFiles',
        (Quote-1CArgument $RootXml),
        (Quote-1CArgument $Destination)
    ) -join ' '

    Write-Host "Starting $Name..."
    $process = Start-Process -FilePath $DesignerExecutable -ArgumentList $arguments -PassThru
    $completed = $process.WaitForExit($Timeout * 1000)
    if (-not $completed) {
        $process.Kill()
        $process.WaitForExit()
    }

    $resultFile = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
    $partialFile = Get-Item -LiteralPath ($Destination + '.build') -ErrorAction SilentlyContinue
    $logText = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($logPath).Trim()
    }
    else {
        '(no Designer log)'
    }

    $result = [pscustomobject]@{
        Stage = $Name
        Completed = $completed
        ExitCode = if ($completed) { $process.ExitCode } else { '(timeout)' }
        EpfBytes = if ($resultFile) { $resultFile.Length } else { 0 }
        PartialBytes = if ($partialFile) { $partialFile.Length } else { 0 }
        Log = $logPath
    }
    $result | Format-List | Out-String | Write-Host
    Write-Host $logText
    return $result
}

$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$designer = (Resolve-Path -LiteralPath $DesignerPath).Path
$configPath = Join-Path $PSScriptRoot 'epf-template.json'
$config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$rootName = [string]$config.rootMetadata
$sourceRoot = Join-Path $source $rootName
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Leaf)) {
    throw "Root metadata was not found: $sourceRoot"
}

$output = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputDirectory))
}
New-Item -ItemType Directory -Path $output -Force | Out-Null
$runDirectory = Join-Path $output ('run-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $runDirectory | Out-Null
Write-Host "Probe files: $runDirectory"

# Phase 1: load processor metadata without a form. Remove form references
# entirely; empty reference elements are invalid metadata and confuse the test.
$metadataDirectory = Join-Path $runDirectory 'metadata-only'
New-Item -ItemType Directory -Path $metadataDirectory | Out-Null
$metadataRoot = Join-Path $metadataDirectory $rootName
$metadataXml = New-Object System.Xml.XmlDocument
$metadataXml.Load($sourceRoot)
$processor = $metadataXml.SelectSingleNode("//*[local-name()='ExternalDataProcessor']")
if (-not $processor) { throw 'ExternalDataProcessor was not found in root metadata.' }
$childObjects = $processor.SelectSingleNode("*[local-name()='ChildObjects']")
foreach ($form in @($childObjects.ChildNodes | Where-Object { $_.LocalName -eq 'Form' })) {
    [void]$childObjects.RemoveChild($form)
}
foreach ($propertyName in @('DefaultForm', 'AuxiliaryForm')) {
    $property = $processor.SelectSingleNode("*[local-name()='Properties']/*[local-name()='$propertyName']")
    if ($property) { [void]$property.ParentNode.RemoveChild($property) }
}
$metadataXml.Save($metadataRoot)
$metadataResult = Invoke-ImportProbe -Name 'metadata-only' -RootXml $metadataRoot `
    -Destination (Join-Path $runDirectory 'metadata-only.epf') `
    -DesignerExecutable $designer -Timeout $TimeoutSeconds

# Find the generated form files from the root metadata.
$sourceDocument = New-Object System.Xml.XmlDocument
$sourceDocument.Load($sourceRoot)
$formName = [string]$sourceDocument.SelectSingleNode("//*[local-name()='ExternalDataProcessor']/*[local-name()='ChildObjects']/*[local-name()='Form']").InnerText
if (-not $formName) { throw 'The source dump does not declare a form.' }
$objectName = [System.IO.Path]::GetFileNameWithoutExtension($rootName)

function New-FormProbeCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$BareForm
    )

    $directory = Join-Path $runDirectory $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $directory -Recurse -Force

    $formXmlPath = Join-Path $directory "$objectName\Forms\$formName\Ext\Form.xml"
    $formXml = New-Object System.Xml.XmlDocument
    $formXml.Load($formXmlPath)
    $formXml.DocumentElement.SelectSingleNode("*[local-name()='ChildItems']").RemoveAll()
    if ($BareForm) {
        $attributes = $formXml.DocumentElement.SelectSingleNode("*[local-name()='Attributes']")
        foreach ($attribute in @($attributes.ChildNodes | Where-Object {
            $_.LocalName -ne 'Attribute' -or -not $_.SelectSingleNode("*[local-name()='MainAttribute']")
        })) {
            [void]$attributes.RemoveChild($attribute)
        }
        $commands = $formXml.DocumentElement.SelectSingleNode("*[local-name()='Commands']")
        if ($commands) { [void]$formXml.DocumentElement.RemoveChild($commands) }
        $events = $formXml.DocumentElement.SelectSingleNode("*[local-name()='Events']")
        if ($events) { [void]$formXml.DocumentElement.RemoveChild($events) }
    }
    $formXml.Save($formXmlPath)

    $modulePath = Join-Path $directory "$objectName\Forms\$formName\Ext\Form\Module.bsl"
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        throw "Generated form module was not found: $modulePath"
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($modulePath, "// import probe: empty form module`r`n", $utf8Bom)
    return Join-Path $directory $rootName
}

# Phase 2: test the form skeleton with only its required main attribute.
$bareFormRoot = New-FormProbeCopy -Name 'form-bare' -BareForm
$bareFormResult = Invoke-ImportProbe -Name 'form-bare' -RootXml $bareFormRoot `
    -Destination (Join-Path $runDirectory 'form-bare.epf') `
    -DesignerExecutable $designer -Timeout $TimeoutSeconds

# Phase 3: keep attributes and commands but remove all visual controls.
$noControlsRoot = New-FormProbeCopy -Name 'form-no-controls'
$noControlsResult = Invoke-ImportProbe -Name 'form-no-controls' -RootXml $noControlsRoot `
    -Destination (Join-Path $runDirectory 'form-no-controls.epf') `
    -DesignerExecutable $designer -Timeout $TimeoutSeconds

# Phase 4: confirm the full visual tree still reproduces the timeout.
$fullControlsDirectory = Join-Path $runDirectory 'controls-full-source'
New-Item -ItemType Directory -Path $fullControlsDirectory | Out-Null
Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $fullControlsDirectory -Recurse -Force
$fullControlsModule = Join-Path $fullControlsDirectory "$objectName\Forms\$formName\Ext\Form\Module.bsl"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($fullControlsModule, "// import probe: empty form module`r`n", $utf8Bom)
$fullControlsResult = Invoke-ImportProbe -Name 'controls-full' -RootXml (Join-Path $fullControlsDirectory $rootName) `
    -Destination (Join-Path $runDirectory 'controls-full.epf') `
    -DesignerExecutable $designer -Timeout $TimeoutSeconds

$controlProbeResults = New-Object System.Collections.Generic.List[object]
$controlProbeResults.Add($fullControlsResult)

if (-not $fullControlsResult.Completed -or $fullControlsResult.ExitCode -ne 0) {
    $sourceFormXmlPath = Join-Path $source "$objectName\Forms\$formName\Ext\Form.xml"
    $sourceFormXml = New-Object System.Xml.XmlDocument
    $sourceFormXml.Load($sourceFormXmlPath)
    $sourceChildItems = $sourceFormXml.DocumentElement.SelectSingleNode("*[local-name()='ChildItems']")

    function Add-ControlsRecursively {
        param(
            [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Items,
            [AllowEmptyCollection()]
            [Parameter(Mandatory = $true)][System.Collections.Generic.List[System.Xml.XmlNode]]$Result
        )

        foreach ($control in @($Items.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })) {
            $Result.Add($control)
            $nestedItems = $control.SelectSingleNode("*[local-name()='ChildItems']")
            if ($nestedItems) { Add-ControlsRecursively -Items $nestedItems -Result $Result }
        }
    }

    $allControls = New-Object System.Collections.Generic.List[System.Xml.XmlNode]
    Add-ControlsRecursively -Items $sourceChildItems -Result $allControls
    if ($allControls.Count -eq 0) { throw 'The source form has no controls to test.' }
    Write-Host "Testing every control individually: $($allControls.Count) elements."

    $controlIndex = 0
    foreach ($targetControl in $allControls) {
        $controlIndex++
        $pathNodes = New-Object System.Collections.Generic.List[System.Xml.XmlNode]
        $cursor = $targetControl
        while ($cursor -and $cursor.LocalName -ne 'Form') {
            if ($cursor.ParentNode -and $cursor.ParentNode.LocalName -eq 'ChildItems') {
                $pathNodes.Add($cursor)
            }
            $cursor = $cursor.ParentNode
        }
        $pathArray = $pathNodes.ToArray()
        [array]::Reverse($pathArray)
        if ($pathArray.Count -eq 0) { throw 'Could not construct the control ancestry path.' }

        $controlLabel = 'element-{0:D3}-{1}-id{2}' -f $controlIndex, $targetControl.LocalName, $targetControl.GetAttribute('id')
        $directory = Join-Path $runDirectory $controlLabel
        New-Item -ItemType Directory -Path $directory | Out-Null
        Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $directory -Recurse -Force

        $formPath = Join-Path $directory "$objectName\Forms\$formName\Ext\Form.xml"
        $document = New-Object System.Xml.XmlDocument
        $document.Load($formPath)
        $currentItems = $document.DocumentElement.SelectSingleNode("*[local-name()='ChildItems']")
        $currentItems.RemoveAll()

        for ($pathIndex = 0; $pathIndex -lt $pathArray.Count; $pathIndex++) {
            $controlClone = $document.ImportNode($pathArray[$pathIndex], $true)
            [void]$currentItems.AppendChild($controlClone)
            if ($pathIndex -lt ($pathArray.Count - 1)) {
                $currentItems = $controlClone.SelectSingleNode("*[local-name()='ChildItems']")
                if (-not $currentItems) {
                    throw "Control '$($pathArray[$pathIndex].GetAttribute('name'))' has no ChildItems for its descendant."
                }
                $currentItems.RemoveAll()
            }
        }
        $document.Save($formPath)

        $modulePath = Join-Path $directory "$objectName\Forms\$formName\Ext\Form\Module.bsl"
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($modulePath, "// import probe: empty form module`r`n", $utf8Bom)

        Write-Host "Testing $controlLabel ($($targetControl.GetAttribute('name')))..."
        $result = Invoke-ImportProbe -Name $controlLabel -RootXml (Join-Path $directory $rootName) `
            -Destination (Join-Path $runDirectory ($controlLabel + '.epf')) `
            -DesignerExecutable $designer -Timeout $TimeoutSeconds
        $controlProbeResults.Add($result)
    }
}
else {
    Write-Host 'The full visual tree completed in this run; no per-control probes were needed.'
}
Write-Host 'Probe summary:'
$allResults = @($metadataResult, $bareFormResult, $noControlsResult) + $controlProbeResults.ToArray()
$allResults |
    Format-Table Stage, Completed, ExitCode, EpfBytes, PartialBytes -AutoSize
