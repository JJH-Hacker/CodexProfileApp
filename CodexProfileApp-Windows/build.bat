@echo off
echo Installing requirements...
pip install -r requirements.txt
pip install pyinstaller

echo Building executable...
pyinstaller --noconsole --onefile --name CodexProfileManager app.py

echo Build complete! You can find your app in the "dist" folder.
pause
