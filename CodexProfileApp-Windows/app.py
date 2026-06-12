import sys
import os
import json
import time
import datetime
import threading
import subprocess
import requests
import pyautogui
import pyperclip

from PyQt6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, 
    QProgressBar, QPushButton, QSystemTrayIcon, QMenu, QScrollArea, QFrame, QSizePolicy
)
from PyQt6.QtCore import Qt, QThread, pyqtSignal, QTimer, QRect
from PyQt6.QtGui import QIcon, QPixmap, QColor, QPainter, QCursor

# --- Configuration ---
PROFILES_DIR = os.path.expanduser(r"~\.codex-profiles")
ACTIVE_DIR = os.path.expanduser(r"~\.codex")
POLL_INTERVAL = 10 # seconds
USAGE_LIMIT = 5.0  

auto_rotate_enabled = True
auto_resume_enabled = True

# --- Core Logic Functions ---
def get_profiles():
    if not os.path.exists(PROFILES_DIR):
        os.makedirs(PROFILES_DIR, exist_ok=True)
    profiles = []
    for d in os.listdir(PROFILES_DIR):
        p = os.path.join(PROFILES_DIR, d)
        if os.path.isdir(p) and os.path.exists(os.path.join(p, "auth.json")):
            profiles.append(d)
    return profiles

def get_active_profile():
    if os.path.exists(ACTIVE_DIR):
        try:
            return os.path.basename(os.readlink(ACTIVE_DIR))
        except OSError:
            pass
    return "Unknown"

