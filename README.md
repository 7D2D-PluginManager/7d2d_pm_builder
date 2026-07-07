## Авто-сборщик PluginManager под Linux
Скрипт стандартизирует процесс вокруг трёх путей:

- `build/_staging/refs` - временная папка для общих DLL, нужных во время компиляции.
- `build/Mods/1_PluginManager` - финальная папка мода.
- `build/Mods/1_PluginManager/Plugins/<PluginName>` - финальная папка конкретного плагина.

Локальные копии игровых DLL в `libs` каждого проекта больше не нужны. Скрипт берёт ссылки напрямую из установленного сервера:

- `<server-root>/7DaysToDieServer_Data/Managed`
- `<server-root>/Mods/0_TFP_Harmony`

Для Linux-сборки через `dotnet msbuild` скрипт автоматически использует `/usr/lib/mono/4.8-api`, если эта папка существует. Это даёт reference assemblies для `.NET Framework 4.8`.

## Как Компилировать Плагин
1. Запусти ./build.sh
2. Выбери плагин или несколько

После этого `build.sh` соберёт DLL, скопирует статику и добавит имя плагина в `Config/plugins.txt`.