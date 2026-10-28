[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$DesignerPath,
    [string]$OutputDirectory = '.\output\control-isolation',
    [ValidateRange(10, 600)][int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

function Quote-1CArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains('"')) { throw 'A command-line argument contains a double quote.' }
    return '"' + $Value + '"'
}

function Invoke-ImportProbe {
    param([string]$Name, [string]$RootXml, [string]$Destination, [string]$Designer, [int]$Timeout)
    $logPath = $Destination + '.log'
    $arguments = @(
        'DESIGNER', '/DisableStartupDialogs',
        '/Out' + (Quote-1CArgument $logPath),
        '/LoadExternalDataProcessorOrReportFromFiles',
        (Quote-1CArgument $RootXml), (Quote-1CArgument $Destination)
    ) -join ' '
    Write-Host "Starting $Name..."
    $process = Start-Process -FilePath $Designer -ArgumentList $arguments -PassThru
    $completed = $process.WaitForExit($Timeout * 1000)
    if (-not $completed) { $process.Kill(); $process.WaitForExit() }
    $epf = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
    $result = [pscustomobject]@{
        Stage = $Name
        Completed = $completed
        ExitCode = if ($completed) { $process.ExitCode } else { '(timeout)' }
        EpfBytes = if ($epf) { $epf.Length } else { 0 }
        Log = $logPath
    }
    $result | Format-List | Out-String | Write-Host
    if (Test-Path -LiteralPath $logPath -PathType Leaf) { Write-Host ([IO.File]::ReadAllText($logPath).Trim()) }
    return $result
}

$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$designer = (Resolve-Path -LiteralPath $DesignerPath).Path
$configPath = Join-Path $PSScriptRoot 'epf-template.json'
$config = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$rootName = [string]$config.rootMetadata
$objectName = [IO.Path]::GetFileNameWithoutExtension($rootName)
$sourceRoot = Join-Path $source $rootName
$rootDoc = New-Object System.Xml.XmlDocument
$rootDoc.Load($sourceRoot)
$formName = [string]$rootDoc.SelectSingleNode("//*[local-name()='ExternalDataProcessor']/*[local-name()='ChildObjects']/*[local-name()='Form']").InnerText
if (-not $formName) { throw 'The source dump does not declare a form.' }
$sourceFormPath = Join-Path $source "$objectName\Forms\$formName\Ext\Form.xml"
$sourceForm = New-Object System.Xml.XmlDocument
$sourceForm.Load($sourceFormPath)
$sourceItems = $sourceForm.DocumentElement.SelectSingleNode("*[local-name()='ChildItems']")
$groups = @($sourceItems.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and $_.LocalName -eq 'UsualGroup' })
$table = $sourceItems.SelectSingleNode(".//*[local-name()='Table']")
if ($groups.Count -lt 2) { throw "Expected two top-level UsualGroup controls, found $($groups.Count)." }
if (-not $table) { throw 'No Table control was found in the source form.' }

$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) { [IO.Path]::GetFullPath($OutputDirectory) } else { [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputDirectory)) }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$runDirectory = Join-Path $output ('run-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $runDirectory | Out-Null
Write-Host "Probe files: $runDirectory"

$probes = @(
    @{ Name = 'group-01-no-context'; Node = $groups[0] }
    @{ Name = 'group-02-no-context'; Node = $groups[1] }
    @{ Name = 'group-01-own-context-removed'; Node = $groups[0]; StripOwnContextMenu = $true }
    @{ Name = 'group-02-own-context-removed'; Node = $groups[1]; StripOwnContextMenu = $true }
    @{ Name = 'table-root'; Node = $table; StripContextMenus = $false }
    @{ Name = 'table-root-no-context'; Node = $table; StripContextMenus = $true }
)
$results = New-Object System.Collections.Generic.List[object]
foreach ($probe in $probes) {
    $directory = Join-Path $runDirectory $probe.Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $directory -Recurse -Force
    $formPath = Join-Path $directory "$objectName\Forms\$formName\Ext\Form.xml"
    $document = New-Object System.Xml.XmlDocument
    $document.Load($formPath)
    $childItems = $document.DocumentElement.SelectSingleNode("*[local-name()='ChildItems']")
    $childItems.RemoveAll()
    $control = $document.ImportNode($probe.Node, $true)
    if ($probe.StripOwnContextMenu) {
        $ownContextMenu = $control.SelectSingleNode("*[local-name()='ContextMenu']")
        if ($ownContextMenu) { [void]$control.RemoveChild($ownContextMenu) }
    }
    elseif ($probe.Name -like 'group-*' -or $probe.StripContextMenus) {
        foreach ($contextMenu in @($control.SelectNodes(".//*[local-name()='ContextMenu']"))) {
            [void]$contextMenu.ParentNode.RemoveChild($contextMenu)
        }
    }
    [void]$childItems.AppendChild($control)
    $document.Save($formPath)

    $modulePath = Join-Path $directory "$objectName\Forms\$formName\Ext\Form\Module.bsl"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($modulePath, "// import probe: empty form module`r`n", $utf8Bom)
    $result = Invoke-ImportProbe -Name $probe.Name -RootXml (Join-Path $directory $rootName) `
        -Destination (Join-Path $runDirectory ($probe.Name + '.epf')) -Designer $designer -Timeout $TimeoutSeconds
    $results.Add($result)
}
Write-Host 'Focused probe summary:'
$results | Format-Table Stage, Completed, ExitCode, EpfBytes -AutoSize
