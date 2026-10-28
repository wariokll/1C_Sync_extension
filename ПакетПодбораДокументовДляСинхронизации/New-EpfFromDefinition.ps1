[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,

    [Parameter(Mandatory = $true)]
    [string]$DefinitionPath,

    [string]$OutputPath,
    [string]$DesignerPath,
    [string]$InfobaseName,
    [string]$InfobasePath,
    [string]$ServerInfobase,
    [string]$InfobaseUser,
    [string]$InfobasePassword,
    [switch]$NoInfobase,
    [int]$DesignerTimeoutSeconds = 180,
    [string]$TemplateDirectory = $PSScriptRoot,
    [switch]$ValidateOnly,
    [switch]$KeepWorkDirectory
)

$ErrorActionPreference = 'Stop'
$script:LogFormNamespace = 'http://v8.1c.ru/8.3/xcf/logform'
$script:MetadataNamespace = 'http://v8.1c.ru/8.3/MDClasses'
$script:CoreNamespace = 'http://v8.1c.ru/8.1/data/core'

function Add-XmlElement {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Text,
        [string]$Namespace = $script:LogFormNamespace
    )

    $element = $Document.CreateElement($Name, $Namespace)
    if ($PSBoundParameters.ContainsKey('Text')) {
        $element.InnerText = $Text
    }
    [void]$Parent.AppendChild($element)
    return $element
}

function Add-CoreElement {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Text
    )

    return Add-XmlElement -Document $Document -Parent $Parent -Name "v8:$Name" -Text $Text -Namespace $script:CoreNamespace
}

function Add-LocalizedText {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $localized = Add-XmlElement -Document $Document -Parent $Parent -Name $Name
    $item = Add-CoreElement -Document $Document -Parent $localized -Name 'item'
    [void](Add-CoreElement -Document $Document -Parent $item -Name 'lang' -Text 'ru')
    [void](Add-CoreElement -Document $Document -Parent $item -Name 'content' -Text $Text)
    return $localized
}

function Get-TypeName {
    param([Parameter(Mandatory = $true)]$TypeDefinition)

    if ($TypeDefinition -is [string]) {
        return $TypeDefinition
    }
    return [string]$TypeDefinition.kind
}

function ConvertTo-1CCommandLineValue {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Contains('"')) {
        throw 'A 1C command-line value cannot contain a double quote.'
    }
    return '"' + $Value + '"'
}

function Get-PlatformType {
    param([Parameter(Mandatory = $true)]$TypeDefinition)

    $typeName = Get-TypeName -TypeDefinition $TypeDefinition
    switch -Regex ($typeName) {
        '^String$' { return 'xs:string' }
        '^Number$' { return 'xs:decimal' }
        '^Boolean$' { return 'xs:boolean' }
        '^Date$' { return 'xs:dateTime' }
        '^CatalogRef\.(.+)$' { return "cfg:CatalogRef.$($Matches[1])" }
        '^ValueTable$' { return 'v8:ValueTable' }
        default { throw "Unsupported attribute type '$typeName'." }
    }
}

