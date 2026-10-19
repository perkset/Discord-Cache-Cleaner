#Requires -Version 5.1
<#
Discord Cache Cleaner 1.0.3 - self-contained Windows PowerShell 5.1/7 script.
Usage: .\DiscordCacheCleaner.ps1 [-Channel Stable|PTB|Canary] [-DryRun]
No sibling files, external downloads or administrator rights required.

MIT License

Copyright (c) 2026 DiscordOptimizer contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Stable', 'PTB', 'Canary')][string]$Channel,
    [switch]$DryRun
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Initialize-CacheNative {
    if ('DiscordCacheCleanerV103.CacheSession' -as [type]) { return }
    Add-Type -TypeDefinition @'
// Windows-only handles. No cache content reads, recursive deletion or ACL changes.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DiscordCacheCleanerV103 {
    public static class ProcessCloser {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern SafeWaitHandle OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool QueryFullProcessImageNameW(SafeWaitHandle handle, uint flags,
            System.Text.StringBuilder path, ref int size);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetProcessTimes(SafeWaitHandle handle,
            out System.Runtime.InteropServices.ComTypes.FILETIME creation,
            out System.Runtime.InteropServices.ComTypes.FILETIME exit,
            out System.Runtime.InteropServices.ComTypes.FILETIME kernel,
            out System.Runtime.InteropServices.ComTypes.FILETIME user);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool TerminateProcess(SafeWaitHandle handle, uint exitCode);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint WaitForSingleObject(SafeWaitHandle handle, uint milliseconds);

        public static void Stop(int id, long expectedCreation, string expectedPath) {
            // The retained handle identifies the original process even if its PID is reused.
            using (SafeWaitHandle handle = OpenProcess(0x00101001u, false, id)) {
                if (handle.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 87) return; // Process already exited.
                    throw new Win32Exception(error);
                }
                if (WaitForSingleObject(handle, 0) == 0) return;
                var path = new System.Text.StringBuilder(4096);
                int size = path.Capacity;
                System.Runtime.InteropServices.ComTypes.FILETIME creation, exit, kernel, user;
                if (!QueryFullProcessImageNameW(handle, 0, path, ref size) ||
                    !GetProcessTimes(handle, out creation, out exit, out kernel, out user))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (WaitForSingleObject(handle, 0) == 0) return;
                    throw new Win32Exception(error);
                }
                long stamp = ((long)(uint)creation.dwHighDateTime << 32) | (uint)creation.dwLowDateTime;
                if (stamp != expectedCreation || !String.Equals(path.ToString(), expectedPath, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Discord process changed. Nothing was stopped through this handle.");
                if (!TerminateProcess(handle, 0)) {
                    int error = Marshal.GetLastWin32Error();
                    if (WaitForSingleObject(handle, 0) != 0) throw new Win32Exception(error);
                }
                if (WaitForSingleObject(handle, 10000) != 0) throw new IOException("Discord did not stop in time.");
            }
        }
    }

    public sealed class Entry {
        public string Path;
        public bool Directory;
        public long Length;
        public long LastWriteTicks;
        public uint Attributes;
        internal SafeFileHandle Handle;
    }

    public sealed class CacheSession : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool Delete; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind,
            ref Disposition value, uint size);
        private readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
        private readonly HashSet<string> directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly List<Entry> entries = new List<Entry>();
        private readonly System.Diagnostics.Stopwatch timer = System.Diagnostics.Stopwatch.StartNew();
        private bool disposed;

        private Entry Open(string path, bool directory) {
            // No FILE_SHARE_WRITE/DELETE for directories: refuse write or rename handles.
            // Files request DELETE, share READ only: writes/replacements fail during the session.
            SafeFileHandle handle = CreateFileW(path, directory ? 0u : 0x00010000u,
                1u, IntPtr.Zero, 3u, 0x02200000u, IntPtr.Zero);
            if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
            try {
                Info info;
                if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((info.Attributes & 0x400u) != 0 || ((info.Attributes & 0x10u) != 0) != directory)
                    throw new IOException("Reparse point or changed entry type refused.");
                if (!directory && (info.Attributes & (1u | 0x1000u)) != 0)
                    throw new IOException("Read-only or offline file refused.");
                // Refuse hard links: unlinking one name does not necessarily reclaim its data.
                if (!directory && info.Links != 1) throw new IOException("Multiple file links refused.");
                handles.Add(handle);
                long stamp = ((long)(uint)info.Write.dwHighDateTime << 32) | (uint)info.Write.dwLowDateTime;
                return new Entry { Path=path, Directory=directory,
                    Length=directory ? 0 : ((long)info.SizeHigh << 32) | info.SizeLow,
                    LastWriteTicks=DateTime.FromFileTimeUtc(stamp).Ticks,
                    Attributes=info.Attributes, Handle=handle };
            } catch { handle.Dispose(); throw; }
        }

        public void LockDirectoryBranch(string path) {
            if (disposed) throw new ObjectDisposedException("CacheSession");
            string full = System.IO.Path.GetFullPath(path);
            if (full.StartsWith(@"\\", StringComparison.Ordinal) || full.Length > 240 || full.IndexOf(':', 2) >= 0)
                throw new IOException("Only short local drive paths are supported.");
            var branch = new Stack<string>();
            for (DirectoryInfo item = new DirectoryInfo(full); item != null; item = item.Parent) branch.Push(item.FullName);
            while (branch.Count > 0) {
                string next = branch.Pop();
                if (directories.Add(next)) Open(next, true);
            }
        }

        public Entry[] Prepare(string root) {
            if (entries.Count > 0) throw new InvalidOperationException("Session already prepared.");
            LockDirectoryBranch(root);
            var queue = new Queue<string>(); queue.Enqueue(root);
            while (queue.Count > 0) {
                if (timer.Elapsed.TotalSeconds > 30) throw new IOException("Preflight time limit exceeded.");
                string directory = queue.Dequeue();
                // Directory itself is already pinned. Never follow a child until opened without reparse traversal.
                foreach (string child in Directory.GetFileSystemEntries(directory)) {
                    if (timer.Elapsed.TotalSeconds > 30) throw new IOException("Preflight time limit exceeded.");
                    if (entries.Count >= 10000) throw new IOException("Cache entry limit exceeded.");
                    if (child.Length > 240) throw new IOException("Long path refused.");
                    FileAttributes attributes = File.GetAttributes(child);
                    bool isDir = (attributes & FileAttributes.Directory) != 0;
                    Entry entry = Open(child, isDir);
                    entries.Add(entry);
                    if (isDir) { directories.Add(child); queue.Enqueue(child); }
                }
            }
            return entries.ToArray();
        }

        public void DeleteEntry(Entry entry) {
            if (disposed || !entries.Contains(entry) || entry.Directory) throw new InvalidOperationException("Invalid deletion entry.");
            Disposition value = new Disposition { Delete=true };
            if (!SetFileInformationByHandle(entry.Handle, 4, ref value, (uint)Marshal.SizeOf(typeof(Disposition))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            entry.Handle.Dispose();
        }

        public void Dispose() {
            if (disposed) return;
            disposed = true;
            for (int i=handles.Count-1; i>=0; i--) handles[i].Dispose();
        }
    }
}
'@ -ErrorAction Stop
}

