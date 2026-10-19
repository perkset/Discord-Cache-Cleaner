# Discord Cache Cleaner

A PowerShell script that clears Discord's HTTP cache on Windows.

## Why clear the cache?

Clearing cache can free up disk space and help with loading or display problems. See [Discord's troubleshooting guide](https://support.discord.com/hc/en-us/articles/31623498041623-Discord-Troubleshooting-Guide).

## How to use

Paste this into PowerShell to run the latest version from GitHub:

```powershell
irm https://raw.githubusercontent.com/perkset/Discord-Cache-Cleaner/main/DiscordCacheCleaner.ps1 -ErrorAction Stop | iex
```

Follow the prompts. Closing Discord ends active calls and streams. Wait for any Discord updates to finish first.

Or download `DiscordCacheCleaner.ps1` and run it from its folder:

```powershell
.\DiscordCacheCleaner.ps1
```

To preview without deleting anything:

```powershell
.\DiscordCacheCleaner.ps1 -DryRun
```

## Notes

- Windows PowerShell 5.1 or PowerShell 7. No admin rights needed.
- Supports standard Discord Stable, PTB and Canary installations.
- Only removes HTTP cache files. Login data, settings and downloads stay untouched.
- Deleted cache cannot be restored. Discord recreates it as needed.

Not affiliated with Discord.
