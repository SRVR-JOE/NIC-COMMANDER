#!/bin/bash
# NIC Commander Startup Script

echo "🖧 Starting NIC Commander..."
echo "================================"

# Check if Python 3 is installed
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: Python 3 is not installed"
    exit 1
fi

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv venv
fi

# Activate virtual environment
echo "🔧 Activating virtual environment..."
source venv/bin/activate

# Install dependencies
echo "📥 Installing dependencies..."
pip install -q -r requirements.txt

# Start the application
echo "🚀 Launching NIC Commander Dashboard..."
echo "================================"
echo "Access the dashboard at: http://localhost:5000"
echo "Press Ctrl+C to stop the server"
echo ""

python3 app.py