function Test-SafeDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Inspect every ancestor: checking the final directory alone misses junctions.
    try {
        $current = [IO.Path]::GetFullPath($Path)
        while ($current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = $parent.FullName
        }
        return $true
    } catch { return $false }
}

function Protect-ReportText {
    param([Parameter(Mandatory)][string]$Text)
    # Reports never contain cache filenames, commands, message text or account data.
    foreach ($entry in @(@($env:LOCALAPPDATA, '%LOCALAPPDATA%'), @($env:APPDATA, '%APPDATA%'), @($env:USERPROFILE, '%USERPROFILE%'))) {
        if ($entry[0]) {
            foreach ($path in @([string]$entry[0], ([string]$entry[0]).Replace('\', '\\'))) {
                $Text = [regex]::Replace($Text, [regex]::Escape($path), [string]$entry[1], [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
        }
    }
    return $Text
}

function Get-DiscordChannels {
    @(
        [pscustomobject]@{ Channel = 'Stable'; Folder = 'discord'; ProcessName = 'Discord' }
        [pscustomobject]@{ Channel = 'PTB'; Folder = 'discordptb'; ProcessName = 'DiscordPTB' }
        [pscustomobject]@{ Channel = 'Canary'; Folder = 'discordcanary'; ProcessName = 'DiscordCanary' }
    )
}

function Get-DiscordInstallation {
    [CmdletBinding()]
    param()
    foreach ($channel in Get-DiscordChannels) {
        $root = Join-Path $env:LOCALAPPDATA $channel.Folder
        $profile = Join-Path $env:APPDATA $channel.Folder
        $versions = @()
        if (Test-SafeDirectory $root) {
            foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)) {
                if (-not (Test-SafeDirectory $dir.FullName)) { continue }
                $exe = Join-Path $dir.FullName ($channel.ProcessName + '.exe')
                try {
                    $file = Get-Item -LiteralPath $exe -ErrorAction Stop
                    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $versions += [pscustomobject]@{ FileVersion = $file.VersionInfo.FileVersion; ProductVersion = $file.VersionInfo.ProductVersion }
                } catch { continue }
            }
        }
        [pscustomobject]@{
            Channel = $channel.Channel; InstallRoot = $root; ProfileRoot = $profile
            Detected = ($versions.Count -gt 0); Versions = $versions
            Discovery = 'Standard per-user layout only; other layouts are not inferred'
        }
    }
}

function Get-CacheTarget {
    param([ValidateSet('Stable', 'PTB', 'Canary')][string]$Channel)
    $definition = Get-DiscordChannels | Where-Object { $_.Channel -eq $Channel }
    $install = @(Get-DiscordInstallation | Where-Object { $_.Channel -eq $Channel -and $_.Detected })
    if ($install.Count -ne 1) { throw 'A standard installation of the selected channel must be detected.' }
    $root = [IO.Path]::GetFullPath((Join-Path $env:APPDATA ($definition.Folder + '\Cache')))
    if ($root.StartsWith('\\') -or $root.Length -gt 240 -or $root.IndexOf(':', 2) -ge 0) { throw 'Only short local drive paths are supported.' }
    $root
}

function Assert-DiscordStopped {
    # Fail closed on enumeration failures and inaccessible updater paths. Never read command lines.
    $roots = @(Get-DiscordChannels | ForEach-Object { (Join-Path $env:LOCALAPPDATA $_.Folder).TrimEnd('\') + '\' })
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        if ($process.ProcessName -like 'Discord*') { throw 'Discord is running. Quit it from the system tray and retry. No processes will be stopped.' }
        if ($process.ProcessName -eq 'Update') {
            $path = $null
            try { $path = $process.Path } catch { throw 'An updater cannot be identified. Close updaters and retry.' }
            if (-not $path) { throw 'An updater cannot be identified. Close updaters and retry.' }
            foreach ($root in $roots) {
                if ($path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Discord updater is running. Wait for it to finish and retry.' }
            }
        }
    }
}

function Get-DiscordCloseTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Stable', 'PTB', 'Canary')][string]$Channel)
    $definition = Get-DiscordChannels | Where-Object { $_.Channel -eq $Channel }
    $root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA $definition.Folder))
    $updaterRoots = @(Get-DiscordChannels | ForEach-Object { (Join-Path $env:LOCALAPPDATA $_.Folder).TrimEnd('\') + '\' })
    $targets = @()
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        if ($process.ProcessName -eq 'Update') {
            $updaterPath = $null
            try { $updaterPath = $process.Path } catch { throw 'An updater cannot be identified. Close it manually before continuing.' }
            if (-not $updaterPath) { throw 'An updater cannot be identified. Close it manually before continuing.' }
            foreach ($updaterRoot in $updaterRoots) {
                if ($updaterPath.StartsWith($updaterRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Discord is updating. Wait for it to finish; the updater will not be stopped.' }
            }
        }
        if ($process.ProcessName -notlike 'Discord*') { continue }
        if ($process.ProcessName -ine $definition.ProcessName) { throw 'Another Discord client or helper is open. Quit it manually before continuing.' }
        $path = $process.Path
        if (-not $path) { throw 'Discord executable path is unavailable. Quit Discord manually.' }
        $directory = [IO.Path]::GetDirectoryName($path)
        if (-not $directory -or -not ([IO.Path]::GetDirectoryName($directory)).Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            -not ([IO.Path]::GetFileName($directory)).StartsWith('app-', [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($path) -ine ($definition.ProcessName + '.exe') -or -not (Test-SafeDirectory $directory)) {
            throw 'Discord is not in a verified standard location. Quit it manually.'
        }
        $file = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked Discord executable refused. Quit Discord manually.' }
        $targets += [pscustomobject]@{ Id = $process.Id; Path = $path; CreationFileTime = $process.StartTime.ToUniversalTime().ToFileTimeUtc() }
    }
    if ($targets.Count -eq 0) { throw 'No verified Discord processes can be stopped automatically. Close Discord and its updater manually.' }
    $targets
}

function Stop-VerifiedDiscordProcess {
    param([Parameter(Mandatory)]$Target)
    Initialize-CacheNative
    [DiscordCacheCleanerV103.ProcessCloser]::Stop($Target.Id, $Target.CreationFileTime, $Target.Path)
}

function Request-DiscordClose {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][ValidateSet('Stable', 'PTB', 'Canary')][string]$Channel)
    $targets = @(Get-DiscordCloseTargets $Channel)
    if ($WhatIfPreference) { $null = $PSCmdlet.ShouldProcess($Channel, 'Stop verified Discord processes'); return $false }
    Write-Host 'Discord is open. Stopping it will end calls/streams and may discard unsaved drafts.'
    if ((Read-Host 'Press Enter to close Discord, or type anything to cancel') -cne '') {
        Write-Host 'Cancelled. Discord was not stopped and cache was not deleted.'
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Channel, 'Stop only the verified Discord processes shown by this client')) { return $false }
    foreach ($target in $targets) { Stop-VerifiedDiscordProcess $target }
    Assert-DiscordStopped
    Write-Host 'Discord is closed. Checking the cache again.'
    return $true
}

function Get-CacheTreeMetadata {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-SafeDirectory $Root)) { throw 'Cache is missing, inaccessible or traverses a reparse point.' }
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0) {
        if ($clock.Elapsed.TotalSeconds -gt 30) { throw 'Cache preflight time limit exceeded.' }
        $directory = $queue.Dequeue()
        if (-not (Test-SafeDirectory $directory)) { throw 'Unsafe cache directory.' }
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($clock.Elapsed.TotalSeconds -gt 30) { throw 'Cache preflight time limit exceeded.' }
            if ($entries.Count -ge 10000 -or $item.FullName.Length -gt 240) { throw 'Cache entry or path length limit exceeded.' }
            if ($item.Attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Offline)) { throw 'Linked, read-only or offline cache entry refused.' }
            $length = [long]0
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) } else { $length = [long]$item.Length }
            $entries.Add([pscustomobject]@{ Path = $item.FullName; Directory = [bool]$item.PSIsContainer; Length = $length; LastWriteTicks = $item.LastWriteTimeUtc.Ticks; Attributes = [uint32]$item.Attributes })
        }
    }
    $entries.ToArray()
}

