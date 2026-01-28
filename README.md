<div align="center">

# Claude Code Status Line

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-blue)](https://github.com)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Compatible-blueviolet)](https://claude.ai)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](http://makeapullrequest.com)

**A feature-rich, customizable status line for Claude Code CLI**

*Display project info, git status, context usage, running servers, and more — all at a glance.*

[Features](#-features) •
[Installation](#-installation) •
[Configuration](#%EF%B8%8F-configuration) •
[Contributing](#-contributing)

</div>

---

## Preview

```
📁 ~/my-project | 🌿 main | ✅ synced | 🤖 Claude Opus 4 | 📦 v1.0.0 | 🎨 normal | 🌐 http://localhost:3000
→ Add authentication to the API
📝 (Previous: Implemented user login flow)
🧠 Context: 150K (75%) [======--] | 📊 Daily: Resets in 8h 30m (2:00 AM) | 📅 Weekly: Resets in 3d 5h (Mon 10:59 AM)
```

---

## ✨ Features

### Line 1 — Project & Environment

| Icon | Information |
|:----:|-------------|
| 📁 | Project directory (with `~` for home) |
| 🌿 | Git branch (handles detached HEAD) |
| 🔶/✅/⬇️/⬆️/🔀/📍 | Git sync status (local changes, synced, behind, ahead, diverged, local only) |
| 🤖 | Model name (with highlighted background) |
| 📦 | Claude Code version |
| 🎨 | Output style |
| 🌐/🐍/☕/💎/🔷 | Running dev servers with clickable links (auto-detected by technology) |

### Line 2 — Last Prompt

Displays your most recent message to Claude (truncated to 100 characters for readability).

### Line 3 — Conversation Summary

- AI-generated summary of previous/resumed sessions using Claude Haiku
- Smart caching to avoid regeneration on each refresh
- Automatic detection of resumed sessions via time gaps (>2 minutes)

### Line 4 — Usage Tracking

| Metric | Description |
|--------|-------------|
| 🧠 **Context Window** | Remaining tokens with color-coded progress bar |
| 📊 **Daily Reset** | Countdown to daily rate limit reset |
| 📅 **Weekly Reset** | Countdown to weekly rate limit reset |

**Context Window Color Coding:**
- 🟢 Green: >50% remaining
- 🟡 Yellow: 20-50% remaining
- 🔴 Red: <20% remaining

---

## 📦 Installation

### Prerequisites

| Requirement | Description | Installation |
|-------------|-------------|--------------|
| `jq` | JSON processor | `brew install jq` (macOS) / `apt install jq` (Linux) |
| `lsof` | List open files | Pre-installed on macOS/Linux |
| `claude` | Claude Code CLI | Required for conversation summaries |
| `gtimeout`/`timeout` | Command timeout | Optional, for summary generation timeout |

### Quick Start

**1. Clone this repository:**

```bash
git clone https://github.com/YOUR_USERNAME/claude-code-statusline.git
cd claude-code-statusline
```

**2. Copy the script to your Claude config directory:**

```bash
cp statusline-command.sh ~/.claude/statusline-command.sh
chmod +x ~/.claude/statusline-command.sh
```

**3. Configure Claude Code settings:**

```bash
# If you don't have a settings.json yet:
cp settings.json ~/.claude/settings.json

# Or manually add to your existing ~/.claude/settings.json:
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

**4. Restart Claude Code** to see your new status line.

---

## ⚙️ Configuration

### Rate Limit Reset Times

Customize the countdown timers via environment variables (add to your `.bashrc` or `.zshrc`):

```bash
# Daily reset (default: 2:00 AM)
export CLAUDE_RESET_HOUR=2
export CLAUDE_RESET_MINUTE=0

# Weekly reset (default: Monday 10:59 AM)
export CLAUDE_WEEKLY_RESET_DAY=1      # 1=Mon, 2=Tue, ... 7=Sun
export CLAUDE_WEEKLY_RESET_HOUR=10
export CLAUDE_WEEKLY_RESET_MINUTE=59
```

### Dev Server Detection

The status line automatically detects running development servers by:

1. Checking if the server process command line contains the project path
2. Checking if the server's working directory is within the project
3. Checking parent processes for project association

**Technology Icons:**

| Icon | Technology |
|:----:|------------|
| 🌐 | Node.js / npm / Vite |
| 🐍 | Python / Uvicorn |
| ☕ | Java |
| 💎 | Ruby / Rails |
| 🔷 | Go |
| 🔹 | Other |

---

## 🎨 Customization

The script is modular and well-commented. Here are common customizations:

| Customization | How To |
|---------------|--------|
| Add/remove items | Modify `line1`, `line2`, `line3`, `line4` variables |
| Change icons | Update emoji characters in the script |
| Adjust colors | Modify ANSI codes: `\033[32m` (green), `\033[33m` (yellow), `\033[31m` (red) |
| Summary length | Change truncation limits (60 chars for summary, 100 for prompt) |

---

## 🔧 Troubleshooting

<details>
<summary><strong>Summary not appearing</strong></summary>

- Ensure `claude` CLI is in your PATH
- Check that you have access to the Haiku model
- Summaries only appear for resumed sessions

</details>

<details>
<summary><strong>Dev servers not detected</strong></summary>

- The script looks for servers running in your project directory
- Ensure your server was started from within the project

</details>

<details>
<summary><strong>Colors not displaying</strong></summary>

- Your terminal must support ANSI escape codes
- Try a different terminal emulator

</details>

---

## 🤝 Contributing

Contributions are welcome! Here's how you can help improve this project:

### Ways to Contribute

- **Report Bugs**: Open an issue describing the bug and how to reproduce it
- **Suggest Features**: Have an idea? Open an issue to discuss it
- **Submit Pull Requests**: Fix bugs or implement new features
- **Improve Documentation**: Help make the docs clearer and more comprehensive
- **Share Your Customizations**: Show us your personalized status line configurations

### Development Workflow

1. **Fork the repository**

2. **Create a feature branch:**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes** and test them locally by copying to `~/.claude/`

4. **Commit your changes:**
   ```bash
   git commit -m "Add: brief description of your changes"
   ```

5. **Push to your fork:**
   ```bash
   git push origin feature/your-feature-name
   ```

6. **Open a Pull Request** with a clear description of your changes

### Commit Message Guidelines

Use descriptive commit messages:
- `Add: new feature or functionality`
- `Fix: bug fix description`
- `Update: improvements to existing features`
- `Docs: documentation changes`
- `Refactor: code refactoring`

### Code Style

- Keep the script POSIX-compatible where possible
- Add comments for complex logic
- Test on both macOS and Linux if possible
- Maintain backward compatibility

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

<div align="center">

**If you find this useful, please consider giving it a ⭐**

Made with ❤️ for the Claude Code community

</div>
