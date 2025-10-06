#!/bin/bash

echo "🚀 Starting Faye Redis NG Example..."
echo ""

# Check if Redis is running
if ! redis-cli ping > /dev/null 2>&1; then
    echo "❌ Redis is not running!"
    echo "Please start Redis first: redis-server"
    exit 1
fi

echo "✅ Redis is running"
echo ""

# Install dependencies if needed
if [ ! -d "examples/.bundle" ]; then
    echo "📦 Installing dependencies..."
    cd examples && bundle install
    cd ..
fi

# Start server
echo "🌐 Starting Faye server on http://localhost:9292"
echo "📖 Open http://localhost:9292 in your browser"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

rackup examples/config.ru -p 9292