function Add-AttributeType {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)]$AttributeDefinition
    )

    $typeDefinition = $AttributeDefinition.type
    $typeName = Get-TypeName -TypeDefinition $typeDefinition
    $typeElement = Add-XmlElement -Document $Document -Parent $Parent -Name 'Type'
    [void](Add-CoreElement -Document $Document -Parent $typeElement -Name 'Type' -Text (Get-PlatformType -TypeDefinition $typeDefinition))

    switch ($typeName) {
        'String' {
            $qualifiers = Add-CoreElement -Document $Document -Parent $typeElement -Name 'StringQualifiers'
            [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'Length' -Text ([string]$(if ($AttributeDefinition.length) { $AttributeDefinition.length } else { 100 })))
            [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'AllowedLength' -Text 'Variable')
        }
        'Number' {
            $qualifiers = Add-CoreElement -Document $Document -Parent $typeElement -Name 'NumberQualifiers'
            [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'Digits' -Text ([string]$(if ($AttributeDefinition.digits) { $AttributeDefinition.digits } else { 15 })))
            [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'FractionDigits' -Text ([string]$(if ($null -ne $AttributeDefinition.fractionDigits) { $AttributeDefinition.fractionDigits } else { 2 })))
            [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'AllowedSign' -Text 'Any')
        }
        'Date' {
            $qualifiers = Add-CoreElement -Document $Document -Parent $typeElement -Name 'DateQualifiers'
            $fraction = if ($AttributeDefinition.dateFractions) { [string]$AttributeDefinition.dateFractions } else { 'Date' }
            if ($fraction -notin @('Date', 'Time', 'DateTime')) {
                throw "Unsupported dateFractions '$fraction' for attribute '$($AttributeDefinition.name)'."
            }
            [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'DateFractions' -Text $fraction)
        }
    }

    if ($typeName -eq 'ValueTable') {
        $columns = Add-XmlElement -Document $Document -Parent $Parent -Name 'Columns'
        $columnId = 0
        foreach ($column in @($AttributeDefinition.columns)) {
            $columnId++
            $columnNode = Add-XmlElement -Document $Document -Parent $columns -Name 'Column'
            $columnNode.SetAttribute('name', [string]$column.name)
            $columnNode.SetAttribute('id', [string]$columnId)
            [void](Add-LocalizedText -Document $Document -Parent $columnNode -Name 'Title' -Text $(if ($column.title) { [string]$column.title } else { [string]$column.name }))
            $columnType = Add-XmlElement -Document $Document -Parent $columnNode -Name 'Type'
            $typeValue = Get-PlatformType -TypeDefinition $column.type
            [void](Add-CoreElement -Document $Document -Parent $columnType -Name 'Type' -Text $typeValue)
            if ($typeValue -eq 'xs:string') {
                $qualifiers = Add-CoreElement -Document $Document -Parent $columnType -Name 'StringQualifiers'
                [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'Length' -Text '100')
                [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'AllowedLength' -Text 'Variable')
            }
            elseif ($typeValue -eq 'xs:decimal') {
                $qualifiers = Add-CoreElement -Document $Document -Parent $columnType -Name 'NumberQualifiers'
                [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'Digits' -Text '15')
                [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'FractionDigits' -Text '2')
                [void](Add-CoreElement -Document $Document -Parent $qualifiers -Name 'AllowedSign' -Text 'Any')
            }
        }
    }
}

function Add-FormAttribute {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$AttributesNode,
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][int]$Id
    )

    $attribute = Add-XmlElement -Document $Document -Parent $AttributesNode -Name 'Attribute'
    $attribute.SetAttribute('name', [string]$Definition.name)
    $attribute.SetAttribute('id', [string]$Id)
    [void](Add-LocalizedText -Document $Document -Parent $attribute -Name 'Title' -Text $(if ($Definition.title) { [string]$Definition.title } else { [string]$Definition.name }))
    Add-AttributeType -Document $Document -Parent $attribute -AttributeDefinition $Definition
    return $attribute
}

function Add-ControlExtras {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Control,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ref]$NextId
    )

    $context = Add-XmlElement -Document $Document -Parent $Control -Name 'ContextMenu'
    # Keep script literals ASCII-only: Windows PowerShell 5.1 reads UTF-8 files
    # without a BOM using the system code page and otherwise corrupts these names.
    $context.SetAttribute('name', "${Name}ContextMenu")
    $NextId.Value++
    $context.SetAttribute('id', [string]$NextId.Value)
    $tooltip = Add-XmlElement -Document $Document -Parent $Control -Name 'ExtendedTooltip'
    $tooltip.SetAttribute('name', "${Name}ExtendedTooltip")
    $NextId.Value++
    $tooltip.SetAttribute('id', [string]$NextId.Value)
}

function Add-TableControl {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)]$ControlDefinition,
        [Parameter(Mandatory = $true)]$AttributeDefinition,
        [Parameter(Mandatory = $true)][ref]$NextId
    )

    $table = Add-XmlElement -Document $Document -Parent $Parent -Name 'Table'
    $table.SetAttribute('name', [string]$ControlDefinition.name)
    $NextId.Value++
    $table.SetAttribute('id', [string]$NextId.Value)
    [void](Add-XmlElement -Document $Document -Parent $table -Name 'Representation' -Text 'List')
    [void](Add-XmlElement -Document $Document -Parent $table -Name 'DataPath' -Text ([string]$ControlDefinition.dataPath))
    Add-ControlExtras -Document $Document -Control $table -Name ([string]$ControlDefinition.name) -NextId $NextId
    $children = Add-XmlElement -Document $Document -Parent $table -Name 'ChildItems'

    foreach ($column in @($AttributeDefinition.columns)) {
        if ($column.visible -eq $false) { continue }
        $fieldName = "$($ControlDefinition.name)$($column.name)"
        $columnType = Get-TypeName -TypeDefinition $column.type
        $fieldType = if ($columnType -eq 'Boolean') { 'CheckBoxField' } else { 'InputField' }
        $field = Add-XmlElement -Document $Document -Parent $children -Name $fieldType
        $field.SetAttribute('name', $fieldName)
        $NextId.Value++
        $field.SetAttribute('id', [string]$NextId.Value)
        [void](Add-XmlElement -Document $Document -Parent $field -Name 'DataPath' -Text "$($ControlDefinition.dataPath).$($column.name)")
        if ($fieldType -eq 'CheckBoxField') {
            [void](Add-XmlElement -Document $Document -Parent $field -Name 'EditMode' -Text 'EnterOnInput')
            [void](Add-XmlElement -Document $Document -Parent $field -Name 'CheckBoxType' -Text 'Auto')
        }
        Add-ControlExtras -Document $Document -Control $field -Name $fieldName -NextId $NextId
    }
}

