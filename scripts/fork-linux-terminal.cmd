@echo off
setlocal EnableExtensions
set "WINDIR=%CD%"
if /I "%WINDIR:~0,2%"=="Z:" (
  set "UNIXDIR=%WINDIR:~2%"
) else if /I "%WINDIR:~0,2%"=="z:" (
  set "UNIXDIR=%WINDIR:~2%"
) else (
  set "UNIXDIR=/tmp"
)
set "UNIXDIR=%UNIXDIR:\=/%"
if "%UNIXDIR%"=="" set "UNIXDIR=/"
C:\windows\system32\start.exe /unix /opt/fork/open-linux-terminal.sh "%UNIXDIR%"
