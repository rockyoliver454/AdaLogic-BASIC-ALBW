@echo off
rem ALBW entry point - zero-setup wrapper.
rem   albw.cmd [albw options] <input.alb> [output.ts]
rem Sets ALB_LIB (stdlib + mathkit + bundled braille engines) and puts
rem the bundled node/tsc on PATH so `--tsc` and `tsc` work out of the box.
set "ALB_HOME=%~dp0"
set "ALB_LIB=%ALB_HOME%stdlib;%ALB_HOME%malbr-testing\lib;%ALB_HOME%braille"
set "PATH=%ALB_HOME%bin;%ALB_HOME%deps\node;%PATH%"
"%ALB_HOME%bin\albw.exe" %*
