@echo off
rem Runs/builds the Flutter app. See app\run.cmd for usage.
call "%~dp0app\run.cmd" %*
exit /b %errorlevel%
