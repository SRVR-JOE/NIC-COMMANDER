@echo off
REM NIC Commander Startup Script for Windows

echo Starting NIC Commander...
echo ================================

REM Check if Python is installed
python --version >nul 2>&1
if errorlevel 1 (
    echo Error: Python is not installed
    pause
    exit /b 1
)

REM Check if virtual environment exists
if not exist "venv\" (
    echo Creating virtual environment...
    python -m venv venv
)

REM Activate virtual environment
echo Activating virtual environment...
call venv\Scripts\activate.bat

REM Install dependencies
echo Installing dependencies...
pip install -q -r requirements.txt

REM Start the application
echo Launching NIC Commander Dashboard...
echo ================================
echo Access the dashboard at: http://localhost:5000
echo Press Ctrl+C to stop the server
echo.

python app.py