function Add-FormControl {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)]$ControlDefinition,
        [Parameter(Mandatory = $true)]$FormDefinition,
        [Parameter(Mandatory = $true)][hashtable]$AttributesByName,
        [Parameter(Mandatory = $true)][ref]$NextId
    )

    switch ([string]$ControlDefinition.kind) {
        'Group' {
            $direction = if ($ControlDefinition.direction) { [string]$ControlDefinition.direction } else { 'Vertical' }
            if ($direction -notin @('Vertical', 'Horizontal')) {
                throw "Group '$($ControlDefinition.name)' has unsupported direction '$direction'. Use Vertical or Horizontal."
            }
            $children = @($ControlDefinition.children)
            if ($children.Count -eq 0) {
                throw "Group '$($ControlDefinition.name)' must contain at least one child control."
            }

            $group = Add-XmlElement -Document $Document -Parent $Parent -Name 'UsualGroup'
            $group.SetAttribute('name', [string]$ControlDefinition.name)
            $NextId.Value++
            $group.SetAttribute('id', [string]$NextId.Value)
            [void](Add-XmlElement -Document $Document -Parent $group -Name 'Group' -Text $direction)
            [void](Add-XmlElement -Document $Document -Parent $group -Name 'Behavior' -Text 'Usual')
            [void](Add-XmlElement -Document $Document -Parent $group -Name 'Representation' -Text 'None')
            $showTitle = if ($ControlDefinition.title) { 'true' } else { 'false' }
            [void](Add-XmlElement -Document $Document -Parent $group -Name 'ShowTitle' -Text $showTitle)
            if ($ControlDefinition.title) {
                [void](Add-LocalizedText -Document $Document -Parent $group -Name 'Title' -Text ([string]$ControlDefinition.title))
            }
            # Designer 8.3.27 hangs while importing generated UsualGroup
            # ContextMenu nodes. Keep the tooltip, which imports successfully.
            $tooltip = Add-XmlElement -Document $Document -Parent $group -Name 'ExtendedTooltip'
            $tooltip.SetAttribute('name', "$($ControlDefinition.name)ExtendedTooltip")
            $NextId.Value++
            $tooltip.SetAttribute('id', [string]$NextId.Value)
            $childItems = Add-XmlElement -Document $Document -Parent $group -Name 'ChildItems'
            foreach ($child in $children) {
                Add-FormControl -Document $Document -Parent $childItems -ControlDefinition $child -FormDefinition $FormDefinition -AttributesByName $AttributesByName -NextId $NextId
            }
        }
        'InputField' {
            if (-not $AttributesByName.ContainsKey([string]$ControlDefinition.dataPath)) {
                throw "InputField '$($ControlDefinition.name)' references unknown attribute '$($ControlDefinition.dataPath)'."
            }
            $control = Add-XmlElement -Document $Document -Parent $Parent -Name 'InputField'
            $control.SetAttribute('name', [string]$ControlDefinition.name)
            $NextId.Value++
            $control.SetAttribute('id', [string]$NextId.Value)
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'DataPath' -Text ([string]$ControlDefinition.dataPath))
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'ExtendedEditMultipleValues' -Text 'true')
            Add-ControlExtras -Document $Document -Control $control -Name ([string]$ControlDefinition.name) -NextId $NextId
        }
        'CheckBoxField' {
            $attributeDefinition = $AttributesByName[[string]$ControlDefinition.dataPath]
            if (-not $attributeDefinition -or (Get-TypeName -TypeDefinition $attributeDefinition.type) -ne 'Boolean') {
                throw "CheckBoxField '$($ControlDefinition.name)' requires a Boolean attribute."
            }
            $control = Add-XmlElement -Document $Document -Parent $Parent -Name 'CheckBoxField'
            $control.SetAttribute('name', [string]$ControlDefinition.name)
            $NextId.Value++
            $control.SetAttribute('id', [string]$NextId.Value)
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'DataPath' -Text ([string]$ControlDefinition.dataPath))
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'EditMode' -Text 'EnterOnInput')
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'CheckBoxType' -Text 'Auto')
            Add-ControlExtras -Document $Document -Control $control -Name ([string]$ControlDefinition.name) -NextId $NextId
        }
        'Table' {
            $attributeDefinition = $AttributesByName[[string]$ControlDefinition.dataPath]
            if (-not $attributeDefinition -or (Get-TypeName -TypeDefinition $attributeDefinition.type) -ne 'ValueTable') {
                throw "Table '$($ControlDefinition.name)' requires a ValueTable attribute."
            }
            Add-TableControl -Document $Document -Parent $Parent -ControlDefinition $ControlDefinition -AttributeDefinition $attributeDefinition -NextId $NextId
        }
        'Button' {
            $commandName = [string]$ControlDefinition.command
            if ($commandName -notin @($FormDefinition.commands | ForEach-Object { [string]$_.name })) {
                throw "Button '$($ControlDefinition.name)' references unknown command '$commandName'."
            }
            $control = Add-XmlElement -Document $Document -Parent $Parent -Name 'Button'
            $control.SetAttribute('name', [string]$ControlDefinition.name)
            $NextId.Value++
            $control.SetAttribute('id', [string]$NextId.Value)
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'Type' -Text 'UsualButton')
            [void](Add-XmlElement -Document $Document -Parent $control -Name 'CommandName' -Text "Form.Command.$commandName")
            # The platform's form dump represents a Button with ExtendedTooltip,
            # but no ContextMenu child. Some Designer builds loop on that extra
            # node during XML import, so keep the generated shape aligned with
            # the native template.
            $tooltip = Add-XmlElement -Document $Document -Parent $control -Name 'ExtendedTooltip'
            $tooltip.SetAttribute('name', "$($ControlDefinition.name)ExtendedTooltip")
            $NextId.Value++
            $tooltip.SetAttribute('id', [string]$NextId.Value)
        }
        default { throw "Unsupported control kind '$($ControlDefinition.kind)'." }
    }
}