function Get-CacheFingerprint {
    param([AllowEmptyCollection()][object[]]$Entries)
    $lines = @($Entries | ForEach-Object {
        # Directory timestamps can lag child creation; compare membership and attributes instead.
        $stamp = $_.LastWriteTicks
        if ($_.Directory) { $stamp = 0 }
        '{0}|{1}|{2}|{3}|{4}' -f $_.Path, $_.Directory, $_.Length, $stamp, $_.Attributes
    })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-', '') }
    finally { $hash.Dispose() }
}

function Get-CachePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Stable', 'PTB', 'Canary')][string]$Channel)
    $root = Get-CacheTarget $Channel
    $entries = @(Get-CacheTreeMetadata $root)
    $files = @($entries | Where-Object { -not $_.Directory })
    $bytes = [long]0
    foreach ($file in $files) { $bytes += $file.Length }
    $ready = $true; $reason = 'Ready (application state will be rechecked before deletion)'
    try { Assert-DiscordStopped } catch { $ready = $false; $reason = $_.Exception.Message }
    [pscustomobject]@{
        Channel = $Channel; Root = $root; FileCount = $files.Count; LogicalBytes = $bytes
        Fingerprint = Get-CacheFingerprint $entries; Ready = $ready; Reason = $reason
        Irreversible = $true; Scope = 'Cache files only; empty directories are retained'
    }
}

