@echo off
rem Builds re9coop_net.dll with MSVC. Needs the REFramework source checkout in ..\..\_deps\REFramework
rem (for include\reframework\API.h and the exact Lua 5.4.3 it embeds).
setlocal
set HERE=%~dp0
set REF=%HERE%..\..\_deps\REFramework
set LUA=%REF%\dependencies\lua\src
set OUT=%HERE%build

if not exist "%REF%\include\reframework\API.h" (
  echo REFramework source not found at %REF%
  exit /b 1
)

set VCVARS=
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if exist "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" set VCVARS=%VSDIR%\VC\Auxiliary\Build\vcvars64.bat
if "%VCVARS%"=="" (
  echo vcvars64.bat not found
  exit /b 1
)
call "%VCVARS%" >nul || exit /b 1

if not exist "%OUT%\obj" mkdir "%OUT%\obj"
pushd "%OUT%\obj"

rem Lua is compiled as C, exactly like REFramework's own copy (errors use longjmp on both sides).
cl /nologo /c /O2 /MT /W0 /TC "%LUA%\*.c" || goto :fail

cl /nologo /c /O2 /MT /W4 /EHsc /std:c++20 /DWIN32_LEAN_AND_MEAN /DNOMINMAX ^
   /I"%LUA%" /I"%REF%\include" ^
   "%HERE%src\plugin.cpp" "%HERE%src\net.cpp" || goto :fail

link /nologo /DLL /OUT:"%OUT%\re9coop_net.dll" *.obj user32.lib kernel32.lib ws2_32.lib cabinet.lib || goto :fail
popd
echo built %OUT%\re9coop_net.dll
exit /b 0

:fail
popd
echo BUILD FAILED
exit /b 1
