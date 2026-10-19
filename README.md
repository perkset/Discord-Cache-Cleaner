# Discord Cache Cleaner

A simple PowerShell script that clears Discord's HTTP cache on Windows.

## Before running

Close Discord completely, including from the system tray. Wait for any updates to finish, and keep Discord closed while the script runs.

## How to use

1. Download `DiscordCacheCleaner.ps1`.
2. Open PowerShell in the folder where you saved it.
3. Run:

```powershell
.\DiscordCacheCleaner.ps1
```

The script shows the cache location and size. Type `CLEAN` to confirm, or press Enter to cancel.

To preview without deleting anything:

```powershell
.\DiscordCacheCleaner.ps1 -DryRun
```

## Notes

- Works with Windows PowerShell 5.1 and PowerShell 7. No administrator rights or extra files needed.
- Supports standard Discord Stable, PTB and Canary installations.
- Only clears HTTP cache files. Login data, settings and downloaded files are excluded.
- Deleted cache cannot be restored. Discord will recreate it as needed.
- Clearing cache can free up disk space. It does not guarantee lower RAM or CPU usage.

This is an independent project and is not affiliated with Discord.
