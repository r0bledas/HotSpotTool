# HotSpotTool

Windows Mobile Hotspot management and auto-start utilities, with optional Telegram notifications.

## Versions

| Folder | Description |
| --- | --- |
| [`HotSpotV5`](HotSpotV5/) | Latest version. Interactive manager, silent install, custom peer counts, clean uninstall, Telegram notifications. See the [V5 README](HotSpotV5/README.md). |
| [`HotSpotV4`](HotSpotV4/) | Previous version with separate 8-peer and 50-peer scripts. |

## Quick Start (V5)

1. Open `HotSpotV5\HotspotTool.bat`.
2. Choose an install option (8 peers, 50 peers, or custom).
3. Approve the elevation prompt.

### Command Line

```powershell
# Install with 8 peers (Windows default), no prompts
powershell.exe -ExecutionPolicy Bypass -File .\HotSpotV5\HotspotTool.ps1 -Install -MaxPeers 8 -Silent

# Install with 50 peers
powershell.exe -ExecutionPolicy Bypass -File .\HotSpotV5\HotspotTool.ps1 -Install -MaxPeers 50 -Silent

# Uninstall and restore Windows defaults
powershell.exe -ExecutionPolicy Bypass -File .\HotSpotV5\HotspotTool.ps1 -Uninstall -Silent
```

## Telegram Setup

The Telegram bot token has been replaced with the placeholder `YOUR_TELEGRAM_BOT_TOKEN` in all scripts. Before using notifications, replace the placeholder (and the `ChatId` value) with your own credentials in:

- `HotSpotV5\HotspotTool.ps1`
- `HotSpotV4\HotspotTool8Peers.ps1`
- `HotSpotV4\HotspotTool50Peers.ps1`

Notifications are optional; the hotspot tooling itself works without them.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Administrative privileges (the scripts self-elevate)
- A Wi-Fi adapter that supports Mobile Hotspot
