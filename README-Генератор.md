# Генератор внешних обработок

`New-EpfFromDefinition.ps1` принимает BSL-модули и JSON-описание интерфейса. Он создаёт дополнительные управляемые формы, их реквизиты и типы, контролы, команды и события; записывает XML-метаданные в копию выгрузки «Экспорт цен» и запускает Конфигуратор для сборки `.epf`. Исходные файлы шаблона не меняются.

В качестве рабочего примера использованы [epf-form-definition.example.json](epf-form-definition.example.json) и [epf-form-module.example.bsl](epf-form-module.example.bsl). Манифест задаёт `forms[]`; у каждой формы есть имя, необязательный синоним, BSL-модуль, `attributes[]`, `controls[]`, `commands[]` и `events[]`. `isDefault: true` назначает созданную форму основной.

Поддерживаемые типы реквизитов: `String`, `Number`, `Boolean`, `Date`, `CatalogRef.ИмяСправочника`, `ValueTable` с колонками. Типы контролов: `InputField`, `CheckBoxField`, `Table`, `Button` и `Group`. Группа задаёт вложенную раскладку: `direction` принимает `Vertical` или `Horizontal`, `title` необязателен, дочерние элементы перечисляются в `children`. Группы можно вкладывать друг в друга. Это позволяет отделить параметры, действия и результат, а также располагать связанные поля или кнопки рядом. Обработчики событий и команд должны быть процедурами/функциями в BSL-модуле соответствующей формы. BSL здесь компилируется при сборке, а не исполняется как динамический текст.

Проверка генерации XML без запуска Конфигуратора:

```powershell
$module = (Get-ChildItem .\Forms -Recurse -Filter Module.bsl | Select-Object -First 1).FullName
.\New-EpfFromDefinition.ps1 `
  -ModulePath $module `
  -DefinitionPath .\epf-form-definition.example.json `
  -ValidateOnly
```

Сборка:

```powershell
$module = (Get-ChildItem .\Forms -Recurse -Filter Module.bsl | Select-Object -First 1).FullName
.\New-EpfFromDefinition.ps1 `
  -ModulePath $module `
  -DefinitionPath .\epf-form-definition.example.json `
  -DesignerPath 'C:\Program Files\1cv8\8.3.27.2214\bin\1cv8.exe' `
  -OutputPath .\output\СформированнаяОбработка.epf
```

Требуется Конфигуратор версии `8.3.27.2214`. Рядом с результатом сохраняется журнал `.build.log`. Параметр `-KeepWorkDirectory` оставляет временную выгрузку для диагностики.

`Build-Epf.ps1` оставлен как облегчённый вариант: он только заменяет BSL-модуль в существующей форме и не создаёт новые формы или контролы.