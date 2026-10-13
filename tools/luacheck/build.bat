@echo off
setlocal
set HERE=%~dp0
set LUA=%HERE%..\..\_deps\REFramework\dependencies\lua\src
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
if not exist "%HERE%obj" mkdir "%HERE%obj"
pushd "%HERE%obj"
cl /nologo /O1 /MT /W0 /TC /I"%LUA%" "%LUA%\*.c" "%HERE%luacheck.c" /Fe"%HERE%luacheck.exe" >nul || (popd & exit /b 1)
popd
echo built luacheck.exe