function New-GeneratedFormXml {
    param([Parameter(Mandatory = $true)]$FormDefinition)

    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $false
    $root = $document.CreateElement('Form', $script:LogFormNamespace)
    [void]$document.AppendChild($root)
    $root.SetAttribute('xmlns', $script:LogFormNamespace)
    $root.SetAttribute('xmlns:cfg', 'http://v8.1c.ru/8.1/data/enterprise/current-config')
    $root.SetAttribute('xmlns:v8', $script:CoreNamespace)
    $root.SetAttribute('xmlns:xs', 'http://www.w3.org/2001/XMLSchema')
    $root.SetAttribute('xmlns:xsi', 'http://www.w3.org/2001/XMLSchema-instance')
    $root.SetAttribute('version', '2.20')

    [void](Add-XmlElement -Document $document -Parent $root -Name 'Group' -Text 'AlwaysHorizontal')
    $bar = Add-XmlElement -Document $document -Parent $root -Name 'AutoCommandBar'
    $bar.SetAttribute('name', "$($FormDefinition.name)CommandBar")
    $bar.SetAttribute('id', '-1')

    if (@($FormDefinition.events).Count -gt 0) {
        $events = Add-XmlElement -Document $document -Parent $root -Name 'Events'
        foreach ($event in @($FormDefinition.events)) {
            $node = Add-XmlElement -Document $document -Parent $events -Name 'Event' -Text ([string]$event.handler)
            $node.SetAttribute('name', [string]$event.name)
        }
    }

    $childItems = Add-XmlElement -Document $document -Parent $root -Name 'ChildItems'
    $attributesByName = @{}
    foreach ($attribute in @($FormDefinition.attributes)) {
        $attributesByName[[string]$attribute.name] = $attribute
    }

    $nextId = 1
    foreach ($controlDefinition in @($FormDefinition.controls)) {
        Add-FormControl -Document $document -Parent $childItems -ControlDefinition $controlDefinition -FormDefinition $FormDefinition -AttributesByName $attributesByName -NextId ([ref]$nextId)
    }

    $attributesNode = Add-XmlElement -Document $document -Parent $root -Name 'Attributes'
    $objectAttribute = Add-XmlElement -Document $document -Parent $attributesNode -Name 'Attribute'
    $objectAttribute.SetAttribute('name', $script:MainAttributeName)
    $objectAttribute.SetAttribute('id', '1')
    $objectType = Add-XmlElement -Document $document -Parent $objectAttribute -Name 'Type'
    [void](Add-CoreElement -Document $document -Parent $objectType -Name 'Type' -Text "cfg:ExternalDataProcessorObject.$script:ProcessorName")
    [void](Add-XmlElement -Document $document -Parent $objectAttribute -Name 'MainAttribute' -Text 'true')
    $attributeId = 1
    foreach ($attributeDefinition in @($FormDefinition.attributes)) {
        $attributeId++
        [void](Add-FormAttribute -Document $document -AttributesNode $attributesNode -Definition $attributeDefinition -Id $attributeId)
    }

    if (@($FormDefinition.commands).Count -gt 0) {
        $commands = Add-XmlElement -Document $document -Parent $root -Name 'Commands'
        $commandId = 0
        foreach ($command in @($FormDefinition.commands)) {
            $commandId++
            $node = Add-XmlElement -Document $document -Parent $commands -Name 'Command'
            $node.SetAttribute('name', [string]$command.name)
            $node.SetAttribute('id', [string]$commandId)
            $title = if ($command.title) { [string]$command.title } else { [string]$command.name }
            [void](Add-LocalizedText -Document $document -Parent $node -Name 'Title' -Text $title)
            [void](Add-LocalizedText -Document $document -Parent $node -Name 'ToolTip' -Text $title)
            [void](Add-XmlElement -Document $document -Parent $node -Name 'Action' -Text ([string]$command.action))
        }
    }

    return $document
}

