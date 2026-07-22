@echo off
setlocal

if defined PLAYMESH_HVIGOR_HOME (
  set "HVIGOR_HOME=%PLAYMESH_HVIGOR_HOME%"
) else (
  set "HVIGOR_HOME=D:\KaiFaTool\runtime\oh-command-line-tools\hvigor"
)

set "HVIGOR_JS=%HVIGOR_HOME%\node_modules\@ohos\hvigor\bin\hvigor.js"
if not exist "%HVIGOR_JS%" (
  echo Hvigor was not found at "%HVIGOR_JS%". 1>&2
  echo Set PLAYMESH_HVIGOR_HOME to the official Hvigor installation directory. 1>&2
  exit /b 1
)

if defined NODE_PATH (
  set "NODE_PATH=%HVIGOR_HOME%\node_modules;%NODE_PATH%"
) else (
  set "NODE_PATH=%HVIGOR_HOME%\node_modules"
)

if defined NODE_HOME if exist "%NODE_HOME%\node.exe" (
  "%NODE_HOME%\node.exe" "%HVIGOR_JS%" %*
) else (
  node "%HVIGOR_JS%" %*
)
exit /b %ERRORLEVEL%
