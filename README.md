
# <img width="40" height="40" alt="Picsart_26-01-02_10-51-59-780" src="https://github.com/user-attachments/assets/43445e6a-d958-4555-b872-36d7323b8cd1" /> CineWall

**The Native Video Wallpaper Engine for macOS.**

[![macOS](https://img.shields.io/badge/Platform-macOS-black?logo=apple)](https://www.apple.com/macos)
[![Release](https://img.shields.io/github/v/release/saivinay1805/CineWall?color=blue&label=Latest%20Version)](https://github.com/saivinay1805/CineWall/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

### 🎥 Live Demo

https://github.com/user-attachments/assets/cd3b29fd-9c5f-447c-9b2b-b33df9c2dc9f

<br>

https://github.com/user-attachments/assets/d86b8f6b-ca3b-4ff0-b715-84e853954f44

---

### 📖 Overview
**CineWall** is a high-performance, native macOS utility designed to turn your desktop into a cinematic experience.

While many wallpaper engines exist, most restrict users to single-file selection or require importing files into a proprietary library. **CineWall** was built to solve this. It plays your local **Folders**, **GIFs**, and **Videos** directly from your disk (including external SSDs) without duplicating files or requiring uploads.

It features a stunning **"Liquid Glass" UI** (inspired by macOS Tahoe concepts) that blends seamlessly into your desktop environment.

### ✨ Key Features

#### 🌊 Aesthetics & UI
*   **Liquid Glass Interface:** A modern, borderless, refractive menu that blurs the background behind it.
*   **Minimalist Player:** Full playback controls (Previous, Next, Pause) with a live **scrubbing bar**.
*   **Pin Mode:** Keep the menu open and floating above other windows for easy control.

#### 🎛️ Playlist & File Management
*   **Folder Support:** Point CineWall to a folder, and it will auto-play all contained videos and GIFs.
*   **Smart Persistence:** Remembers your last played file and folder, even after a restart.
*   **Drag & Drop:** Simply drag a video file onto the menu to play it instantly without navigating finder.
*   **Zero-Space Favorites:** Add videos to your "Favorites" list without duplicating the file storage.

#### ⚡ Performance & Intelligence
*   **Smart Pause:** Automatically pauses playback when:
    *   An application is maximized/fullscreen.
    *   The desktop is completely covered (Occlusion detection).
    *   (Optional) You focus on another application.
*   **Battery Saver:** Automatically pauses the engine when the MacBook is unplugged.
*   **SSD Auto-Mount:** If your wallpaper library is on an external drive, CineWall detects when the drive connects and auto-loads your playlist.
*   **Native Core:** Built with Swift and `AVFoundation`. Uses negligible CPU (approx 0% when paused, <5% when playing 4K).

#### 🖥️ Desktop Integration
*   **Hide Desktop Icons:** One-click toggle to hide all desktop icons and widgets for a clean look.
*   **Multi-Space Support:** Choose to show the wallpaper on all Spaces or bring it to the current active Space.

---

### 📥 Installation

**CineWall is an unsigned open-source application.** To run it, you must bypass the Gatekeeper warning once.

1.  **[Download the latest ZIP](https://github.com/saivinay1805/CineWall-App/releases/latest)** from the Releases page.
2.  Unzip and move `CineWall.app` to your **Applications** folder.
3.  **Right-Click** the app and select **Open**.
4.  Click **Open** in the dialog box.
5.  *(Optional)* Grant **Accessibility Permissions** in System Settings to enable the "Hide Desktop Icons" feature.

---

### 🛠️ Building from Source

Requirements:
- macOS 13.0 or higher
- Xcode 15+ with Swift 5.9+

```bash
# Clone the repository
git clone https://github.com/saivinay1805/CineWall.git
cd CineWall

# Open the project in Xcode
open SimpleVideoWallpaper.xcodeproj
```

Select the `SimpleVideoWallpaper` target and click **Run** (or `Cmd + R`).

---

### 🗺️ Roadmap & Known Limitations
*   **Current:** Supports the main primary display with Lock Screen video sync (Fast & Compatible modes).
*   **Planned:** Multi-monitor support (Different wallpapers for different screens).

---

### 🤝 Contributing & Feedback
This project is open source under the MIT License! Contributions and feedback are welcome!
If you encounter bugs or have feature requests, please [open an issue](https://github.com/saivinay1805/CineWall/issues).

---

*Built with ❤️ for the Mac Community.*