function Assert-ModuleHandlers {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Handlers
    )

    $missing = foreach ($handler in $Handlers) {
        $pattern = '(?im)^\s*(?:\u041F\u0440\u043E\u0446\u0435\u0434\u0443\u0440\u0430|\u0424\u0443\u043D\u043A\u0446\u0438\u044F)\s+' + [regex]::Escape($handler) + '(?=\s|\()'
        if ($Source -notmatch $pattern) { $handler }
    }
    if ($missing) {
        throw ('The module does not define form handlers: ' + ($missing -join ', '))
    }
}

function Get-FormHandlers {
    param([Parameter(Mandatory = $true)][string]$FormXmlPath)

    $document = New-Object System.Xml.XmlDocument
    $document.Load($FormXmlPath)
    $handlers = New-Object System.Collections.Generic.List[string]
    foreach ($action in $document.GetElementsByTagName('Action', $script:LogFormNamespace)) {
        if ($action.InnerText.Trim()) { $handlers.Add($action.InnerText.Trim()) }
    }
    foreach ($event in $document.GetElementsByTagName('Event', $script:LogFormNamespace)) {
        if ($event.InnerText.Trim()) { $handlers.Add($event.InnerText.Trim()) }
    }
    return @($handlers | Sort-Object -Unique)
}

function Get-HandlersFromDefinition {
    param([Parameter(Mandatory = $true)]$FormDefinition)

    $handlers = @(
        @($FormDefinition.commands | ForEach-Object { [string]$_.action })
        @($FormDefinition.events | ForEach-Object { [string]$_.handler })
    ) | Where-Object { $_ }
    return @($handlers | Sort-Object -Unique)
}

function Get-ControlCount {
    param([Parameter(Mandatory = $true)][object[]]$Controls)

    $count = 0
    foreach ($control in $Controls) {
        $count++
        if ([string]$control.kind -eq 'Group') {
            $count += Get-ControlCount -Controls @($control.children)
        }
    }
    return $count
}

