# Discord Cache Cleaner

A simple PowerShell script that clears Discord's HTTP cache on Windows.

## Why clear the cache?

Discord keeps local copies of images and other web resources so it does not have to download them every time. Clearing these files can free up disk space and is a troubleshooting step for loading or display problems. [Discord's troubleshooting guide](https://support.discord.com/hc/en-us/articles/31623498041623-Discord-Troubleshooting-Guide) includes cache clearing.

It is not a general speed boost. If Discord works fine and you have enough disk space, you probably do not need to clear it.

After cleaning, Discord downloads needed resources again. The first use may be slower and use more data. The cache will grow again, and clearing it does not guarantee lower RAM or CPU usage.

## How to use

1. Download `DiscordCacheCleaner.ps1`.
2. Open PowerShell in the folder where you saved it.
3. Run:

```powershell
.\DiscordCacheCleaner.ps1
```

The script shows the cache location and size. If Discord is open, press Enter when asked to close it. This ends calls and streams, and unsaved drafts may be lost. You can also quit Discord yourself from the system tray.

Wait for updates to finish first; the script will not stop Discord's updater. Keep Discord closed while cleaning. Press Enter at the cleanup prompt to delete the cache. At either confirmation prompt, type anything and press Enter to cancel.

After closing Discord, the script continues in the same window. It shows how many files were deleted and waits for Enter before exiting. If something goes wrong, the error stays on screen too.

To preview without deleting anything:

```powershell
.\DiscordCacheCleaner.ps1 -DryRun
```

## Download from PowerShell

You can download the script from GitHub without opening a browser. Use a folder where `DiscordCacheCleaner.ps1` does not already exist:

```powershell
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/perkset/Discord-Cache-Cleaner/main/DiscordCacheCleaner.ps1" -OutFile ".\DiscordCacheCleaner.ps1"
notepad .\DiscordCacheCleaner.ps1
```

Read the downloaded file before running it. The link follows the current `main` branch, so its contents can change. If you have a trusted release checksum, compare it with `Get-FileHash .\DiscordCacheCleaner.ps1 -Algorithm SHA256`.

Once you have reviewed it, run:

```powershell
.\DiscordCacheCleaner.ps1
```

## Notes

- Works with Windows PowerShell 5.1 and PowerShell 7. No administrator rights or extra files needed.
- Supports standard Discord Stable, PTB and Canary installations.
- Only clears HTTP cache files. Login data, settings and downloaded files are excluded.
- Deleted cache cannot be restored. Discord will recreate it as needed.
- `-DryRun` and `-WhatIf` never stop Discord or delete cache files.

This is an independent project and is not affiliated with Discord.
