# Запуск проекта через Xcode

## Требования

1. Установить полный Xcode из Mac App Store. Одних Command Line Tools недостаточно.
2. Один раз открыть Xcode и принять лицензию/установку дополнительных компонентов.
3. Проверить активный developer directory:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Если приложение установлено под другим именем, например `Xcode-26.app`, в первой команде нужен его настоящий путь.

## Сборка и запуск

1. Открыть `WinLauncher.xcodeproj`.
2. В верхней панели выбрать схему **WinLauncher** и **My Mac**.
3. Нажать **Run** (`⌘R`). Для локального запуска платный Apple Developer Program не нужен.
4. В приложении нажать **Open Windows App** или перетащить `.exe`/`.msi`.
5. При первом открытии `.exe` WinLauncher сам скачает и проверит Wine 11 (около 460 МБ), установит его в Application Support и создаст общий Windows Environment. Выбирать движок не нужно. Ручной выбор доступен только в Advanced Mode.

Приложение использует один общий каталог:

```text
~/Library/Application Support/WinLauncher/Environments/default/prefix
```

Логи находятся в:

```text
~/Library/Application Support/WinLauncher/Logs
```

## Avast

Приложение не выключает Avast, не восстанавливает карантин и не создаёт исключения. DMG WinLauncher не содержит Windows DLL. Wine загружается отдельно с опубликованным SHA-256 и проверяется до установки.

Wine использует PE DLL для совместимости с Windows и WoW64. Некоторые версии Avast ошибочно распознают такие открытые Wine DLL как `Win32:SuspBehav-B [Heur]`. Это эвристическое обнаружение самого формата Wine; его нельзя честно устранить заменой распаковщика или переименованием файлов. Если Avast удалит файл, WinLauncher остановит установку и не примет повреждённый движок.