function New-FormMetadataFile {
    param(
        [Parameter(Mandatory = $true)][string]$TemplateMetadataPath,
        [Parameter(Mandatory = $true)][string]$FormName,
        [Parameter(Mandatory = $true)][string]$Synonym,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $document = New-Object System.Xml.XmlDocument
    $document.Load($TemplateMetadataPath)
    $formNode = $document.GetElementsByTagName('Form', $script:MetadataNamespace)[0]
    $formNode.SetAttribute('uuid', [guid]::NewGuid().ToString())
    foreach ($nameNode in $document.GetElementsByTagName('Name', $script:MetadataNamespace)) {
        $nameNode.InnerText = $FormName
        break
    }
    foreach ($contentNode in $document.GetElementsByTagName('content', $script:CoreNamespace)) {
        $contentNode.InnerText = $Synonym
        break
    }
    $document.Save($Destination)
}

function Add-GeneratedForms {
    param(
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [Parameter(Mandatory = $true)][string]$TemplateRoot,
        [Parameter(Mandatory = $true)]$Definition,
        [Parameter(Mandatory = $true)][string]$DefaultModulePath
    )

    $rootPath = Join-Path $WorkDirectory $script:Config.rootMetadata
    $objectDirectoryName = [System.IO.Path]::GetFileNameWithoutExtension([string]$script:Config.rootMetadata)
    $objectDirectory = Join-Path $WorkDirectory $objectDirectoryName
    $rootDocument = New-Object System.Xml.XmlDocument
    $rootDocument.Load($rootPath)
    $processor = $rootDocument.GetElementsByTagName('ExternalDataProcessor', $script:MetadataNamespace)[0]
    $script:ProcessorName = [string]$processor.Properties.Name
    if (-not $script:ProcessorName) {
        $script:ProcessorName = [string]$processor.SelectSingleNode("*[local-name()='Properties']/*[local-name()='Name']").InnerText
    }
    $childObjects = $processor.SelectSingleNode("*[local-name()='ChildObjects']")
    $existingForms = @($childObjects.ChildNodes | Where-Object { $_.LocalName -eq 'Form' } | ForEach-Object { $_.InnerText })
    $forms = @($Definition.forms)
    if ($forms.Count -eq 0) { throw 'Definition must contain at least one form.' }
    if (@($forms | Where-Object { $_.isDefault }).Count -gt 1) { throw 'Only one generated form can be marked isDefault.' }

    $metadataTemplate = Join-Path $TemplateRoot ($script:Config.formMetadata -replace '/Ext/Form.xml$', '.xml')
    $summary = New-Object System.Collections.Generic.List[string]
    foreach ($form in $forms) {
        $formName = [string]$form.name
        if ($formName -notmatch '^[\p{L}_][\p{L}\p{N}_]*$') { throw "Invalid 1C form name '$formName'." }
        if ($formName -in $existingForms) { throw "Form '$formName' already exists in the template; choose a new form name." }

        $modulePath = if ($form.modulePath) {
            $candidate = [string]$form.modulePath
            if ([System.IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path (Split-Path -Parent $Definition.__path) $candidate }
        }
        else { $DefaultModulePath }
        $modulePath = (Resolve-Path -LiteralPath $modulePath).Path
        $module = [System.IO.File]::ReadAllText($modulePath, [System.Text.Encoding]::UTF8)
        Assert-ModuleHandlers -Source $module -Handlers (Get-HandlersFromDefinition -FormDefinition $form)

        $formDirectory = Join-Path $objectDirectory ("Forms\$formName")
        $formExtDirectory = Join-Path $formDirectory 'Ext'
        $moduleDirectory = Join-Path $formExtDirectory 'Form'
        New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null
        $metadataDestination = Join-Path $objectDirectory ("Forms\$formName.xml")
        New-FormMetadataFile -TemplateMetadataPath $metadataTemplate -FormName $formName -Synonym $(if ($form.synonym) { [string]$form.synonym } else { $formName }) -Destination $metadataDestination
        $formXml = New-GeneratedFormXml -FormDefinition $form
        $formXml.Save((Join-Path $formExtDirectory 'Form.xml'))
        # 1C text modules in a hierarchical dump must have an unambiguous
        # Unicode encoding. In particular, Windows builds may interpret a
        # UTF-8 file without BOM using the current ANSI code page.
        $generatedModulePath = Join-Path $moduleDirectory 'Module.bsl'
        $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($generatedModulePath, $module, $utf8WithBom)

        $formNode = $rootDocument.CreateElement('Form', $script:MetadataNamespace)
        $formNode.InnerText = $formName
        [void]$childObjects.AppendChild($formNode)
        if ($form.isDefault) {
            $defaultForm = $processor.SelectSingleNode("*[local-name()='Properties']/*[local-name()='DefaultForm']")
            $defaultForm.InnerText = "ExternalDataProcessor.$script:ProcessorName.Form.$formName"
        }
        $summary.Add("$formName (attributes: $(@($form.attributes).Count), controls: $(Get-ControlCount -Controls @($form.controls)), commands: $(@($form.commands).Count))")
    }

    if ($Definition.replaceTemplateForms) {
        $generatedFormNames = @($forms | ForEach-Object { [string]$_.name })
        $formNodesToRemove = @($childObjects.ChildNodes | Where-Object {
            $_.LocalName -eq 'Form' -and $_.InnerText -notin $generatedFormNames
        })
        foreach ($formNodeToRemove in $formNodesToRemove) {
            [void]$childObjects.RemoveChild($formNodeToRemove)
        }
    }

    $rootDocument.Save($rootPath)
    return $summary
}

$configPath = Join-Path $PSScriptRoot 'epf-template.json'
$config = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$templateRoot = (Resolve-Path -LiteralPath $TemplateDirectory).Path
$definitionResolvedPath = (Resolve-Path -LiteralPath $DefinitionPath).Path
$defaultModulePath = (Resolve-Path -LiteralPath $ModulePath).Path
$definition = [System.IO.File]::ReadAllText($definitionResolvedPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$definition | Add-Member -NotePropertyName __path -NotePropertyValue $definitionResolvedPath
$script:Config = $config
$rootMetadataPath = Join-Path $templateRoot $config.rootMetadata
$templateFormPath = Join-Path $templateRoot $config.formMetadata
$templateModulePath = Join-Path $templateRoot $config.modulePath
$templateMetadataPath = Join-Path $templateRoot ($config.formMetadata -replace '/Ext/Form.xml$', '.xml')

foreach ($requiredFile in @($rootMetadataPath, $templateFormPath, $templateModulePath, $templateMetadataPath)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required template file not found: $requiredFile" }
}

$templateModule = [System.IO.File]::ReadAllText($defaultModulePath, [System.Text.Encoding]::UTF8)
if (-not $definition.replaceTemplateForms) {
    $templateHandlers = @(Get-FormHandlers -FormXmlPath $templateFormPath)
    Assert-ModuleHandlers -Source $templateModule -Handlers $templateHandlers
}
$templateFormDocument = New-Object System.Xml.XmlDocument
$templateFormDocument.Load($templateFormPath)
$mainAttribute = $templateFormDocument.SelectSingleNode("//*[local-name()='Attribute' and *[local-name()='MainAttribute' and text()='true']]")
if (-not $mainAttribute) { throw 'Template form has no main attribute.' }
$script:MainAttributeName = $mainAttribute.GetAttribute('name')

$workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('epf-build-' + [guid]::NewGuid().ToString('N'))
$outputFullPath = $null
$logPath = $null
$tracePath = $null
$buildSucceeded = $false
try {
    New-Item -ItemType Directory -Path $workDirectory | Out-Null
    Copy-Item -LiteralPath $rootMetadataPath -Destination $workDirectory
    $objectDirectoryName = [System.IO.Path]::GetFileNameWithoutExtension([string]$config.rootMetadata)
    $workObjectDirectory = Join-Path $workDirectory $objectDirectoryName
    New-Item -ItemType Directory -Path $workObjectDirectory | Out-Null
    if ($definition.replaceTemplateForms) {
        New-Item -ItemType Directory -Path (Join-Path $workObjectDirectory 'Forms') | Out-Null
    }
    else {
        Copy-Item -LiteralPath (Join-Path $templateRoot 'Forms') -Destination $workObjectDirectory -Recurse
        $templateWorkModule = Join-Path $workObjectDirectory $config.modulePath
        Copy-Item -LiteralPath $defaultModulePath -Destination $templateWorkModule -Force
    }
    $formsSummary = @(Add-GeneratedForms -WorkDirectory $workDirectory -TemplateRoot $templateRoot -Definition $definition -DefaultModulePath $defaultModulePath)

    $rootDocumentForPaths = New-Object System.Xml.XmlDocument
    $rootDocumentForPaths.Load((Join-Path $workDirectory $config.rootMetadata))
    foreach ($formNode in $rootDocumentForPaths.GetElementsByTagName('Form', $script:MetadataNamespace)) {
        $formName = $formNode.InnerText
        $expectedFormMetadata = Join-Path $workObjectDirectory ("Forms\$formName.xml")
        if (-not (Test-Path -LiteralPath $expectedFormMetadata -PathType Leaf)) {
            throw "Generated hierarchical dump is missing form metadata: $expectedFormMetadata"
        }
    }

    $xmlFiles = Get-ChildItem -LiteralPath $workDirectory -Filter '*.xml' -Recurse
    foreach ($xmlFile in $xmlFiles) {
        $checkDocument = New-Object System.Xml.XmlDocument
        $checkDocument.Load($xmlFile.FullName)
    }

    if ($ValidateOnly) {
        Write-Host 'Generated XML is well-formed. Generated forms:'
        $formsSummary | ForEach-Object { Write-Host "- $_" }
        $buildSucceeded = $true
        return
    }

    if (-not $OutputPath) { throw 'OutputPath is required unless ValidateOnly is specified.' }
    if (-not $DesignerPath) {
        $designerCommand = Get-Command '1cv8.exe' -ErrorAction SilentlyContinue
        if ($designerCommand) { $DesignerPath = $designerCommand.Source }
        else { throw 'Specify DesignerPath, the full path to 1cv8.exe.' }
    }
    $designerPathResolved = (Resolve-Path -LiteralPath $DesignerPath).Path
    $designerVersion = (Get-Item -LiteralPath $designerPathResolved).VersionInfo.ProductVersion
    if ($designerVersion -notmatch [regex]::Escape($config.requiredPlatformVersion)) {
        throw "Expected platform $($config.requiredPlatformVersion), found '$designerVersion'."
    }

    $specifiedInfobases = @($InfobaseName, $InfobasePath, $ServerInfobase) | Where-Object { $_ }
    $connectionModeCount = @($specifiedInfobases).Count + $(if ($NoInfobase) { 1 } else { 0 })
    if ($connectionModeCount -ne 1) {
        throw 'Specify exactly one connection mode: -InfobaseName, -InfobasePath, -ServerInfobase, or -NoInfobase.'
    }

    $connectionArguments = @()
    if (-not $NoInfobase) {
        $connectionArguments += if ($InfobaseName) {
            '/IBName' + (ConvertTo-1CCommandLineValue -Value $InfobaseName)
        }
        elseif ($InfobasePath) {
            '/F' + (ConvertTo-1CCommandLineValue -Value (Resolve-Path -LiteralPath $InfobasePath).Path)
        }
        else {
            '/S' + (ConvertTo-1CCommandLineValue -Value $ServerInfobase)
        }
    }

    $authenticationArguments = @()
    if ($NoInfobase -and ($InfobaseUser -or $InfobasePassword)) {
        throw 'Do not specify InfobaseUser or InfobasePassword together with NoInfobase.'
    }
    if ($InfobaseUser) { $authenticationArguments += '/N' + (ConvertTo-1CCommandLineValue -Value $InfobaseUser) }
    if ($InfobasePassword) { $authenticationArguments += '/P' + (ConvertTo-1CCommandLineValue -Value $InfobasePassword) }

    $outputFullPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
        [System.IO.Path]::GetFullPath($OutputPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath))
    }
    $outputDirectory = Split-Path -Parent $outputFullPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $tracePath = $outputFullPath + '.script.log'
    $connectionDescription = if ($NoInfobase) {
        'none'
    }
    elseif ($InfobaseName) {
        'registered infobase'
    }
    elseif ($InfobasePath) {
        'file infobase'
    }
    else {
        'server infobase'
    }
    $traceHeader = @(
        "Started: $([DateTime]::Now.ToString('s'))"
        "PowerShell: $($PSVersionTable.PSVersion)"
        "Designer: $designerPathResolved"
        "Designer version: $designerVersion"
        "Connection: $connectionDescription"
        "Source: $workDirectory"
        "Root metadata: $(Join-Path $workDirectory $config.rootMetadata)"
        "Output: $outputFullPath"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($tracePath, $traceHeader + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    Write-Host "Generated source: $workDirectory"
    Write-Host "Build trace: $tracePath"
    $logPath = $outputFullPath + '.build.log'
    $temporaryOutputPath = $outputFullPath + '.build'
    if (Test-Path -LiteralPath $temporaryOutputPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryOutputPath -Force
    }
    $workRootMetadataPath = Join-Path $workDirectory $config.rootMetadata
    $designerArguments = @('DESIGNER') + $connectionArguments + $authenticationArguments + @(
        '/DisableStartupDialogs',
        '/Out' + (ConvertTo-1CCommandLineValue -Value $logPath),
        '/LoadExternalDataProcessorOrReportFromFiles',
        (ConvertTo-1CCommandLineValue -Value $workRootMetadataPath),
        (ConvertTo-1CCommandLineValue -Value $outputFullPath))
    $designerArgumentLine = $designerArguments -join ' '
    $designerProcess = Start-Process -FilePath $designerPathResolved -ArgumentList $designerArgumentLine -PassThru
    [System.IO.File]::AppendAllText($tracePath, "Designer process started. PID: $($designerProcess.Id)" + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    Write-Host "Designer process started. PID: $($designerProcess.Id)"
    $designerCompleted = $designerProcess.WaitForExit($DesignerTimeoutSeconds * 1000)
    [System.IO.File]::AppendAllText($tracePath, "Wait completed: $designerCompleted" + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    if (-not $designerCompleted) {
        $designerProcess.Kill()
        $designerProcess.WaitForExit()
        $timeoutLogDetails = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            ([System.IO.File]::ReadAllText($logPath)).Trim()
        }
        else {
            'The Designer log was not created.'
        }
        throw "Designer exceeded the timeout of $DesignerTimeoutSeconds seconds and was stopped. Log: $logPath`r`n$timeoutLogDetails"
    }
    [System.IO.File]::AppendAllText($tracePath, "Designer exit code: $($designerProcess.ExitCode)" + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    if ($designerProcess.ExitCode -ne 0) {
        $logDetails = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            ([System.IO.File]::ReadAllText($logPath)).Trim()
        }
        else {
            'The Designer log was not created.'
        }
        throw "Designer failed with exit code $($designerProcess.ExitCode). Log: $logPath`r`n$logDetails"
    }
    if (-not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) { throw "Designer did not create: $outputFullPath. See log: $logPath" }
    $buildSucceeded = $true
    Write-Host "Created: $outputFullPath"
}
catch {
    if ($tracePath) {
        [System.IO.File]::AppendAllText($tracePath, "ERROR: $($_.Exception.Message)" + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
    throw
}
finally {
    if ($buildSucceeded -and -not $KeepWorkDirectory -and (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
    elseif (-not $buildSucceeded -and (Test-Path -LiteralPath $workDirectory)) {
        Write-Warning "Build source was preserved for diagnostics: $workDirectory"
        if ($tracePath) {
            [System.IO.File]::AppendAllText($tracePath, "Preserved source: $workDirectory" + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
        }
    }
}