def fetch_usage(profile_name):
    auth_file = os.path.join(PROFILES_DIR, profile_name, "auth.json")
    try:
        with open(auth_file, "r") as f:
            auth_data = json.load(f)
            api_key = auth_data.get("openai", {}).get("api_key")
            if not api_key: return 0.0
            
            today = datetime.date.today()
            start_date = today.replace(day=1).strftime("%Y-%m-%d")
            end_date = (today + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
            url = f"https://api.openai.com/v1/dashboard/billing/usage?start_date={start_date}&end_date={end_date}"
            
            r = requests.get(url, headers={"Authorization": f"Bearer {api_key}"}, timeout=5)
            if r.status_code == 200:
                return r.json().get("total_usage", 0) / 100.0
    except Exception:
        pass
    return 0.0

def send_keep_going():
    time.sleep(4.0)
    text = "계정 스위칭이 완료되었습니다. 끊긴 이전 작업을 그대로 이어서 진행해 줘."
    pyperclip.copy(text)
    try:
        import win32gui
        import win32con
        hwnd = win32gui.FindWindow(None, "Codex")
        if hwnd:
            win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
            win32gui.SetForegroundWindow(hwnd)
            time.sleep(0.5)
    except ImportError:
        pass
    pyautogui.hotkey('ctrl', 'v')
    time.sleep(0.5)
    pyautogui.press('enter')

def restart_codex():
    os.system("taskkill /IM codex.exe /F")
    time.sleep(1)
    codex_path = r"C:\Program Files\Codex\codex.exe"
    if os.path.exists(codex_path):
        subprocess.Popen([codex_path])
    if auto_resume_enabled:
        threading.Thread(target=send_keep_going, daemon=True).start()

# --- Worker Thread ---
class MonitorThread(QThread):
    usage_updated = pyqtSignal(dict, str) # usages, active_profile
    notify_signal = pyqtSignal(str, str)

    def run(self):
        while True:
            if auto_rotate_enabled:
                profiles = get_profiles()
                if profiles:
                    active = get_active_profile()
                    usages = {p: fetch_usage(p) for p in profiles}
                    self.usage_updated.emit(usages, active)
                    
                    if active in usages and usages[active] >= USAGE_LIMIT:
                        best_profile = min(usages, key=usages.get)
                        if usages[best_profile] < USAGE_LIMIT:
                            target_path = os.path.join(PROFILES_DIR, best_profile)
                            os.system(f'rmdir "{ACTIVE_DIR}"')
                            os.system(f'mklink /J "{ACTIVE_DIR}" "{target_path}"')
                            restart_codex()
                        else:
                            self.notify_signal.emit("All accounts exhausted!", "Please add new API keys.")
            time.sleep(POLL_INTERVAL)

# --- UI Components ---
class ToggleSwitch(QPushButton):
    def __init__(self, parent=None, checked=True):
        super().__init__(parent)
        self.setCheckable(True)
        self.setChecked(checked)
        self.setFixedSize(40, 20)
        self.setStyleSheet("""
            QPushButton {
                border-radius: 10px;
                background-color: #555555;
            }
            QPushButton:checked {
                background-color: #0A84FF;
            }
        """)

class MacStylePopup(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setFixedSize(320, 400)
        
        # Main background frame
        self.bg = QFrame(self)
        self.bg.setGeometry(0, 0, 320, 400)
        self.bg.setStyleSheet("""
            QFrame {
                background: qlineargradient(x1:0, y1:0, x2:1, y2:1, stop:0 #2C2C2E, stop:1 #1C1C1E);
                border-radius: 16px;
                border: 1px solid #3A3A3C;
            }
        """)
        
        self.layout = QVBoxLayout(self.bg)
        self.layout.setContentsMargins(16, 16, 16, 16)
        self.layout.setSpacing(12)
        
        # Header
        header = QLabel("Codex Profiles")
        header.setStyleSheet("color: white; font-size: 18px; font-weight: bold; background: transparent; border: none;")
        self.layout.addWidget(header)
        
        # Scroll Area for profiles
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet("background: transparent; border: none;")
        
        self.scroll_content = QWidget()
        self.scroll_content.setStyleSheet("background: transparent;")
        self.scroll_layout = QVBoxLayout(self.scroll_content)
        self.scroll_layout.setContentsMargins(0, 0, 0, 0)
        self.scroll_layout.setSpacing(8)
        self.scroll_layout.setAlignment(Qt.AlignmentFlag.AlignTop)
        
        self.scroll.setWidget(self.scroll_content)
        self.layout.addWidget(self.scroll)
        
        # Controls
        controls_layout = QVBoxLayout()
        controls_layout.setSpacing(8)
        
        # Auto Rotate Toggle
        h1 = QHBoxLayout()
        l1 = QLabel("Auto-Rotate")
        l1.setStyleSheet("color: white; background: none; border: none; font-size: 14px;")
        self.rotate_toggle = ToggleSwitch(checked=auto_rotate_enabled)
        self.rotate_toggle.clicked.connect(self.toggle_rotate)
        h1.addWidget(l1)
        h1.addStretch()
        h1.addWidget(self.rotate_toggle)
        controls_layout.addLayout(h1)
        
        # Auto Resume Toggle
        h2 = QHBoxLayout()
        l2 = QLabel("Auto-Resume")
        l2.setStyleSheet("color: white; background: none; border: none; font-size: 14px;")
        self.resume_toggle = ToggleSwitch(checked=auto_resume_enabled)
        self.resume_toggle.clicked.connect(self.toggle_resume)
        h2.addWidget(l2)
        h2.addStretch()
        h2.addWidget(self.resume_toggle)
        controls_layout.addLayout(h2)
        
        self.layout.addLayout(controls_layout)
        
        # Buttons
        btn_layout = QHBoxLayout()
        btn_restart = QPushButton("Restart Codex")
        btn_restart.setStyleSheet("background-color: #3A3A3C; color: white; border-radius: 6px; padding: 6px; font-size: 12px;")
        btn_restart.clicked.connect(lambda: threading.Thread(target=restart_codex, daemon=True).start())
        
        btn_quit = QPushButton("Quit")
        btn_quit.setStyleSheet("background-color: #FF453A; color: white; border-radius: 6px; padding: 6px; font-size: 12px;")
        btn_quit.clicked.connect(QApplication.quit)
        
        btn_layout.addWidget(btn_restart)
        btn_layout.addWidget(btn_quit)
        self.layout.addLayout(btn_layout)
        
        self.profiles_data = {}

    def toggle_rotate(self):
        global auto_rotate_enabled
        auto_rotate_enabled = self.rotate_toggle.isChecked()

    def toggle_resume(self):
        global auto_resume_enabled
        auto_resume_enabled = self.resume_toggle.isChecked()

    def update_data(self, usages, active_profile):
        # Clear layout
        while self.scroll_layout.count():
            item = self.scroll_layout.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()
                
        for profile, usage in usages.items():
            card = QFrame()
            is_active = (profile == active_profile)
            
            bg_color = "#2C2C2E"
            if is_active: bg_color = "#1C1C1E"
            if usage >= USAGE_LIMIT: bg_color = "#3A1C1C"
            
            card.setStyleSheet(f"""
                QFrame {{
                    background-color: {bg_color};
                    border-radius: 8px;
                    border: {'1px solid #0A84FF' if is_active else 'none'};
                }}
            """)
            card_layout = QVBoxLayout(card)
            card_layout.setContentsMargins(12, 12, 12, 12)
            
            # Name and Price
            top_layout = QHBoxLayout()
            name_lbl = QLabel(profile + (" (Active)" if is_active else ""))
            name_lbl.setStyleSheet("color: white; font-weight: bold; background: none; border: none;")
            price_lbl = QLabel(f"${usage:.2f} / ${USAGE_LIMIT:.2f}")
            price_lbl.setStyleSheet("color: #8E8E93; background: none; border: none;")
            top_layout.addWidget(name_lbl)
            top_layout.addStretch()
            top_layout.addWidget(price_lbl)
            card_layout.addLayout(top_layout)
            
            # Progress Bar
            progress = QProgressBar()
            progress.setFixedHeight(4)
            progress.setTextVisible(False)
            percent = int((usage / USAGE_LIMIT) * 100)
            if percent > 100: percent = 100
            progress.setValue(percent)
            
            color = "#34C759" # Green
            if percent > 80: color = "#FF9F0A" # Orange
            if percent >= 100: color = "#FF453A" # Red
            
            progress.setStyleSheet(f"""
                QProgressBar {{
                    background-color: #3A3A3C;
                    border-radius: 2px;
                    border: none;
                }}
                QProgressBar::chunk {{
                    background-color: {color};
                    border-radius: 2px;
                }}
            """)
            card_layout.addWidget(progress)
            self.scroll_layout.addWidget(card)

# --- Tray App ---
class TrayApp:
    def __init__(self):
        self.app = QApplication(sys.sys.argv)
        self.app.setQuitOnLastWindowClosed(False)
        
        self.popup = MacStylePopup()
        
        # Create blank green icon for Tray
        pixmap = QPixmap(64, 64)
        pixmap.fill(QColor(0, 128, 0))
        painter = QPainter(pixmap)
        painter.setBrush(QColor(255, 255, 255))
        painter.drawRect(16, 16, 32, 32)
        painter.end()
        
        self.tray_icon = QSystemTrayIcon(QIcon(pixmap), self.app)
        self.tray_icon.setToolTip("Codex Profile Manager")
        self.tray_icon.activated.connect(self.tray_clicked)
        self.tray_icon.show()
        
        self.thread = MonitorThread()
        self.thread.usage_updated.connect(self.popup.update_data)
        self.thread.notify_signal.connect(self.show_notification)
        self.thread.start()
        
    def tray_clicked(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            if self.popup.isVisible():
                self.popup.hide()
            else:
                # Position popup above tray
                geom = self.tray_icon.geometry()
                screen = QApplication.primaryScreen().availableGeometry()
                # Default to bottom right if geometry is invalid (often is on Windows)
                x = screen.width() - self.popup.width() - 10
                y = screen.height() - self.popup.height() - 40
                
                if geom.x() > 0 and geom.y() > 0:
                    x = geom.x() - self.popup.width() // 2
                    y = geom.y() - self.popup.height() - 10
                
                # Keep on screen
                if x < 0: x = 0
                if y < 0: y = 0
                if x + self.popup.width() > screen.width(): x = screen.width() - self.popup.width()
                
                self.popup.move(x, y)
                self.popup.show()
                self.popup.activateWindow()

    def show_notification(self, title, message):
        try:
            from win10toast import ToastNotifier
            toaster = ToastNotifier()
            toaster.show_toast(title, message, duration=5, threaded=True)
        except:
            pass

    def run(self):
        sys.exit(self.app.exec())

if __name__ == "__main__":
    TrayApp().run()
