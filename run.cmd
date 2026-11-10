@echo off
rem Run / build MyTermi on Windows.
rem
rem   run [dev|prod|build] [android|ios] [extra flutter args...]
rem
rem   dev    debug build with hot reload            (default)
rem   prod   release build, run on a device
rem   build  release APK
rem
rem Default platform on Windows: android (iOS needs macOS).
rem Examples:
rem   run
rem   run prod
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

rem --- locate flutter ---
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
