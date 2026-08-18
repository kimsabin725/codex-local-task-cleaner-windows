param(
    [string[]]$Id,
    [switch]$List,
    [switch]$ShowAll,
    [switch]$Execute,
    [switch]$Yes,
    [switch]$RemoveWorkspaces,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$BackupRoot = (Join-Path $env:LOCALAPPDATA 'CodexTaskCleaner\Backups'),
    [switch]$SkipProcessCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:RemoveMarker = New-Object object
try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch { }

function Write-Heading([string]$Text) {
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===') -ForegroundColor Cyan
}

function Add-SqliteBridge {
    if ('CodexCleaner.SqliteNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CodexCleaner {
    public static class SqliteNative {
        private const int SQLITE_OK = 0;
        private const int SQLITE_ROW = 100;
        private const int SQLITE_DONE = 101;

        [DllImport("winsqlite3.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open16(string filename, out IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close_v2(IntPtr db);
        [DllImport("winsqlite3.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int bytes, out IntPtr stmt, IntPtr tail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_name16(IntPtr stmt, int index);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text16(IntPtr stmt, int index);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_errmsg16(IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);

        private static string Error(IntPtr db) {
            IntPtr ptr = sqlite3_errmsg16(db);
            return ptr == IntPtr.Zero ? "unknown SQLite error" : Marshal.PtrToStringUni(ptr);
        }

        private static IntPtr Open(string path) {
            IntPtr db;
            int rc = sqlite3_open16(path, out db);
            if (rc != SQLITE_OK) {
                string message = db == IntPtr.Zero ? "could not open database" : Error(db);
                if (db != IntPtr.Zero) sqlite3_close_v2(db);
                throw new InvalidOperationException(message);
            }
            sqlite3_busy_timeout(db, 5000);
            return db;
        }

        private static void Run(IntPtr db, string sql) {
            IntPtr stmt;
            int rc = sqlite3_prepare16_v2(db, sql, -1, out stmt, IntPtr.Zero);
            if (rc != SQLITE_OK) throw new InvalidOperationException(Error(db) + " SQL=" + sql);
            try {
                rc = sqlite3_step(stmt);
                if (rc != SQLITE_DONE && rc != SQLITE_ROW) throw new InvalidOperationException(Error(db) + " SQL=" + sql);
            } finally {
                sqlite3_finalize(stmt);
            }
        }

        public static List<Dictionary<string,string>> Query(string path, string sql) {
            IntPtr db = Open(path);
            try {
                IntPtr stmt;
                int rc = sqlite3_prepare16_v2(db, sql, -1, out stmt, IntPtr.Zero);
                if (rc != SQLITE_OK) throw new InvalidOperationException(Error(db) + " SQL=" + sql);
                try {
                    var result = new List<Dictionary<string,string>>();
                    int columns = sqlite3_column_count(stmt);
                    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
                        var row = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                        for (int i = 0; i < columns; i++) {
                            string name = Marshal.PtrToStringUni(sqlite3_column_name16(stmt, i));
                            IntPtr valuePtr = sqlite3_column_text16(stmt, i);
                            row[name] = valuePtr == IntPtr.Zero ? null : Marshal.PtrToStringUni(valuePtr);
                        }
                        result.Add(row);
                    }
                    if (rc != SQLITE_DONE) throw new InvalidOperationException(Error(db) + " SQL=" + sql);
                    return result;
                } finally {
                    sqlite3_finalize(stmt);
                }
            } finally {
                sqlite3_close_v2(db);
            }
        }

        public static void ExecuteBatch(string path, string[] statements) {
            IntPtr db = Open(path);
            try {
                Run(db, "BEGIN IMMEDIATE");
                try {
                    foreach (string sql in statements) Run(db, sql);
                    Run(db, "COMMIT");
                } catch {
                    try { Run(db, "ROLLBACK"); } catch { }
                    throw;
                }
            } finally {
                sqlite3_close_v2(db);
            }
        }
    }
}
'@
}

function Get-FullPath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ($PathValue.StartsWith('\\?\')) { $PathValue = $PathValue.Substring(4) }
    return [IO.Path]::GetFullPath($PathValue)
}

function Test-IsWithin([string]$Child, [string]$Parent) {
    $childFull = (Get-FullPath $Child).TrimEnd('\') + '\'
    $parentFull = (Get-FullPath $Parent).TrimEnd('\') + '\'
    return $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePath([string]$Base, [string]$PathValue) {
    $baseFull = (Get-FullPath $Base).TrimEnd('\') + '\'
    $pathFull = Get-FullPath $PathValue
    $baseUri = New-Object Uri($baseFull)
    $pathUri = New-Object Uri($pathFull)
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Quote-Sql([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Quote-Identifier([string]$Value) {
    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-TableColumns([string]$Database, [string]$Table) {
    $quoted = Quote-Identifier $Table
    return @([CodexCleaner.SqliteNative]::Query($Database, "PRAGMA table_info($quoted)") | ForEach-Object { $_['name'] })
}

function Get-ThreadTables([string]$Database) {
    $result = @()
    $tables = [CodexCleaner.SqliteNative]::Query($Database, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    foreach ($row in $tables) {
        $name = $row['name']
        if ($name -like 'sqlite_*' -or $name -eq '_sqlx_migrations') { continue }
        $columns = @(Get-TableColumns $Database $name)
        if ($columns -contains 'thread_id' -or $columns -contains 'parent_thread_id' -or $columns -contains 'child_thread_id' -or $name -eq 'threads') {
            $result += [pscustomobject]@{ Name = $name; Columns = $columns }
        }
    }
    return $result
}

function Assert-SupportedSchema([string]$StateDb) {
    if (-not (Test-Path -LiteralPath $StateDb -PathType Leaf)) { throw "Missing state database: $StateDb" }
    $tables = [CodexCleaner.SqliteNative]::Query($StateDb, "SELECT name FROM sqlite_master WHERE type='table'")
    if (-not ($tables | Where-Object { $_['name'] -eq 'threads' })) { throw 'Unsupported Codex schema: threads table is missing.' }
    $columns = @(Get-TableColumns $StateDb 'threads')
    foreach ($required in @('id','rollout_path','cwd')) {
        if ($columns -notcontains $required) { throw "Unsupported Codex schema: threads.$required is missing." }
    }
}

function Get-AllThreads([string]$StateDb) {
    $columns = @(Get-TableColumns $StateDb 'threads')
    $select = @('id','rollout_path','cwd')
    foreach ($optional in @('name','title','preview','first_user_message','archived','updated_at_ms','updated_at','created_at_ms','created_at','source','thread_source','agent_role')) {
        if ($columns -contains $optional) { $select += $optional }
    }
    $order = if ($columns -contains 'updated_at_ms') { 'updated_at_ms' } elseif ($columns -contains 'updated_at') { 'updated_at' } else { 'id' }
    $sql = 'SELECT ' + (($select | ForEach-Object { Quote-Identifier $_ }) -join ',') + ' FROM threads ORDER BY ' + (Quote-Identifier $order) + ' DESC'
    return @([CodexCleaner.SqliteNative]::Query($StateDb, $sql))
}

function Get-ThreadLabel($Row) {
    foreach ($key in @('name','title','preview','first_user_message')) {
        if ($Row.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($Row[$key])) {
            return ($Row[$key] -replace '\s+', ' ').Trim()
        }
    }
    return '(untitled)'
}

function Get-ThreadKind($Row) {
    $source = if ($Row.ContainsKey('source')) { [string]$Row['source'] } else { '' }
    $threadSource = if ($Row.ContainsKey('thread_source')) { [string]$Row['thread_source'] } else { '' }
    $label = Get-ThreadLabel $Row
    if ($threadSource -eq 'subagent' -or $source -match 'subagent') { return '하위작업' }
    if ($source -eq 'exec' -or $label -like "You are executing an authenticated owner's request*") { return '자동화' }
    return '일반대화'
}

function Get-ThreadUpdatedText($Row) {
    try {
        if ($Row.ContainsKey('updated_at_ms') -and $Row['updated_at_ms']) {
            return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Row['updated_at_ms']).LocalDateTime.ToString('MM-dd HH:mm')
        }
        if ($Row.ContainsKey('updated_at') -and $Row['updated_at']) {
            $seconds = [long]$Row['updated_at']
            if ($seconds -gt 100000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($seconds).LocalDateTime.ToString('MM-dd HH:mm') }
            return [DateTimeOffset]::FromUnixTimeSeconds($seconds).LocalDateTime.ToString('MM-dd HH:mm')
        }
    } catch { }
    return '-'
}

function Get-WorkspaceLabel($Row) {
    $workspace = Get-FullPath $Row['cwd']
    if (-not $workspace) { return '-' }
    $leaf = Split-Path -Leaf $workspace.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $workspace }
    return $leaf
}

function Show-Threads($Threads) {
    $rows = for ($i = 0; $i -lt $Threads.Count; $i++) {
        $thread = $Threads[$i]
        $label = Get-ThreadLabel $thread
        $folder = Get-WorkspaceLabel $thread
        $shortId = $thread['id'].Substring([Math]::Max(0, $thread['id'].Length - 8))
        [pscustomobject]@{
            No = $i + 1
            '종류' = Get-ThreadKind $thread
            '제목' = $label.Substring(0, [Math]::Min(38, $label.Length))
            '수정' = Get-ThreadUpdatedText $thread
            '폴더' = $folder.Substring(0, [Math]::Min(24, $folder.Length))
            'ID끝' = $shortId
        }
    }
    $rows | Format-Table -AutoSize
}

function Show-SelectedThreads($Threads) {
    for ($i = 0; $i -lt $Threads.Count; $i++) {
        $thread = $Threads[$i]
        Write-Host ('[' + ($i + 1) + '] ' + (Get-ThreadLabel $thread)) -ForegroundColor White
        Write-Host ('    종류: ' + (Get-ThreadKind $thread))
        Write-Host ('    ID:   ' + $thread['id'])
        Write-Host ('    폴더: ' + (Get-FullPath $thread['cwd']))
    }
}

function Get-DescendantIds([string]$StateDb, [string[]]$RootIds) {
    $tables = [CodexCleaner.SqliteNative]::Query($StateDb, "SELECT name FROM sqlite_master WHERE type='table' AND name='thread_spawn_edges'")
    if ($tables.Count -eq 0) { return @() }
    $edges = [CodexCleaner.SqliteNative]::Query($StateDb, 'SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges')
    $selected = @{}
    foreach ($threadId in $RootIds) { $selected[$threadId] = $true }
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($edge in $edges) {
            if ($selected.ContainsKey($edge['parent_thread_id']) -and -not $selected.ContainsKey($edge['child_thread_id'])) {
                $selected[$edge['child_thread_id']] = $true
                $changed = $true
            }
        }
    }
    return @($selected.Keys | Where-Object { $RootIds -notcontains $_ })
}

function Test-TextContainsId([string]$Text, [string[]]$Ids) {
    if ($null -eq $Text) { return $false }
    foreach ($threadId in $Ids) {
        if ($Text.IndexOf($threadId, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Remove-JsonReferences($Value, [string[]]$Ids) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if (Test-TextContainsId $Value $Ids) { return $script:RemoveMarker }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            if (Test-TextContainsId ([string]$key) $Ids) { continue }
            $next = Remove-JsonReferences $Value[$key] $Ids
            if (-not [object]::ReferenceEquals($next, $script:RemoveMarker)) { $clean[$key] = $next }
        }
        return $clean
    }
    if ($Value -is [pscustomobject]) {
        $clean = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            if (Test-TextContainsId $property.Name $Ids) { continue }
            $next = Remove-JsonReferences $property.Value $Ids
            if (-not [object]::ReferenceEquals($next, $script:RemoveMarker)) { $clean[$property.Name] = $next }
        }
        return $clean
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $clean = New-Object Collections.ArrayList
        foreach ($item in $Value) {
            $next = Remove-JsonReferences $item $Ids
            if (-not [object]::ReferenceEquals($next, $script:RemoveMarker)) { [void]$clean.Add($next) }
        }
        return ,$clean
    }
    return $Value
}

function Write-Utf8NoBom([string]$PathValue, [string]$Text) {
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($PathValue, $Text, $encoding)
}

function Write-AtomicText([string]$PathValue, [string]$Text) {
    $temp = $PathValue + '.cleaner-tmp-' + [Guid]::NewGuid().ToString('N')
    Write-Utf8NoBom $temp $Text
    Move-Item -LiteralPath $temp -Destination $PathValue -Force
}

function Clean-GlobalStateFiles([string]$CodexRoot, [string[]]$Ids) {
    $files = @(Get-ChildItem -LiteralPath $CodexRoot -Force -File | Where-Object {
        $_.Name -eq '.codex-global-state.json' -or
        $_.Name -eq '.codex-global-state.json.bak' -or
        $_.Name -like '..codex-global-state.json.tmp-*'
    })
    foreach ($file in $files) {
        $raw = Get-Content -LiteralPath $file.FullName -Raw
        if (-not (Test-TextContainsId $raw $Ids)) { continue }
        try {
            $parsed = $raw | ConvertFrom-Json
            $clean = Remove-JsonReferences $parsed $Ids
            Write-AtomicText $file.FullName ($clean | ConvertTo-Json -Depth 100 -Compress)
        } catch {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function Clean-SessionIndex([string]$PathValue, [string[]]$Ids) {
    if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) { return }
    $kept = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($PathValue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $remove = Test-TextContainsId $line $Ids
        if (-not $remove) { $kept.Add($line) }
    }
    $text = if ($kept.Count) { ($kept -join [Environment]::NewLine) + [Environment]::NewLine } else { '' }
    Write-AtomicText $PathValue $text
}

function Get-TargetItems([string]$CodexRoot, $Threads, [string[]]$Ids) {
    $items = New-Object Collections.Generic.List[string]
    foreach ($thread in $Threads) {
        $rollout = Get-FullPath $thread['rollout_path']
        if ($rollout -and (Test-Path -LiteralPath $rollout)) { $items.Add($rollout) }
    }
    foreach ($folderName in @('sessions','archived_sessions','thread-writer-locks')) {
        $folder = Join-Path $CodexRoot $folderName
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $folder -Recurse -Force -File -ErrorAction SilentlyContinue) {
            if (Test-TextContainsId $item.Name $Ids) { $items.Add($item.FullName) }
        }
    }
    $visualizations = Join-Path $CodexRoot 'visualizations'
    if (Test-Path -LiteralPath $visualizations) {
        foreach ($folder in Get-ChildItem -LiteralPath $visualizations -Recurse -Force -Directory -ErrorAction SilentlyContinue) {
            if ($Ids -contains $folder.Name) { $items.Add($folder.FullName) }
        }
    }
    return @($items | Select-Object -Unique)
}

function Get-CoreFiles([string]$CodexRoot) {
    $names = @(
        'state_5.sqlite','state_5.sqlite-wal','state_5.sqlite-shm',
        'logs_2.sqlite','logs_2.sqlite-wal','logs_2.sqlite-shm',
        'goals_1.sqlite','goals_1.sqlite-wal','goals_1.sqlite-shm',
        'memories_1.sqlite','memories_1.sqlite-wal','memories_1.sqlite-shm',
        'session_index.jsonl','version.json'
    )
    $files = @($names | ForEach-Object { Join-Path $CodexRoot $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    $files += @(Get-ChildItem -LiteralPath $CodexRoot -Force -File | Where-Object {
        $_.Name -eq '.codex-global-state.json' -or
        $_.Name -eq '.codex-global-state.json.bak' -or
        $_.Name -like '..codex-global-state.json.tmp-*'
    } | ForEach-Object { $_.FullName })
    return @($files | Select-Object -Unique)
}

function New-Backup([string]$CodexRoot, [string]$Root, [string[]]$Ids, $Threads, [string[]]$TargetItems) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $Root ('backup-' + $stamp + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,8)))
    $core = Join-Path $backup 'core'
    $payload = Join-Path $backup 'payload'
    New-Item -ItemType Directory -Path $core,$payload -Force | Out-Null
    $coreNames = @()
    foreach ($file in Get-CoreFiles $CodexRoot) {
        Copy-Item -LiteralPath $file -Destination (Join-Path $core ([IO.Path]::GetFileName($file))) -Force
        $coreNames += [IO.Path]::GetFileName($file)
    }
    $payloadRelative = @()
    foreach ($item in $TargetItems) {
        if (-not (Test-IsWithin $item $CodexRoot)) { throw "Refusing to back up path outside Codex home: $item" }
        $relative = Get-RelativePath $CodexRoot $item
        $destination = Join-Path $payload $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $item -Destination $destination -Recurse -Force
        $payloadRelative += $relative
    }
    $manifest = [ordered]@{
        createdAt = (Get-Date).ToString('o')
        codexHome = $CodexRoot
        ids = $Ids
        tasks = @($Threads | ForEach-Object { [ordered]@{ id = $_['id']; title = Get-ThreadLabel $_; cwd = $_['cwd']; rolloutPath = $_['rollout_path'] } })
        coreFiles = $coreNames
        payloadItems = $payloadRelative
    }
    Write-Utf8NoBom (Join-Path $backup 'manifest.json') ($manifest | ConvertTo-Json -Depth 10)
    return [pscustomobject]@{ Path = $backup; CoreNames = $coreNames; PayloadRelative = $payloadRelative }
}

function Restore-Backup([string]$CodexRoot, $Backup) {
    Write-Host 'Restoring backup...' -ForegroundColor Yellow
    foreach ($databaseName in @('state_5.sqlite','logs_2.sqlite','goals_1.sqlite','memories_1.sqlite')) {
        foreach ($suffix in @('','-wal','-shm')) {
            $current = Join-Path $CodexRoot ($databaseName + $suffix)
            if (Test-Path -LiteralPath $current) { Remove-Item -LiteralPath $current -Force }
        }
    }
    foreach ($name in $Backup.CoreNames) {
        $source = Join-Path (Join-Path $Backup.Path 'core') $name
        $destination = Join-Path $CodexRoot $name
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }
    foreach ($relative in $Backup.PayloadRelative) {
        $source = Join-Path (Join-Path $Backup.Path 'payload') $relative
        $destination = Join-Path $CodexRoot $relative
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
    }
}

function Remove-DatabaseRows([string]$Database, [string[]]$Ids) {
    if (-not (Test-Path -LiteralPath $Database -PathType Leaf)) { return }
    $idList = ($Ids | ForEach-Object { Quote-Sql $_ }) -join ','
    $statements = New-Object Collections.Generic.List[string]
    $tables = @(Get-ThreadTables $Database)
    foreach ($table in $tables | Where-Object { $_.Name -ne 'threads' }) {
        $conditions = @()
        foreach ($column in @('thread_id','parent_thread_id','child_thread_id')) {
            if ($table.Columns -contains $column) { $conditions += (Quote-Identifier $column) + " IN ($idList)" }
        }
        if ($conditions.Count) { $statements.Add('DELETE FROM ' + (Quote-Identifier $table.Name) + ' WHERE ' + ($conditions -join ' OR ')) }
    }
    if ($tables | Where-Object { $_.Name -eq 'threads' }) {
        $statements.Add("DELETE FROM threads WHERE id IN ($idList)")
    }
    if ($statements.Count) { [CodexCleaner.SqliteNative]::ExecuteBatch($Database, $statements.ToArray()) }
}

function Get-DatabaseReferenceCount([string]$Database, [string[]]$Ids) {
    if (-not (Test-Path -LiteralPath $Database -PathType Leaf)) { return 0 }
    $idList = ($Ids | ForEach-Object { Quote-Sql $_ }) -join ','
    $total = 0
    foreach ($table in Get-ThreadTables $Database) {
        $conditions = @()
        if ($table.Name -eq 'threads') { $conditions += "id IN ($idList)" }
        foreach ($column in @('thread_id','parent_thread_id','child_thread_id')) {
            if ($table.Columns -contains $column) { $conditions += (Quote-Identifier $column) + " IN ($idList)" }
        }
        if ($conditions.Count) {
            $row = [CodexCleaner.SqliteNative]::Query($Database, 'SELECT COUNT(*) AS n FROM ' + (Quote-Identifier $table.Name) + ' WHERE ' + ($conditions -join ' OR '))[0]
            $total += [int]$row['n']
        }
    }
    return $total
}

function Assert-NoReferences([string]$CodexRoot, [string[]]$Ids, [string[]]$TargetItems) {
    $databases = @('state_5.sqlite','logs_2.sqlite','goals_1.sqlite','memories_1.sqlite') | ForEach-Object { Join-Path $CodexRoot $_ }
    foreach ($database in $databases) {
        $count = Get-DatabaseReferenceCount $database $Ids
        if ($count -ne 0) { throw "Database references remain in $database ($count row(s))." }
    }
    foreach ($file in Get-CoreFiles $CodexRoot) {
        if ($file -like '*.json' -or $file -like '*.jsonl' -or $file -like '*.bak' -or $file -like '*tmp-*') {
            $raw = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
            if (Test-TextContainsId $raw $Ids) { throw "Target reference remains in $file" }
        }
    }
    foreach ($item in $TargetItems) {
        if (Test-Path -LiteralPath $item) { throw "Target file or folder remains: $item" }
    }
}

function Assert-AppClosed {
    if ($SkipProcessCheck) { return }
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ChatGPT|Codex)$' })
    if ($running.Count) { throw 'ChatGPT is still running. Quit the ChatGPT desktop app completely, including the system tray, and run this utility again.' }
}

function Find-AutomationReferences([string]$CodexRoot, [string[]]$Ids) {
    $folder = Join-Path $CodexRoot 'automations'
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    $hits = @()
    foreach ($file in Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue) {
        $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if (Test-TextContainsId $raw $Ids) { $hits += $file.FullName }
    }
    return @($hits | Select-Object -Unique)
}

function Test-ProtectedWorkspace([string]$Workspace, [string]$CodexRoot, [string]$BackupPath) {
    $full = Get-FullPath $Workspace
    $protected = @(
        [IO.Path]::GetPathRoot($full),
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        $CodexRoot,
        $PSScriptRoot,
        $BackupPath
    ) | Where-Object { $_ }
    foreach ($pathValue in $protected) {
        if ((Get-FullPath $pathValue).TrimEnd('\') -ieq $full.TrimEnd('\')) { return $true }
    }
    return $false
}

function Move-WorkspacesToRecycleBin([string[]]$Workspaces, $RemainingThreads, [string]$CodexRoot, [string]$BackupPath) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    foreach ($workspaceValue in $Workspaces | Select-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace($workspaceValue)) { continue }
        $workspace = Get-FullPath $workspaceValue
        if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { continue }
        if (Test-ProtectedWorkspace $workspace $CodexRoot $BackupPath) {
            Write-Warning "Protected workspace was not removed: $workspace"
            continue
        }
        $shared = @($RemainingThreads | Where-Object { $_['cwd'] -and ((Get-FullPath $_['cwd']) -ieq (Get-FullPath $workspace)) })
        if ($shared.Count) {
            Write-Warning "Workspace is shared by another task and was not removed: $workspace"
            continue
        }
        $automationHit = $false
        $automationFolder = Join-Path $CodexRoot 'automations'
        if (Test-Path -LiteralPath $automationFolder) {
            $workspaceVariants = @($workspaceValue, $workspace | Where-Object { $_ } | Select-Object -Unique)
            foreach ($file in Get-ChildItem -LiteralPath $automationFolder -Recurse -File -ErrorAction SilentlyContinue) {
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
                if (-not $raw) { continue }
                foreach ($workspaceVariant in $workspaceVariants) {
                    if ($raw.IndexOf($workspaceVariant, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $automationHit = $true
                        break
                    }
                }
                if ($automationHit) { break }
            }
        }
        if ($automationHit) {
            Write-Warning "Workspace is referenced by an automation and was not removed: $workspace"
            continue
        }
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $workspace,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
        Write-Host "Moved workspace to Recycle Bin: $workspace" -ForegroundColor Green
    }
}

try {
    Write-Host 'Codex 로컬 작업 정리 도구 for Windows 0.3.1' -ForegroundColor White
    Write-Host '비공식 도구입니다. 복구 백업을 만든 뒤 로컬 Codex 메타데이터를 정리합니다.' -ForegroundColor DarkGray
    Assert-AppClosed
    $CodexHome = Get-FullPath $CodexHome
    $BackupRoot = Get-FullPath $BackupRoot
    if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) { throw "Codex home was not found: $CodexHome" }
    Add-SqliteBridge
    $stateDb = Join-Path $CodexHome 'state_5.sqlite'
    Assert-SupportedSchema $stateDb
    $allThreads = @(Get-AllThreads $stateDb)
    $userThreads = @($allThreads | Where-Object { (Get-ThreadKind $_) -eq '일반대화' })
    $hiddenCount = $allThreads.Count - $userThreads.Count

    if ($List) {
        $listThreads = if ($ShowAll) { $allThreads } else { $userThreads }
        Write-Heading $(if ($ShowAll) { '전체 로컬 작업' } else { '사용자 대화' })
        Show-Threads $listThreads
        if (-not $ShowAll -and $hiddenCount -gt 0) {
            Write-Host "자동화·하위 작업 ${hiddenCount}개는 숨겼습니다. 전체 목록은 -List -ShowAll로 확인할 수 있습니다." -ForegroundColor DarkGray
        }
        exit 0
    }

    $interactive = -not $Id -or $Id.Count -eq 0
    if ($interactive) {
        $candidates = $userThreads
        $showingAll = $false
        while ($true) {
            Write-Heading $(if ($showingAll) { '전체 로컬 작업' } else { '사용자 대화' })
            Show-Threads $candidates
            Write-Host '목록의 번호는 이번 실행에서만 사용하는 임시 번호입니다.' -ForegroundColor Yellow
            if (-not $showingAll -and $hiddenCount -gt 0) {
                Write-Host "자동화·하위 작업 ${hiddenCount}개는 안전을 위해 숨겼습니다." -ForegroundColor DarkGray
                $selection = Read-Host '삭제할 번호(여러 개는 1,2), 전체 보기 A, 취소 Enter'
            } else {
                $selection = Read-Host '삭제할 번호(여러 개는 1,2), 취소 Enter'
            }
            if ([string]::IsNullOrWhiteSpace($selection)) {
                Write-Host '취소했습니다. 아무것도 변경하지 않았습니다.' -ForegroundColor Green
                exit 0
            }
            if (-not $showingAll -and $selection.Trim() -ieq 'A') {
                $candidates = $allThreads
                $showingAll = $true
                continue
            }
            break
        }
        $indexes = @($selection -split ',' | ForEach-Object { [int]$_.Trim() })
        $Id = @($indexes | ForEach-Object {
            if ($_ -lt 1 -or $_ -gt $candidates.Count) { throw "잘못된 작업 번호입니다: $_" }
            $candidates[$_ - 1]['id']
        })
    }

    foreach ($threadId in $Id) {
        if ($threadId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw "Invalid task ID: $threadId"
        }
    }
    $Id = @($Id | Select-Object -Unique)
    $descendants = @(Get-DescendantIds $stateDb $Id)
    if ($descendants.Count) { $Id = @($Id + $descendants | Select-Object -Unique) }
    $selected = @($allThreads | Where-Object { $Id -contains $_['id'] })
    $selectedIds = @($selected | ForEach-Object { $_['id'] })
    $missing = @($Id | Where-Object { $selectedIds -notcontains $_ })
    if ($missing.Count) { throw 'Task ID was not found: ' + ($missing -join ', ') }
    $automationHits = @(Find-AutomationReferences $CodexHome $Id)
    if ($automationHits.Count) { throw 'Selected task is referenced by an automation: ' + ($automationHits -join ', ') }
    $targetItems = @(Get-TargetItems $CodexHome $selected $Id)

    Write-Heading '최종 삭제 대상 확인'
    Show-SelectedThreads $selected
    $internalSelected = @($selected | Where-Object { (Get-ThreadKind $_) -ne '일반대화' })
    if ($internalSelected.Count) { Write-Warning "자동화 또는 하위 작업 $($internalSelected.Count)개가 포함되어 있습니다." }
    if ($descendants.Count) { Write-Warning ('연결된 하위 작업도 함께 제거됩니다: ' + ($descendants -join ', ')) }
    Write-Host "제거할 메타데이터·세션 항목: $($targetItems.Count)"
    Write-Host '전체 복구 백업 위치:'
    Write-Host $BackupRoot -ForegroundColor Yellow

    if ($interactive) {
        $workspaceChoice = Read-Host '선택한 작업의 전용 폴더도 휴지통으로 보낼까요? [y/N]'
        if ($workspaceChoice -match '^(y|yes)$') { $RemoveWorkspaces = $true }
        $confirmation = Read-Host '실제 삭제하려면 DELETE를 정확히 입력하세요. 그 외 입력은 미리보기로 종료합니다'
        if ($confirmation -ceq 'DELETE') { $Execute = $true }
    }
    if (-not $Execute) {
        Write-Host '미리보기 완료. 아무것도 변경하지 않았습니다.' -ForegroundColor Green
        exit 0
    }
    if (-not $Yes -and -not $interactive) {
        $confirmation = Read-Host 'Type DELETE to permanently remove the selected local task metadata'
        if ($confirmation -cne 'DELETE') { throw 'Confirmation was not entered. Nothing was changed.' }
    }

    Write-Heading 'Backup'
    $backup = New-Backup $CodexHome $BackupRoot $Id $selected $targetItems
    Write-Host "Recovery backup created: $($backup.Path)" -ForegroundColor Green

    try {
        Write-Heading 'Metadata cleanup'
        foreach ($name in @('logs_2.sqlite','goals_1.sqlite','memories_1.sqlite','state_5.sqlite')) {
            Remove-DatabaseRows (Join-Path $CodexHome $name) $Id
        }
        Clean-SessionIndex (Join-Path $CodexHome 'session_index.jsonl') $Id
        Clean-GlobalStateFiles $CodexHome $Id
        foreach ($item in $targetItems | Sort-Object Length -Descending) {
            if (-not (Test-IsWithin $item $CodexHome)) { throw "Refusing to remove path outside Codex home: $item" }
            if (Test-Path -LiteralPath $item) { Remove-Item -LiteralPath $item -Recurse -Force }
        }
        Assert-NoReferences $CodexHome $Id $targetItems
    } catch {
        $originalError = $_
        Restore-Backup $CodexHome $backup
        throw "Cleanup failed and the recovery backup was restored. Cause: $($originalError.Exception.Message)"
    }

    Write-Heading 'Verified'
    Write-Host "Deleted and verified $($Id.Count) local task(s)." -ForegroundColor Green
    Write-Host "Recovery backup kept at: $($backup.Path)" -ForegroundColor Yellow

    if ($RemoveWorkspaces) {
        $remaining = @($allThreads | Where-Object { $Id -notcontains $_['id'] })
        $workspaces = @($selected | ForEach-Object { $_['cwd'] } | Where-Object { $_ } | Select-Object -Unique)
        Move-WorkspacesToRecycleBin $workspaces $remaining $CodexHome $backup.Path
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    if ($env:CODEX_CLEANER_DEBUG -eq '1' -and $_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
