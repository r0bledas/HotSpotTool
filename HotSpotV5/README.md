# Mobile Hotspot Manager V5

A resilient Windows Mobile Hotspot management and auto-start utility designed for single or multi-computer deployment with Telegram notifications.

## Key Improvements in V5

1. **Fixed Telegram Emoji Encoding (`??` Bug Fixed)**:
   - Formats messages with Telegram HTML mode and direct UTF-8 byte streams, bypassing PowerShell 5.1's `ConvertTo-Json` bug and ensuring emojis (🔔, 📶, 🔑) render correctly.
2. **Multi-Computer Safe (No Polling Conflicts)**:
   - Designed for networks where multiple computers share the same Telegram bot token. The background service maintains the hotspot and sends notifications (`sendMessage`) on startup and credential changes without `getUpdates` polling conflicts.
3. **Version Tagging**:
   - Every alert includes `_Running on V5_` for version tracking.
4. **Clean & Traceless Uninstallation**:
   - Reverts all registry settings (`WifiMaxPeers`, `PeerlessTimeout`, `PublicConnectionTimeout`) to Windows defaults, removes all scheduled tasks, terminates background processes, and deletes `C:\ProgramData\HotspotAutoStart`. No disk logs or artifacts remain.
5. **Instant Synchronous Activation**:
   - Hotspot is activated and validated immediately during installation before sending the Telegram activation alert.
6. **Auto-Shutoff Prevention**:
   - Disables Windows 5-minute idle hotspot auto-shutdown via `PeerlessTimeout` and `PublicConnectionTimeout` registry settings.

## Usage

### Interactive Menu
Run [`HotspotTool.bat`](HotspotTool.bat) to open the interactive manager:
- `0. Silent Quick Install (8 Peers - Auto-Exit)`
- `1. Install & Enable Hotspot (8 Peers - Windows Default)`
- `2. Install & Enable Hotspot (50 Peers - High Capacity)`
- `3. Install & Enable Hotspot (Custom Peer Count)`
- `4. Revert & Uninstall (Restore Windows Defaults)`
- `5. Exit`

### Command-Line (Headless / Automated)
```powershell
# Silent Install with 8 peers (Default)
powershell.exe -ExecutionPolicy Bypass -File HotspotTool.ps1 -Install -MaxPeers 8 -Silent

# Silent Install with 50 peers (High Capacity)
powershell.exe -ExecutionPolicy Bypass -File HotspotTool.ps1 -Install -MaxPeers 50 -Silent

# Silent Install with custom peer limit
powershell.exe -ExecutionPolicy Bypass -File HotspotTool.ps1 -Install -MaxPeers 32 -Silent

# Silent Uninstall and revert all changes to Windows defaults
powershell.exe -ExecutionPolicy Bypass -File HotspotTool.ps1 -Uninstall -Silent
```
