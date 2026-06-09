# 🚀 Codex Profile Manager

A smart, elegant, and fully automated macOS menu-bar & window utility designed to seamlessly manage multiple Codex IDE API accounts. Never worry about hitting your API usage limits again!

<div align="center">
  <img src="Resources/AppIcon.png" alt="Codex Profile Manager Logo" width="200" />
</div>

## ✨ Key Features

- **🧠 Smart Auto-Rotation:** Continuously monitors the token usage of your active profile. When your usage hits 100%, the app instantly finds the profile with the most remaining usage and seamlessly switches to it.
- **⚡ Concurrent Usage Fetching:** Under the hood, it runs `codexbar` concurrently across all your registered profiles to fetch real-time usage data in less than a second, displaying live percentages right on the UI.
- **🛡️ Seamless Transitions (No Popups):** Say goodbye to annoying AppleEvent permission prompts and crash screens! This app uses native macOS `NSRunningApplication.terminate()` to gracefully close Codex and swap out tokens flawlessly.
- **➕ Quick Add API Keys:** Just paste a new `sk-...` API key into the app. It automatically creates a new isolated profile directory, logs in, and switches to it in one click.
- **🎨 Stunning Liquid Glass UI:** Built with SwiftUI, featuring an animated mesh gradient background, glassmorphism effects, and color-coded usage badges (Green/Orange/Red) for quick scanning.
- **🎛️ Complete Profile Management:** 
  - **Rename:** Right-click a profile to give it a memorable name (e.g., "Work Account", "Personal").
  - **Delete:** Right-click to safely completely delete dead or banned tokens.
  - **Clear Logs:** 1-click trash button to flush the system activity log.
- **🔔 Desktop Notifications:** If all your accounts unfortunately hit their 100% usage limits, it plays a sound and sends a macOS notification to let you know it's time to add a new key!

## ⚙️ How It Works

The app maintains isolated `.codex-profiles` directories. When you switch a profile, it seamlessly swaps the `auth.json` inside the main `~/.codex` directory and triggers a clean restart of the Codex IDE.

It embeds the lightning-fast [CodexBar](https://codexbar.app) open-source CLI internally to securely read token usages without any network timeouts or complex setups.

## 🛠️ Installation & Build

This project is built natively using Swift and `xcodebuild`. 

1. Clone the repository:
   ```bash
   git clone https://github.com/JJH-Hacker/CodexProfileApp.git
   cd CodexProfileApp
   ```
2. Build the app using the provided script:
   ```bash
   ./build_app.sh
   ```
3. Run the compiled app!
   ```bash
   open ../CodexProfileManager.app
   ```

## 📝 License

Open Source. Feel free to fork and modify!
