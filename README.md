# Notsy 📝

Notsy is a lightning-fast, keyboard-first, native macOS notes application designed for developers and power users. Inspired by the premium, minimalist aesthetics of Spotlight and Raycast, it lives silently in your menu bar and summons a beautiful floating command-palette style editor anywhere on your screen.

![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![Platform](https://img.shields.io/badge/macOS-14.0+-lightgrey.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)

---

## ✨ Features

- **Raycast-Inspired UI:** A beautiful, borderless, dark-themed floating window that feels like a native OS extension.
- **Keyboard First:** Never touch your mouse. Summon the app, search, create, and edit entirely via keyboard shortcuts.
- **Smart Markdown-like Lists:** Natively converts `- ` into bullets and supports nested tab-indentation and Notion-style interactive checkboxes `○` / `◉`.
- **Instant Search:** As you type, Notsy searches titles and content and auto-selects the top hit for instant editing.
- **Pinning:** Keep important notes at the top of your sidebar forever.
- **Privacy Focused:** 100% offline. All notes and rich text data are stored locally on your machine.
- **Native Performance:** Built purely with Swift, SwiftUI, and TextKit 2 for zero-lag typing and minimal resource usage.

---

## 🚀 Installation

### Download
1. **[Download the latest installer (Notsy.dmg)](https://github.com/iamsumanp/notsy/raw/main/Notsy.dmg)** *(Link placeholder until uploaded to releases)*
2. Open the disk image and drag **Notsy** to your Applications folder.

### First Run
- Launch Notsy from your Applications folder.
- A small note icon will appear in your top macOS menu bar. 

---

## ⌨️ Usage

### Global Shortcut
The default shortcut to open Notsy is: **`Shift + Command + Space`**
*The window will automatically spawn on the monitor where your mouse is currently active.*

### Navigation & Editing
- **Type to Search:** Start typing to instantly filter your notes.
- **Enter:** If searching, `Enter` opens the highlighted note. If typing a new search query, `Enter` creates a new note titled with your query.
- **Cmd + N:** Create a new blank note instantly.
- **Cmd + P:** Pin or unpin the active note.
- **Esc:** Clears your search query. Pressing `Esc` again hides the window.
- **Rich Text:** Highlight text and use standard macOS shortcuts (`Cmd+B`, `Cmd+I`, `Cmd+U`) to format.
- **Smart Lists:** Type `- ` at the start of a line to begin a bullet list.

### Preferences
- Press **`Cmd + ,`** while the window is open to access Settings.
- Quickly manage your data (Clear all unpinned notes, or wipe the database entirely).

---

## 🛠️ Building from Source

If you want to build the app yourself or contribute:

**Prerequisites:**
- macOS 14.0 (Sonoma) or later.
- Xcode 15+ (or Command Line Tools).

**Clone the Repository:**
```bash
git clone https://github.com/iamsumanp/notsy.git
cd notsy
```

**Run Locally (Debug):**
```bash
swift run
```

---

## 📂 Project Structure

- `Sources/notsy/App/`: App entry point, Window configuration, and Menu Bar delegation.
- `Sources/notsy/Models/`: Core data logic (`Note`, `NoteStore`) and local JSON persistence.
- `Sources/notsy/UI/`: SwiftUI views (`MainPanel`, `PreferencesView`, `Theme`) and the highly customized `RichTextEditorView` TextKit wrapper.
- `Sources/notsy/Extensions/`: Global Carbon hotkey manager.

---

## 🔒 Privacy

Notsy operates **100% offline**. Your data is never sent to the cloud.
Your notes history is stored locally in plain JSON and standard Apple RTF data at:
`~/Library/Application Support/Notsy/notes.json`

---

## ❓ Troubleshooting

**"App is damaged and can't be opened"**
If you see this error after downloading the `.dmg`, it is because the app is not notarized by Apple (which requires a paid developer account). To fix it:

1. Open your Terminal.
2. Run the following command to remove the quarantine attribute:
   ```bash
   xattr -cr /Applications/Notsy.app
   ```
3. Launch the app again.

---

## 📄 License

This project is licensed under the MIT License.