function New-CacheJournal {
    param([Parameter(Mandatory)]$Session)
    # Pin existing ancestors first, then create and pin each tool-owned child directory.
    $parent = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
    $Session.LockDirectoryBranch($parent)
    foreach ($name in @('DiscordCacheCleaner', 'Logs')) {
        $parent = Join-Path $parent $name
        $null = [IO.Directory]::CreateDirectory($parent)
        $Session.LockDirectoryBranch($parent)
    }
    $path = Join-Path $parent (([Guid]::NewGuid().ToString('N')) + '.jsonl')
    $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    [pscustomobject]@{ Path = $path; Stream = $stream }
}

function Write-CacheJournal {
    param([Parameter(Mandatory)]$Journal, [Parameter(Mandatory)]$Event)
    $text = Protect-ReportText (($Event | ConvertTo-Json -Compress) + [Environment]::NewLine)
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $Journal.Stream.Write($bytes, 0, $bytes.Length)
    $Journal.Stream.Flush($true)
}

function Invoke-CacheCleanup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)]$Plan)
    # Treat plans as untrusted. Derive the allowlisted target again and rebuild metadata.
    $fresh = Get-CachePlan -Channel $Plan.Channel
    if ($fresh.Root -cne $Plan.Root -or $fresh.Fingerprint -cne $Plan.Fingerprint -or $fresh.FileCount -ne $Plan.FileCount -or $fresh.LogicalBytes -ne $Plan.LogicalBytes) { throw 'Cache changed since preview. Review a new plan.' }
    if ($WhatIfPreference) { $null = $PSCmdlet.ShouldProcess($fresh.Root, 'Permanently delete planned HTTP cache files'); return }
    if (-not $fresh.Ready) { throw $fresh.Reason }
    if ($fresh.FileCount -eq 0) { return [pscustomobject]@{ Status = 'NoOp'; DeletedFiles = 0; DeletedLogicalBytes = 0; JournalPath = $null; Error = $null } }
    if (-not $PSCmdlet.ShouldProcess($fresh.Root, 'Permanently delete planned HTTP cache files (no content rollback)')) { return }
    Assert-DiscordStopped
    Initialize-CacheNative
    $session = New-Object DiscordCacheCleanerV103.CacheSession
    $journal = $null
    $result = [pscustomobject]@{ Status = 'Aborted'; DeletedFiles = 0; DeletedLogicalBytes = [long]0; JournalPath = $null; Error = $null }
    try {
        $entries = @($session.Prepare($fresh.Root))
        if ((Get-CacheFingerprint $entries) -cne $fresh.Fingerprint) { throw 'Cache changed while locking files. No files deleted.' }
        Assert-DiscordStopped
        $journal = New-CacheJournal $session
        $result.JournalPath = $journal.Path
        Write-CacheJournal $journal ([ordered]@{ Event = 'Started'; Utc = [DateTime]::UtcNow.ToString('o'); Version = '1.0.3'; Channel = $fresh.Channel; PlannedFiles = $fresh.FileCount; PlannedLogicalBytes = $fresh.LogicalBytes; Fingerprint = $fresh.Fingerprint; Irreversible = $true })
        foreach ($entry in @($entries | Where-Object { -not $_.Directory })) {
            Assert-DiscordStopped
            Write-CacheJournal $journal ([ordered]@{ Event = 'Deleting'; Index = $result.DeletedFiles + 1 })
            $session.DeleteEntry($entry)
            $result.DeletedFiles++; $result.DeletedLogicalBytes += $entry.Length
            Write-CacheJournal $journal ([ordered]@{ Event = 'Deleted'; DeletedFiles = $result.DeletedFiles; DeletedLogicalBytes = $result.DeletedLogicalBytes })
        }
        $result.Status = 'Completed'
    } catch {
        if ($result.DeletedFiles -gt 0) { $result.Status = 'Partial' }
        # No filenames or arbitrary OS exception text in persistent logs.
        $result.Error = 'Operation stopped after a safety, file access or journal failure. Deleted cache cannot be restored.'
        Write-Verbose $_.Exception.Message
    } finally {
        try {
            if ($null -ne $journal) {
                try { Write-CacheJournal $journal ([ordered]@{ Event = $result.Status; Utc = [DateTime]::UtcNow.ToString('o'); DeletedFiles = $result.DeletedFiles; DeletedLogicalBytes = $result.DeletedLogicalBytes; Error = $result.Error }) }
                catch { $result.Status = 'JournalFailure'; $result.Error = 'Journal write failed. Deletion may already have occurred; inspect counters.' }
                $journal.Stream.Dispose()
            }
        } finally { $session.Dispose() }
    }
    $result
}

