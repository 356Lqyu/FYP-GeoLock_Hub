@echo off
rem Starts the hub-ranking API and links every connected Android phone/emulator to it,
rem so the app finds it at http://127.0.0.1:8000 with no extra settings.
cd /d "%~dp0"

set ADB=adb
where adb >nul 2>nul || set ADB="%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"

echo Linking connected devices to port 8000...
for /f "skip=1 tokens=1,2" %%a in ('%ADB% devices 2^>nul') do (
  if "%%b"=="device" (
    %ADB% -s %%a reverse tcp:8000 tcp:8000 >nul && echo   %%a linked
  )
)

if exist "..\..\.venv\Scripts\activate.bat" call "..\..\.venv\Scripts\activate.bat"
if not exist ".env" copy ".env.example" ".env" >nul

echo Starting API on http://localhost:8000  (Ctrl+C to stop)
uvicorn main:app --host 0.0.0.0 --port 8000
