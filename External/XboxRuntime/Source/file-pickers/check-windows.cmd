@echo off
rem Run in an x64 MSVC developer command prompt with the Windows SDK installed.
rem Builds project source and exercises mocked dialogs; no game or registry writes.
setlocal
cd /d "%~dp0.."
if not exist build\file-pickers-windows mkdir build\file-pickers-windows
cl /nologo /W3 /std:c11 /D_CRT_SECURE_NO_WARNINGS /MD /TC /LD /Fo:build\file-pickers-windows\pickers.obj file-pickers\pickers.c /link /OUT:build\file-pickers-windows\bedrock-pickers.dll /IMPLIB:build\file-pickers-windows\bedrock-pickers.lib /EXPORT:DllGetActivationFactory /EXPORT:DllCanUnloadNow runtimeobject.lib ole32.lib user32.lib comdlg32.lib
if errorlevel 1 exit /b 1
cl /nologo /W3 /std:c11 /D_CRT_SECURE_NO_WARNINGS /MD /TC /Fo:build\file-pickers-windows\contract.obj /Fe:build\file-pickers-windows\file-picker-contract.exe tests\file-picker-contract.c /link runtimeobject.lib ole32.lib user32.lib comdlg32.lib
if errorlevel 1 exit /b 1
set "BEDROCK_PICKER_DLL=%CD%\build\file-pickers-windows\bedrock-pickers.dll"
build\file-pickers-windows\file-picker-contract.exe
exit /b %errorlevel%