function Invoke-DiscordCacheCleaner {
    param([string]$Channel, [switch]$DryRun)
    if ($env:OS -ne 'Windows_NT') { throw 'Windows 10 or 11 is required.' }
    Write-Host "`nDISCORD CACHE CLEANER"
    if (-not $Channel) {
        $installed = @(Get-DiscordInstallation | Where-Object { $_.Detected })
        if ($installed.Count -eq 0) { throw 'No standard Discord installation found. Nothing changed.' }
        if ($installed.Count -eq 1) { $Channel = $installed[0].Channel }
        else {
            Write-Host ('Detected: ' + (($installed | ForEach-Object { $_.Channel }) -join ', '))
            $Channel = Read-Host 'Enter the Discord channel to clean, or press Enter to cancel'
            if (-not $Channel) { Write-Host 'Cancelled.'; return }
            if ($Channel -notin @($installed | ForEach-Object { $_.Channel })) { throw 'Select one of the detected channels. Nothing changed.' }
        }
    }

    $plan = Get-CachePlan -Channel $Channel
    Write-Host ('Discord: {0}' -f $plan.Channel)
    Write-Host ('Cache: {0}' -f $plan.Root)
    Write-Host ('Found: {0} files, {1:N2} MiB' -f $plan.FileCount, ($plan.LogicalBytes / 1MB))
    Write-Host 'Only HTTP cache files are removed. Settings and login data are excluded.'
    Write-Host 'Deleted cache cannot be restored. No permanent RAM or CPU saving is promised.'

    if ($DryRun -or $WhatIfPreference) {
        Write-Host ('Status: ' + $plan.Reason)
        Write-Host 'Preview only. Nothing will be deleted or logged.'
        return
    }
    if ($plan.FileCount -eq 0) { Write-Host 'Cache is already empty. Nothing to clean.'; return }
    if (-not $plan.Ready) {
        Write-Host ('Status: ' + $plan.Reason)
        if (-not (Request-DiscordClose -Channel $Channel -Confirm:$false)) { return }
        $plan = Get-CachePlan -Channel $Channel
        if (-not $plan.Ready) { throw $plan.Reason }
        Write-Host ('Updated cache: {0} files, {1:N2} MiB' -f $plan.FileCount, ($plan.LogicalBytes / 1MB))
        if ($plan.FileCount -eq 0) { Write-Host 'Cache is already empty. Nothing to clean.'; return }
    }
    if ((Read-Host 'Press Enter to permanently delete these cache files, or type anything to cancel') -cne '') {
        Write-Host 'Cancelled. No cache files were deleted.'
        return
    }

    $result = Invoke-CacheCleanup -Plan $plan -Confirm:$false
    Write-Host ('{0}: {1} files, {2:N2} MiB logical file size.' -f $result.Status, $result.DeletedFiles, ($result.DeletedLogicalBytes / 1MB))
    if ($result.JournalPath) { Write-Host ('Log: ' + $result.JournalPath) }
    if ($result.Status -notin @('Completed', 'NoOp')) { throw $result.Error }
    Write-Host 'Done. You can reopen Discord. Cache will be recreated as needed.'
}

try {
    Invoke-DiscordCacheCleaner -Channel $Channel -DryRun:$DryRun
} catch {
    Write-Host ('Stopped: ' + $_.Exception.Message) -ForegroundColor Red
    throw
} finally {
    if (-not $DryRun -and -not $WhatIfPreference) {
        $null = Read-Host 'Press Enter to exit'
    }
}
