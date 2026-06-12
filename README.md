# 🚀 Codex Profile Manager

A smart, fully automated profile rotation and macro injection utility designed to seamlessly manage multiple Codex IDE API accounts across **macOS** and **Windows**. 

This system acts as a persistent layer above the Codex IDE, ensuring zero downtime by utilizing context-aware LLM prompt injection, low-level OS event hooking, and real-time usage tracking.

<div align="center">
  <img src="Resources/AppIcon.png" alt="Codex Profile Manager Logo" width="200" />
</div>

---

## 📐 System Architecture Overview

The core philosophy of this application is **Fault Tolerance via Prompt Engineering**. Instead of attempting complex process memory injection to hot-swap API keys inside a running Codex instance, the system relies on **Directory Swapping + Application Restart + Context-Aware Auto-Resume**.

1. **Auto-Rotate:** Concurrently polls OpenAI usage limits across all registered `.codex-profiles`.
2. **Directory Swap:** Instantly reroutes the symlink/junction of the `~/.codex` configuration directory to the profile with the most remaining quota.
3. **Hard Restart:** Gracefully terminates and respawns the Codex IDE process.
4. **Context Injection (Auto-Resume):** Uses OS-level hardware event simulation to automatically type:  
   `"계정 스위칭이 완료되었습니다. 끊긴 이전 작업을 그대로 이어서 진행해 줘."`  
   *(Account switching complete. Please seamlessly continue the previous task.)*  
   This forces the LLM to context-switch and recover state without requiring native application support.

---

## 🍏 macOS Implementation (Native Swift)

The macOS client is built natively using **Swift, AppKit, and SwiftUI** for maximum performance and deep OS integration.

### Technical Deep Dive
- **UI Architecture:** Built with `SwiftUI`, featuring an `AnimatedMeshBackground` and `VisualEffectView` for a state-of-the-art Liquid Glassmorphism aesthetic. It runs purely as a Menu Bar application (`NSApplicationActivationPolicyAccessory`) to avoid polluting the Dock.
- **Concurrent Polling:** Implements `DispatchGroup` and `DispatchQueue.global(qos: .userInitiated)` to fire concurrent usage fetching routines utilizing the embedded `codexbar` CLI binary, ensuring sub-second UI updates across dozens of profiles.
- **Security & Macro Injection:** Initially implemented via `NSAppleScript`, the auto-resume feature encountered macOS Sandbox and Accessibility attribution failures (Error 1002). This was resolved by dropping to the CoreGraphics layer. The app now natively synthesizes HID hardware events using `CGEvent`, completely bypassing high-level OS restrictions to inject the clipboard payload directly into the active window.
- **Process Management:** Utilizes `NSRunningApplication.terminate()` to safely flush Codex's internal SQLite state before directory swapping, preventing database corruption.

### Build Instructions (macOS)
```bash
git clone https://github.com/JJH-Hacker/CodexProfileApp.git
cd CodexProfileApp
./build_app.sh
open ../CodexProfileManager.app
```

---

## 🪟 Windows Implementation (Python + PyQt6)

The Windows client is a faithful architectural port located in the `CodexProfileApp-Windows` directory, retaining the exact UI aesthetics and background automation logic of the macOS version using the **PyQt6** framework.

### Technical Deep Dive
- **UI Architecture:** Implements a custom borderless `QWidget` (`Qt.FramelessWindowHint`) that anchors itself relative to the `QSystemTrayIcon`. Using extensive `QSS` (Qt Style Sheets), it perfectly replicates the macOS rounded corners, dark mode gradients, and custom progress bar rendering.
- **Asynchronous Loop:** To prevent the heavy PyQt GUI thread from freezing during network requests, the core logic runs continuously inside an isolated `QThread`. Cross-thread communication is handled via strict `pyqtSignal` event emissions.
- **Usage Fetching:** Bypasses the need for a compiled `codexbar` CLI by directly reading `auth.json` and interfacing with the OpenAI `/v1/dashboard/billing/usage` API endpoints over HTTP via `requests`.
- **System Integration:** 
  - **Directory Swapping:** Utilizes `mklink /J` to handle directory junctions safely across NTFS drives.
  - **Window Focusing & Injection:** Uses the `win32gui` (`SetForegroundWindow`) API to forcefully pull the Codex application to the absolute foreground, followed by `pyautogui` for `Ctrl+V` + `Enter` macro execution.

### Build Instructions (Windows)
```cmd
git clone https://github.com/JJH-Hacker/CodexProfileApp.git
cd CodexProfileApp\CodexProfileApp-Windows
build.bat
```
The compiled, standalone `.exe` will be generated inside the `dist` folder via PyInstaller.

---

## 📝 License

Open Source. Feel free to fork, study the architecture, and modify!
