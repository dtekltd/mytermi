@echo off
rem Run / build MyTermi on Windows.
rem
rem   run [dev|prod|build] [android|windows] [extra flutter args...]
rem
rem   dev    debug build with hot reload            (default)
rem   prod   release build, run on a device / this PC
rem   build  release package: android -> APK, windows -> zip
rem
rem Default platform: android (iOS needs macOS).
rem Windows needs Visual Studio 2022 with "Desktop development with C++".
rem Examples:
rem   run
rem   run windows
rem   run build windows
rem   run build android --split-per-abi
rem   run dev android -d emulator-5554
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "MODE=dev"
set "PLATFORM=android"
set "EXTRA="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="dev"     (set "MODE=dev"     & shift & goto parse)
if /i "%~1"=="prod"    (set "MODE=prod"    & shift & goto parse)
if /i "%~1"=="build"   (set "MODE=build"   & shift & goto parse)
if /i "%~1"=="android" (set "PLATFORM=android" & shift & goto parse)
if /i "%~1"=="ios"     (set "PLATFORM=ios" & shift & goto parse)
if /i "%~1"=="windows" (set "PLATFORM=windows" & shift & goto parse)
if /i "%~1"=="help"    goto usage
if /i "%~1"=="-h"      goto usage
if /i "%~1"=="--help"  goto usage
:rest
if "%~1"=="" goto parsed
set "EXTRA=!EXTRA! %1"
shift
goto rest

:usage
for /f "usebackq skip=1 tokens=* delims=" %%L in ("%~f0") do (
  set "line=%%L"
  if /i not "!line:~0,3!"=="rem" goto :eof
  echo(!line:~4!
)
goto :eof

:parsed
if /i "%PLATFORM%"=="ios" (
  echo X iOS chi chay/build duoc tren macOS ^(can Xcode^).
  exit /b 1
)

rem --- locate flutter: project pins its version in .fvmrc, use it via FVM if installed ---
if not exist ".fvmrc" goto nofvm
where fvm >nul 2>nul
if errorlevel 1 goto nofvm
set "FVMVER="
for /f "usebackq tokens=*" %%V in (`powershell -NoProfile -Command "(Get-Content .fvmrc -Raw | ConvertFrom-Json).flutter"`) do set "FVMVER=%%V"
set "FVMSDK=%FVM_CACHE_PATH%"
if not defined FVMSDK set "FVMSDK=%LOCALAPPDATA%\fvm"
set "FVMSDK=%FVMSDK%\versions\%FVMVER%"
if exist ".fvm\flutter_sdk\bin\flutter.bat" set "FVMSDK=%CD%\.fvm\flutter_sdk"
if not exist "%FVMSDK%\bin\flutter.bat" (
  echo ... Cai Flutter %FVMVER% qua FVM ^(lan dau^)
  call fvm install %FVMVER%
)
if not exist "%FVMSDK%\bin\flutter.bat" (
  echo X Khong tim thay Flutter %FVMVER% cua FVM o %FVMSDK%
  exit /b 1
)
set "PATH=%FVMSDK%\bin;%PATH%"
goto found
:nofvm
where flutter >nul 2>nul
if errorlevel 1 (
  for %%D in ("%FLUTTER_ROOT%" "%USERPROFILE%\sdk\flutter" "%USERPROFILE%\flutter" "C:\flutter" "C:\src\flutter") do (
    if exist "%%~D\bin\flutter.bat" (
      set "PATH=%%~D\bin;!PATH!"
      goto found
    )
  )
  echo X Khong tim thay flutter ^(them vao PATH hoac dat FLUTTER_ROOT^).
  exit /b 1
)
:found

set "ENV=prod"
if /i "%MODE%"=="dev" set "ENV=dev"
set "DEFINES=--dart-define=APP_ENV=%ENV%"
if defined MYTERMI_API_URL set "DEFINES=%DEFINES% --dart-define=API_URL=%MYTERMI_API_URL%"
if defined GOOGLE_SERVER_CLIENT_ID set "DEFINES=%DEFINES% --dart-define=GOOGLE_SERVER_CLIENT_ID=%GOOGLE_SERVER_CLIENT_ID%"

if /i "%MODE%"=="build" if /i "%PLATFORM%"=="windows" (
  echo ^> flutter build windows --release %DEFINES%%EXTRA%
  call flutter build windows --release %DEFINES%%EXTRA%
  if errorlevel 1 exit /b 1
  powershell -NoProfile -Command "Compress-Archive -Force -Path build\windows\x64\runner\Release\* -DestinationPath build\windows\MyTermi-windows-x64.zip"
  if errorlevel 1 exit /b 1
  echo OK App: build\windows\x64\runner\Release\mytermi.exe
  echo OK Zip: build\windows\MyTermi-windows-x64.zip  ^(giai nen roi chay mytermi.exe^)
  exit /b 0
)

if /i "%MODE%"=="build" (
  echo ^> flutter build apk --release %DEFINES%%EXTRA%
  call flutter build apk --release %DEFINES%%EXTRA%
  if errorlevel 1 exit /b 1
  echo OK APK: build\app\outputs\flutter-apk\
  exit /b 0
)

rem --- pick an Android device unless -d was given ---
set "HASDEV="
echo.%EXTRA% | findstr /r /c:" -d " /c:"--device-id" >nul && set "HASDEV=1"
if /i "%PLATFORM%"=="windows" if not defined HASDEV (
  set "HASDEV=1"
  set "EXTRA= -d windows%EXTRA%"
)
if not defined HASDEV (
  set "DEVID="
  for /f "usebackq tokens=*" %%I in (`powershell -NoProfile -Command "$d = flutter devices --machine 2>$null | Out-String | ConvertFrom-Json | Where-Object { $_.targetPlatform -like 'android*' } | Sort-Object emulator; if ($d) { @($d)[0].id }"`) do set "DEVID=%%I"
  if not defined DEVID (
    echo X Khong tim thay thiet bi Android nao dang ket noi.
    echo   Cam dien thoai ^(bat USB debugging^) hoac mo emulator: flutter emulators --launch ^<id^>
    exit /b 1
  )
  echo -^> Thiet bi: !DEVID!
  set "EXTRA= -d !DEVID!%EXTRA%"
)

set "FLAGS=--debug"
if /i "%MODE%"=="prod" set "FLAGS=--release"
echo ^> flutter run %FLAGS% %DEFINES%%EXTRA%
call flutter run %FLAGS% %DEFINES%%EXTRA%
exit /b %errorlevel%
