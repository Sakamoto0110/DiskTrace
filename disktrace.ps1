<#
.SYNOPSIS
    Pick drives and get offline HTML reports of how their files are laid out, take dated snapshots, and see what
    changed between them.

.DESCRIPTION
    DiskTrace 1.2.0 -- pure Windows PowerShell; no Python, no install.

    METADATA ONLY: DiskTrace NEVER opens files and NEVER reads file contents. It only lists directories and reads
    file system metadata (name, size, last-write date, attributes) through directory enumeration. Nothing on the
    scanned drive is changed.

    The scan is a small C# class compiled on the fly by Windows (Add-Type). Reparse points (junctions, symlinks)
    are listed but never followed. Pages are single self-contained HTML files that make no network request
    (Content-Security-Policy default-src 'none'). Running as administrator reads more protected system folders;
    it is not required.

    Snapshots are kept in %LOCALAPPDATA%\DiskTrace\snapshots, one folder per volume (identified by the volume, not
    by its letter). A summary snapshot keeps per-folder totals and files of 100 MB or more; a full snapshot (-Full)
    keeps the name, size and date of every file.

    The interface follows the Windows display language (pt-BR when Portuguese, English otherwise);
    -Language overrides it.

.EXAMPLE
    .\disktrace.ps1                              # arrow-key menu
.EXAMPLE
    .\disktrace.ps1 -Drive D -NoOpen             # report, no menu
.EXAMPLE
    .\disktrace.ps1 -Drive all -Snapshot -Full   # full snapshot of every fixed drive (for a scheduled task)
.EXAMPLE
    .\disktrace.ps1 -Analyze 30                  # what changed in the last 30 days, every drive with snapshots
.EXAMPLE
    .\disktrace.ps1 -Drive C:\Projects -UserProfile none -OutputDir C:\Reports -Language en
#>
param(
    [string]$OutputDir,
    [string[]]$Drive,               # skip the menu: drive letters (D, D:, C,D), all, or one folder (report only)
    [string]$UserProfile,           # skip profile detection; 'none' = do not list personal files
    [switch]$Snapshot,              # save a snapshot instead of a report; add -Report for both
    [switch]$Report,
    [switch]$Full,                  # full snapshot: name, size and date of every file
    [ValidateSet('', 'last', '7', '30', '90', '180', '360', 'all')][string]$Analyze = '',
    [string]$SnapshotDir,           # default: %LOCALAPPDATA%\DiskTrace\snapshots
    [int]$KeepFull = 0,             # keep only the newest N full snapshots per drive (older ones go to the Recycle Bin); 0 keeps all
    [ValidateSet('', 'en', 'pt-BR')][string]$Language = '',
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'
$Version = '1.2.0'

# ------------------------------------------------------------------------------------------------- strings
if (-not $Language) { $Language = if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'pt*') { 'pt-BR' } else { 'en' } }
$Culture = [Globalization.CultureInfo]::GetCultureInfo($(if ($Language -eq 'pt-BR') { 'pt-BR' } else { 'en-US' }))
$Strings = @{
    'en' = @{
        menuHint = '  Up/Down or W/S to move · Enter to choose · Esc to quit'
        mainHint = '  Up/Down or W/S to move · Left/Right or A/D to change the option · Enter to choose · Esc to quit'
        pickHint = '  Up/Down or W/S to move · Space to mark · Shift+Up/Down to mark several · Enter to confirm · Esc to quit'
        mainTitle = 'What do you want to do?'
        actReport = 'Build a report now'; actSnap = 'Take a snapshot'; actSnapReport = 'Take a snapshot and open the report'; actAnalyze = 'Analysis'
        modeSummary = 'summary'; modeFull = 'full: every file name'
        pLast = 'since the last snapshot'; pDays = 'last {0} days'; pAll = 'everything'
        pickDrive = 'Choose the drives:'; allDrives = 'All drives'; pickStored = 'Choose the drives to analyse:'
        storedItem = '{0}:  {1,-18} {2,3} snapshots · last {3}{4}'; offline = ' · not connected'
        noSnapshots = 'No snapshot yet: take one first.'; noDriveMatch = 'No drive matches "{0}".'
        pickProfile = 'This drive has more than one user profile. Which one should be used to list personal files?'
        noLabel = '(no label)'; free = 'free'; noDrives = 'No drive found.'
        scanning = 'Scanning {0} (metadata only: names, sizes and dates; file contents are never read)...'; foldersRead = '  {0} folders read'
        scanDone = 'Read in {0} s: {1} folders, {2} files; {3} folders could not be opened.'
        building = 'Building the page...'
        pageAt = 'Page: {0} ({1} MB)'; pressEnter = 'Press Enter to exit'; outDir = 'DiskTrace'
        snapSaved = 'Snapshot: {0} ({1} MB)'; snapFolder = 'Snapshots are taken of whole drives only; {0} is a folder.'
        fullWarn = 'Full mode: the snapshot keeps the name of every file on the drive (still metadata only, never contents). Keep it private.'
        recycled = 'Old full snapshot sent to the Recycle Bin: {0}'; badSnapshot = 'Skipped, not a readable snapshot: {0}'
        comparing = 'Comparing {0}: {1} -> {2}...'; analysisAt = 'Analysis: {0} ({1} MB)'
        titleDrive = 'Drive {0} - {1}'; titleFolder = 'Folder {0}'; driveWord = 'drive'
        generated = 'DiskTrace · generated {0} · {1}'; dateFmt = 'yyyy-MM-dd HH:mm'
        capacity = 'capacity'; used = 'used'; freeCard = 'free'; filesCounted = 'files counted'; folders = 'folders'; largest = 'largest: '
        help = 'Click a folder to open it; "smaller items" opens too. The bar compares the size with the parent folder; hover to see the full path. Files are listed one by one when they are 100 MB or larger or sit in personal folders. Reparse points (junctions, links) are shown but not followed. Metadata only (names, sizes and dates): no file was opened and no file content was read. {0} folders could not be opened (usually protected by Windows): they are listed at the top of the page and marked with 🔒 in the tree, and what is inside them is left out of the totals.'
        search = 'Search folder or file (Enter)'; collapse = 'Collapse all'
        unreadTitle = '🔒 Folders that could not be opened: {0}'
        unreadText = 'Listed here so nothing is hidden. DiskTrace could not list what is inside them, so their size is unknown and is not in the totals. Most are protected by Windows; running as administrator opens many of them. Click one to find it in the tree.'
        notSeen = 'used, not seen by the scan'; notSeenNeg = 'counted above the used space'
        notSeenHelp = ' The "not seen" card is the used space minus what the scan added up: folders that could not be opened, NTFS metadata and restore points. Hard links and compressed files are counted at full size, which makes that number smaller and can turn it negative.'
        js = @{ smaller = 'smaller items'; files = 'files'; none = 'Nothing found.'; link = 'shortcut'; locale = 'en-US'
               denied = 'no access'; deniedPart = 'partly read, then access denied'; error = 'could not be read'; errorPart = 'partly read, then failed'
               unknown = 'size unknown'; inside = '{0} folders without access inside' }
        aTitle = 'DiskTrace · Analysis: {0}'
        aRange = '{0} → {1} · {2} days apart · {3}'; aModeFull = 'file by file'; aModeSummary = 'folder by folder'
        aNeedTwo = 'This needs at least two snapshots of this drive; there is {0}.'
        aShort = 'The oldest snapshot is from {0} ({1} days ago), so this covers less than the chosen period.'
        aSummary = 'At least one of the two snapshots is a summary, so changes are shown per folder. Take full snapshots to see them file by file.'
        aAdmin = 'One snapshot was taken as administrator and the other was not, so protected folders can show up as changes.'
        aOmitted = '{0} smaller file changes are counted in the cards but not listed in the tree.'
        aUnread = 'Folders that could not be opened: {0} in the older snapshot, {1} in the newer one. What is inside them is not compared.'
        cUsed = 'used space'; cScanned = 'counted by the scan'; cDirsNew = 'new folders'; cDirsGone = 'removed folders'
        cFilesNew = 'new files'; cFilesGone = 'removed files'; cFilesChanged = 'changed files'; cFilesMoved = 'moved files'
        aHelp = 'Green grew, red shrank. Each row shows the change, the size before → after and the change in file count; folders that did not change are left out. Click a folder to open it, or a name in the lists to find it in the tree. Metadata only: no file was opened and no file content was read.'
        ajs = @{ smaller = 'smaller changes'; files = 'files'; none = 'Nothing found.'; locale = 'en-US'
                newD = 'new folder'; goneD = 'removed folder'; newF = 'new'; goneF = 'removed'; changedF = 'changed'
                movedIn = 'moved here from {0}'; movedOut = 'moved to {0}'
                unreadA = 'no access in the older snapshot'; unreadB = 'no access in the newer snapshot'
                grew = 'Grew the most'; shrank = 'Shrank the most'; nothing = 'Nothing.'; used = 'used space'; scanned = 'counted by the scan' }
    }
    'pt-BR' = @{
        menuHint = '  ↑/↓ ou W/S para mover · Enter para escolher · Esc para sair'
        mainHint = '  ↑/↓ ou W/S para mover · ←/→ ou A/D para trocar a opção · Enter para escolher · Esc para sair'
        pickHint = '  ↑/↓ ou W/S para mover · Espaço para marcar · Shift+↑/↓ para marcar vários · Enter para confirmar · Esc para sair'
        mainTitle = 'O que você quer fazer?'
        actReport = 'Gerar relatório agora'; actSnap = 'Tirar snapshot'; actSnapReport = 'Tirar snapshot e abrir relatório'; actAnalyze = 'Análise'
        modeSummary = 'resumido'; modeFull = 'completo: nome de todos os arquivos'
        pLast = 'desde o último snapshot'; pDays = 'últimos {0} dias'; pAll = 'tudo'
        pickDrive = 'Escolha os discos:'; allDrives = 'Todos os discos'; pickStored = 'Escolha os discos para analisar:'
        storedItem = '{0}:  {1,-18} {2,3} snapshots · último em {3}{4}'; offline = ' · desconectado'
        noSnapshots = 'Nenhum snapshot ainda: tire um primeiro.'; noDriveMatch = 'Nenhum disco corresponde a "{0}".'
        pickProfile = 'Esse disco tem mais de um perfil de usuário. Qual usar para listar os arquivos pessoais?'
        noLabel = '(sem nome)'; free = 'livres'; noDrives = 'Nenhum disco encontrado.'
        scanning = 'Varrendo {0} (só metadados: nomes, tamanhos e datas; o conteúdo dos arquivos nunca é lido)...'; foldersRead = '  {0} pastas lidas'
        scanDone = 'Lido em {0} s: {1} pastas, {2} arquivos; {3} pastas não puderam ser abertas.'
        building = 'Montando a página...'
        pageAt = 'Página: {0} ({1} MB)'; pressEnter = 'Enter para sair'; outDir = 'DiskTrace'
        snapSaved = 'Snapshot: {0} ({1} MB)'; snapFolder = 'Snapshots são só de discos inteiros; {0} é uma pasta.'
        fullWarn = 'Modo completo: o snapshot guarda o nome de todos os arquivos do disco (continua sendo só metadados, nunca conteúdo). Guarde-o com cuidado.'
        recycled = 'Snapshot completo antigo enviado para a Lixeira: {0}'; badSnapshot = 'Ignorado, não é um snapshot legível: {0}'
        comparing = 'Comparando {0}: {1} -> {2}...'; analysisAt = 'Análise: {0} ({1} MB)'
        titleDrive = 'Disco {0} - {1}'; titleFolder = 'Pasta {0}'; driveWord = 'disco'
        generated = 'DiskTrace · gerado em {0} · {1}'; dateFmt = 'dd/MM/yyyy HH:mm'
        capacity = 'capacidade'; used = 'usado'; freeCard = 'livre'; filesCounted = 'arquivos contados'; folders = 'pastas'; largest = 'maior: '
        help = 'Clique numa pasta para abrir; "itens menores" também abre. A barra compara o tamanho com a pasta de cima; passe o mouse para ver o caminho completo. Arquivos aparecem individualmente quando têm 100 MB ou mais ou estão nas pastas pessoais. Atalhos do sistema (junções, links) aparecem mas não são seguidos. Só metadados (nomes, tamanhos e datas): nenhum arquivo foi aberto e nenhum conteúdo foi lido. {0} pastas não puderam ser abertas (em geral protegidas pelo Windows): estão listadas no topo da página e marcadas com 🔒 na árvore, e o que há dentro delas fica de fora dos totais.'
        search = 'Buscar pasta ou arquivo (Enter)'; collapse = 'Recolher tudo'
        unreadTitle = '🔒 Pastas que não puderam ser abertas: {0}'
        unreadText = 'Listadas aqui para que nada fique escondido. O DiskTrace não conseguiu listar o que há dentro delas, então o tamanho é desconhecido e não entra nos totais. A maioria é protegida pelo Windows; rodar como administrador abre muitas delas. Clique numa para achá-la na árvore.'
        notSeen = 'usado e não visto pela varredura'; notSeenNeg = 'somado acima do espaço usado'
        notSeenHelp = ' O cartão "não visto" é o espaço usado menos o que a varredura somou: pastas que não abriram, metadados do NTFS e pontos de restauração. Hard links e arquivos comprimidos entram com o tamanho cheio, o que diminui esse número e pode deixá-lo negativo.'
        js = @{ smaller = 'itens menores'; files = 'arq.'; none = 'Nada encontrado.'; link = 'atalho'; locale = 'pt-BR'
               denied = 'sem acesso'; deniedPart = 'lida em parte, depois acesso negado'; error = 'não pôde ser lida'; errorPart = 'lida em parte, depois falhou'
               unknown = 'tamanho desconhecido'; inside = '{0} pastas sem acesso aqui dentro' }
        aTitle = 'DiskTrace · Análise: {0}'
        aRange = '{0} → {1} · {2} dias entre eles · {3}'; aModeFull = 'arquivo por arquivo'; aModeSummary = 'pasta por pasta'
        aNeedTwo = 'É preciso ter pelo menos dois snapshots deste disco; há {0}.'
        aShort = 'O snapshot mais antigo é de {0} ({1} dias atrás), então a análise cobre menos que o período escolhido.'
        aSummary = 'Pelo menos um dos dois snapshots é resumido, então as mudanças aparecem por pasta. Tire snapshots completos para vê-las arquivo por arquivo.'
        aAdmin = 'Um snapshot foi tirado como administrador e o outro não, então pastas protegidas podem aparecer como mudança.'
        aOmitted = '{0} mudanças menores em arquivos entram nos cartões, mas não aparecem na árvore.'
        aUnread = 'Pastas que não puderam ser abertas: {0} no snapshot mais antigo, {1} no mais novo. O que há dentro delas não é comparado.'
        cUsed = 'espaço usado'; cScanned = 'somado pela varredura'; cDirsNew = 'pastas novas'; cDirsGone = 'pastas removidas'
        cFilesNew = 'arquivos novos'; cFilesGone = 'arquivos removidos'; cFilesChanged = 'arquivos alterados'; cFilesMoved = 'arquivos movidos'
        aHelp = 'Verde cresceu, vermelho diminuiu. Cada linha mostra a mudança, o tamanho antes → depois e a mudança no número de arquivos; pastas que não mudaram ficam de fora. Clique numa pasta para abrir, ou num nome das listas para achá-lo na árvore. Só metadados: nenhum arquivo foi aberto e nenhum conteúdo foi lido.'
        ajs = @{ smaller = 'mudanças menores'; files = 'arq.'; none = 'Nada encontrado.'; locale = 'pt-BR'
                newD = 'pasta nova'; goneD = 'pasta removida'; newF = 'novo'; goneF = 'removido'; changedF = 'alterado'
                movedIn = 'movido para cá de {0}'; movedOut = 'movido para {0}'
                unreadA = 'sem acesso no snapshot mais antigo'; unreadB = 'sem acesso no snapshot mais novo'
                grew = 'O que mais cresceu'; shrank = 'O que mais diminuiu'; nothing = 'Nada.'; used = 'espaço usado'; scanned = 'somado pela varredura' }
    }
}
$T = $Strings[$Language]
if (-not $OutputDir) { $OutputDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) $T.outDir }
if (-not $SnapshotDir) { $SnapshotDir = Join-Path $env:LOCALAPPDATA 'DiskTrace\snapshots' }

# ------------------------------------------------------------------------------------------------- scanner (C#)
$cs = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text;

public class DiskTraceScanner
{
    public List<string> Names = new List<string>();
    public List<int> Parent = new List<int>();
    public List<long> OwnBytes = new List<long>();
    public List<int> OwnFiles = new List<int>();
    public List<long> Newest = new List<long>();
    public List<int> FileDir = new List<int>();
    public List<string> FileName = new List<string>();
    public List<long> FileSize = new List<long>();
    public List<long> FileTime = new List<long>();
    public List<int> LinkDir = new List<int>();
    public List<string> LinkName = new List<string>();
    public bool Full;                                  // keep every file below (for full snapshots)
    public List<int> AllDir = new List<int>();
    public List<string> AllName = new List<string>();
    public List<long> AllSize = new List<long>();
    public List<long> AllTime = new List<long>();
    public List<int> Unread = new List<int>();         // folders whose listing failed
    public List<byte> UnreadWhy = new List<byte>();    // 0 access denied, 1 other error
    public List<bool> UnreadPart = new List<bool>();   // true when some entries were read before the failure
    public int Errors;                                 // folders that could not be read (= Unread.Count)
    public int EntryErrors;                            // entries whose size or attributes could not be read
    public string Root;
    public long TotalBytes;
    public long TotalFiles;

    const long BigFile = 100L * 1024 * 1024;
    const int TopFiles = 15;
    static readonly HashSet<string> NoList = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "appdata", ".cache", ".git", "node_modules", ".vs", "obj", "bin", "__pycache__", ".nuget", ".gradle" };

    static string Long(string p) { return p.StartsWith(@"\\?\") ? p : @"\\?\" + p; }
    static string Short(string p) { return p.StartsWith(@"\\?\") ? p.Substring(4) : p; }

    struct Item { public long Size; public string Name; public long Time; }

    // Walk `root` without following reparse points. Inside `profile` (outside AppData, caches and build output)
    // the 15 largest files of each folder are kept; anywhere else only files of 100 MB or more.
    public static DiskTraceScanner Run(string root, string profile, bool full, Action<int> progress)
    {
        var s = new DiskTraceScanner();
        s.Full = full;
        root = root.TrimEnd('\\') + "\\";
        s.Root = root.TrimEnd('\\');
        string prof = string.IsNullOrEmpty(profile) || profile == "none" ? null : profile.TrimEnd('\\').ToLowerInvariant();
        s.Names.Add(s.Root); s.Parent.Add(-1); s.OwnBytes.Add(0); s.OwnFiles.Add(0); s.Newest.Add(0);
        var stack = new Stack<KeyValuePair<int, string>>();
        var listable = new HashSet<int>();
        stack.Push(new KeyValuePair<int, string>(0, Long(root)));
        int seen = 0;
        while (stack.Count > 0)
        {
            var cur = stack.Pop();
            int idx = cur.Key;
            bool list = listable.Contains(idx);
            var top = new List<Item>();
            int got = 0;
            try
            {
                foreach (var e in new DirectoryInfo(cur.Value).EnumerateFileSystemInfos())
                {
                    got++;
                    FileAttributes at;
                    try { at = e.Attributes; } catch { s.EntryErrors++; continue; }
                    if ((at & FileAttributes.ReparsePoint) != 0)
                    {
                        s.LinkDir.Add(idx); s.LinkName.Add(e.Name);
                        continue;
                    }
                    if ((at & FileAttributes.Directory) != 0)
                    {
                        int child = s.Names.Count;
                        s.Names.Add(e.Name); s.Parent.Add(idx); s.OwnBytes.Add(0); s.OwnFiles.Add(0); s.Newest.Add(0);
                        if (prof != null)
                        {
                            string pl = Short(e.FullName).ToLowerInvariant();
                            if (pl == prof || pl.StartsWith(prof + "\\"))
                            {
                                bool ok = true;
                                foreach (var part in pl.Substring(prof.Length).Split('\\'))
                                    if (NoList.Contains(part)) { ok = false; break; }
                                if (ok) listable.Add(child);
                            }
                        }
                        stack.Push(new KeyValuePair<int, string>(child, e.FullName));
                        continue;
                    }
                    var f = (FileInfo)e;
                    long size, t;
                    try { size = f.Length; t = f.LastWriteTimeUtc.Ticks; } catch { s.EntryErrors++; continue; }
                    s.OwnFiles[idx]++; s.OwnBytes[idx] += size;
                    if (s.Full) { s.AllDir.Add(idx); s.AllName.Add(e.Name); s.AllSize.Add(size); s.AllTime.Add(t); }
                    if (t > s.Newest[idx]) s.Newest[idx] = t;
                    if (size >= BigFile) { s.FileDir.Add(idx); s.FileName.Add(e.Name); s.FileSize.Add(size); s.FileTime.Add(t); }
                    else if (list)
                    {
                        top.Add(new Item { Size = size, Name = e.Name, Time = t });
                        if (top.Count > 4 * TopFiles) { top.Sort((a, b) => b.Size.CompareTo(a.Size)); top.RemoveRange(TopFiles, top.Count - TopFiles); }
                    }
                }
            }
            catch (Exception ex)
            {
                s.Errors++;
                s.Unread.Add(idx); s.UnreadWhy.Add((byte)(ex is UnauthorizedAccessException ? 0 : 1)); s.UnreadPart.Add(got > 0);
            }
            if (top.Count > 0)
            {
                top.Sort((a, b) => b.Size.CompareTo(a.Size));
                for (int i = 0; i < top.Count && i < TopFiles; i++)
                { s.FileDir.Add(idx); s.FileName.Add(top[i].Name); s.FileSize.Add(top[i].Size); s.FileTime.Add(top[i].Time); }
            }
            seen++;
            if (progress != null && seen % 20000 == 0) progress(seen);
        }
        return s;
    }

    // ------------------------------------------------------------------------------------------- folder notes
    // key -> { English, Portuguese }
    static readonly Dictionary<string, string[]> Notes = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase) {
        { "windows", new[] { "Windows operating system", "Sistema operacional Windows" } },
        { "program files", new[] { "Installed programs (64-bit)", "Programas instalados (64 bits)" } },
        { "program files (x86)", new[] { "Installed programs (32-bit)", "Programas instalados (32 bits)" } },
        { "programdata", new[] { "Program data shared by all users (hidden)", "Dados de programas compartilhados entre usuários (oculto)" } },
        { "$recycle.bin", new[] { "Recycle Bin", "Lixeira" } },
        { "system volume information", new[] { "Windows restore points and indexes", "Pontos de restauração e índices do Windows" } },
        { "recovery", new[] { "Windows recovery", "Recuperação do Windows" } },
        { "users", new[] { "User profiles", "Perfis de usuário" } },
        { "users\\public", new[] { "Public folder shared by all users", "Pasta pública, compartilhada entre usuários" } },
        { "users\\default", new[] { "Template for new profiles", "Modelo usado para criar novos perfis" } },
        { "riot games", new[] { "Riot games", "Jogos da Riot" } },
        { "xboxgames", new[] { "Xbox app games", "Jogos do app Xbox" } },
        { "steamlibrary", new[] { "Steam game library", "Biblioteca de jogos da Steam" } },
        { "program files (x86)\\steam", new[] { "Steam", "Steam" } },
        { "program files (x86)\\steam\\steamapps", new[] { "Games installed by Steam", "Jogos instalados pela Steam" } },
        { "games", new[] { "Installed games", "Jogos instalados" } },
        { "gog games", new[] { "GOG games", "Jogos da GOG" } } };
    static readonly Dictionary<string, string[]> ProfileNotes = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase) {
        { "", new[] { "User profile", "Perfil de usuário" } },
        { "appdata", new[] { "Program data and settings (hidden)", "Dados e configurações dos programas (oculto)" } },
        { "appdata\\local", new[] { "Local program data (caches, databases, Store apps)", "Dados locais dos programas (caches, bancos, apps da loja)" } },
        { "appdata\\local\\packages", new[] { "Store (MSIX) app data, each in its own private folder", "Dados dos apps da loja (MSIX), cada um na sua pasta privada" } },
        { "appdata\\local\\temp", new[] { "Temporary files", "Arquivos temporários" } },
        { "appdata\\roaming", new[] { "Program settings", "Configurações dos programas" } },
        { "appdata\\locallow", new[] { "Low-integrity program data (many games)", "Dados de programas com permissão reduzida (muitos jogos)" } },
        { ".cache", new[] { "Tool caches", "Caches de ferramentas" } },
        { ".local", new[] { "Per-user installed tools", "Ferramentas instaladas por usuário" } },
        { "documents", new[] { "Documents", "Documentos" } },
        { "documents\\my games", new[] { "Game saves and settings", "Saves e configurações de jogos" } },
        { "downloads", new[] { "Downloads", "Downloads" } },
        { "desktop", new[] { "Desktop", "Área de trabalho" } },
        { "pictures", new[] { "Pictures", "Imagens" } },
        { "music", new[] { "Music", "Músicas" } },
        { "videos", new[] { "Videos", "Vídeos" } },
        { "saved games", new[] { "Game saves", "Saves de jogos" } },
        { "onedrive", new[] { "OneDrive", "OneDrive" } } };
    static readonly Dictionary<string, string[]> FileNotes = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase) {
        { "pagefile.sys", new[] { "Windows virtual memory", "Memória virtual do Windows" } },
        { "hiberfil.sys", new[] { "Hibernation / fast startup", "Hibernação / inicialização rápida" } },
        { "swapfile.sys", new[] { "Virtual memory for Store apps", "Memória virtual dos apps da loja" } } };
    static readonly string[] RootNote = { "Drive root", "Raiz do disco" };
    static readonly string[] LinkNote = { "system shortcut (not followed)", "atalho do sistema (não seguido)" };

    public static void Str(StringBuilder sb, string v)
    {
        sb.Append('"');
        foreach (char c in v)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '<': sb.Append("\\u003c"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20 || c == '\u2028' || c == '\u2029') sb.Append("\\u").Append(((int)c).ToString("x4"));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    static string Day(long ticks)
    {
        return ticks > 0 ? new DateTime(ticks, DateTimeKind.Utc).ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : "";
    }

    public long[] SubBytes, SubFiles, SubDirs, SubNewest;
    public int[] Flag, SubUnread;   // Flag: 0 read, 1 access denied, 2 denied after a partial read, 3 other error, 4 error after a partial read
    public string[] Paths;

    public void Aggregate()
    {
        int n = Names.Count;
        SubBytes = new long[n]; SubFiles = new long[n]; SubDirs = new long[n]; SubNewest = new long[n]; Paths = new string[n];
        Flag = new int[n]; SubUnread = new int[n];
        for (int u = 0; u < Unread.Count; u++) { Flag[Unread[u]] = 1 + 2 * UnreadWhy[u] + (UnreadPart[u] ? 1 : 0); SubUnread[Unread[u]] = 1; }
        for (int i = 0; i < n; i++) { SubBytes[i] = OwnBytes[i]; SubFiles[i] = OwnFiles[i]; SubNewest[i] = Newest[i]; }
        for (int i = n - 1; i > 0; i--)   // a child always has a larger index than its parent
        {
            int p = Parent[i];
            SubBytes[p] += SubBytes[i]; SubFiles[p] += SubFiles[i]; SubDirs[p] += 1 + SubDirs[i]; SubUnread[p] += SubUnread[i];
            if (SubNewest[i] > SubNewest[p]) SubNewest[p] = SubNewest[i];
        }
        Paths[0] = "";
        for (int i = 1; i < n; i++) Paths[i] = Paths[Parent[i]].Length > 0 ? Paths[Parent[i]] + "\\" + Names[i] : Names[i];
        TotalBytes = SubBytes[0]; TotalFiles = SubFiles[0];
    }

    string NoteFor(int i, string profRel, int lang)
    {
        if (i == 0) return RootNote[lang];
        string p = Paths[i].ToLowerInvariant();
        string[] v;
        if (!string.IsNullOrEmpty(profRel) && (p == profRel || p.StartsWith(profRel + "\\")))
        {
            if (ProfileNotes.TryGetValue(p.Substring(profRel.Length).TrimStart('\\'), out v)) return v[lang];
        }
        return Notes.TryGetValue(p, out v) ? v[lang] : "";
    }

    // nodes: [id, parent, name, kind, bytes, files, subdirs, newest, note, ownBytes, ownFiles, flag, unreadBelow]
    // kind d=folder f=file l=link; flag and unreadBelow only on folders (see Flag, SubUnread)
    public string NodesJson(string profRel, int lang)
    {
        profRel = (profRel ?? "").TrimEnd('\\').ToLowerInvariant();
        var sb = new StringBuilder(Names.Count * 90);
        sb.Append('[');
        int n = Names.Count;
        for (int i = 0; i < n; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append('[').Append(i).Append(',').Append(Parent[i]).Append(',');
            Str(sb, Names[i]); sb.Append(",\"d\",").Append(SubBytes[i]).Append(',').Append(SubFiles[i]).Append(',').Append(SubDirs[i]).Append(',');
            Str(sb, Day(SubNewest[i])); sb.Append(','); Str(sb, NoteFor(i, profRel, lang));
            sb.Append(',').Append(OwnBytes[i]).Append(',').Append(OwnFiles[i]).Append(',').Append(Flag[i]).Append(',').Append(SubUnread[i]).Append(']');
        }
        int id = n;
        for (int j = 0; j < FileDir.Count; j++, id++)
        {
            sb.Append(",[").Append(id).Append(',').Append(FileDir[j]).Append(',');
            Str(sb, FileName[j]); sb.Append(",\"f\",").Append(FileSize[j]).Append(",1,0,");
            Str(sb, Day(FileTime[j])); sb.Append(',');
            string[] fn; Str(sb, FileDir[j] == 0 && FileNotes.TryGetValue(FileName[j], out fn) ? fn[lang] : "");
            sb.Append(",0,0]");
        }
        for (int j = 0; j < LinkDir.Count; j++, id++)
        {
            sb.Append(",[").Append(id).Append(',').Append(LinkDir[j]).Append(',');
            Str(sb, LinkName[j]); sb.Append(",\"l\",0,0,0,\"\","); Str(sb, LinkNote[lang]); sb.Append(",0,0]");
        }
        sb.Append(']');
        return sb.ToString();
    }

    public string[] TopChildren(int count)
    {
        var kids = new List<int>();
        for (int i = 1; i < Names.Count; i++) if (Parent[i] == 0) kids.Add(i);
        kids.Sort((a, b) => SubBytes[b].CompareTo(SubBytes[a]));
        var r = new List<string>();
        for (int k = 0; k < kids.Count && k < count; k++) r.Add(Names[kids[k]] + "|" + SubBytes[kids[k]]);
        return r.ToArray();
    }

    // ------------------------------------------------------------------------------------------- snapshot file
    // gzip, UTF-8, one record per line, tab-separated:
    //   DiskTraceSnapshot<TAB>1
    //   <header JSON>
    //   D  parent  name  ownBytes  ownFiles  newestTicks  flag     (index = line order; a parent comes before its children)
    //   F  dir     name  size      lastWriteTicks                  (summary: files of 100 MB or more; full: every file)
    //   END
    public const string Magic = "DiskTraceSnapshot\t1";

    public static string Esc(string v)
    {
        if (v.IndexOfAny(new[] { '\\', '\t', '\n', '\r' }) < 0) return v;
        return v.Replace("\\", "\\\\").Replace("\t", "\\t").Replace("\n", "\\n").Replace("\r", "\\r");
    }

    public static string Unesc(string v)
    {
        if (v.IndexOf('\\') < 0) return v;
        var sb = new StringBuilder(v.Length);
        for (int i = 0; i < v.Length; i++)
        {
            char c = v[i];
            if (c == '\\' && i + 1 < v.Length)
            {
                char n = v[++i];
                sb.Append(n == 't' ? '\t' : n == 'n' ? '\n' : n == 'r' ? '\r' : n);
            }
            else sb.Append(c);
        }
        return sb.ToString();
    }

    public void WriteSnapshot(string path, string header)
    {
        string tmp = path + ".part";
        var inv = CultureInfo.InvariantCulture;
        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write))
        using (var gz = new GZipStream(fs, CompressionLevel.Optimal))
        using (var w = new StreamWriter(gz, new UTF8Encoding(false), 1 << 16))
        {
            w.NewLine = "\n";
            w.WriteLine(Magic);
            w.WriteLine(header);
            for (int i = 0; i < Names.Count; i++)
                w.WriteLine("D\t" + Parent[i].ToString(inv) + "\t" + Esc(Names[i]) + "\t" + OwnBytes[i].ToString(inv) + "\t" +
                            OwnFiles[i].ToString(inv) + "\t" + Newest[i].ToString(inv) + "\t" + Flag[i].ToString(inv));
            if (Full)
                for (int j = 0; j < AllDir.Count; j++)
                    w.WriteLine("F\t" + AllDir[j].ToString(inv) + "\t" + Esc(AllName[j]) + "\t" + AllSize[j].ToString(inv) + "\t" + AllTime[j].ToString(inv));
            else
                for (int j = 0; j < FileDir.Count; j++)
                    if (FileSize[j] >= BigFile)
                        w.WriteLine("F\t" + FileDir[j].ToString(inv) + "\t" + Esc(FileName[j]) + "\t" + FileSize[j].ToString(inv) + "\t" + FileTime[j].ToString(inv));
            w.WriteLine("END");
        }
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }
}

public class DiskTraceSnapshot
{
    public string Header;
    public List<int> Parent = new List<int>();
    public List<string> Name = new List<string>();
    public List<long> OwnBytes = new List<long>();
    public List<long> OwnFiles = new List<long>();
    public List<int> Flag = new List<int>();
    public List<int> FDir = new List<int>();
    public List<string> FName = new List<string>();
    public List<long> FSize = new List<long>();
    public List<long> FTime = new List<long>();
    public long[] SubBytes, SubFiles;

    static StreamReader Open(string path)
    {
        var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return new StreamReader(new GZipStream(fs, CompressionMode.Decompress), new UTF8Encoding(false), false, 1 << 16);
    }

    public static string ReadHeader(string path)
    {
        using (var r = Open(path))
        {
            if (r.ReadLine() != DiskTraceScanner.Magic) throw new InvalidDataException("not a DiskTrace snapshot: " + path);
            return r.ReadLine();
        }
    }

    // files=false skips the F records (folder-level comparison only)
    public static DiskTraceSnapshot Load(string path, bool files)
    {
        var s = new DiskTraceSnapshot();
        var inv = CultureInfo.InvariantCulture;
        bool end = false;
        using (var r = Open(path))
        {
            if (r.ReadLine() != DiskTraceScanner.Magic) throw new InvalidDataException("not a DiskTrace snapshot: " + path);
            s.Header = r.ReadLine();
            string line;
            while ((line = r.ReadLine()) != null)
            {
                if (line == "END") { end = true; break; }
                if (line.StartsWith("D\t"))
                {
                    var p = line.Split('\t');
                    s.Parent.Add(int.Parse(p[1], inv)); s.Name.Add(DiskTraceScanner.Unesc(p[2])); s.OwnBytes.Add(long.Parse(p[3], inv));
                    s.OwnFiles.Add(long.Parse(p[4], inv)); s.Flag.Add(int.Parse(p[6], inv));
                }
                else if (files && line.StartsWith("F\t"))
                {
                    var p = line.Split('\t');
                    s.FDir.Add(int.Parse(p[1], inv)); s.FName.Add(DiskTraceScanner.Unesc(p[2])); s.FSize.Add(long.Parse(p[3], inv)); s.FTime.Add(long.Parse(p[4], inv));
                }
            }
        }
        if (!end) throw new InvalidDataException("incomplete snapshot: " + path);
        int n = s.Name.Count;
        s.SubBytes = new long[n]; s.SubFiles = new long[n];
        for (int i = 0; i < n; i++) { s.SubBytes[i] = s.OwnBytes[i]; s.SubFiles[i] = s.OwnFiles[i]; }
        for (int i = n - 1; i > 0; i--) { s.SubBytes[s.Parent[i]] += s.SubBytes[i]; s.SubFiles[s.Parent[i]] += s.SubFiles[i]; }
        return s;
    }
}

// Compares two snapshots of the same volume. Folders are matched by path (case-insensitive); with files=true
// (two full snapshots) files are compared too, and a file that disappeared and reappeared elsewhere with the
// same name, size and date is reported as moved.
public class DiskTraceDelta
{
    public string Json;
    public int DirsNew, DirsGone, FilesNew, FilesGone, FilesChanged, FilesMoved, Omitted;
    public long BytesNew, BytesGone, BytesChanged, BytesMoved;

    // kind: 1 new, 2 removed, 3 changed, 4 moved here, 5 moved away
    struct Change { public int Kind, Dir; public string Name, Note; public long SizeA, SizeB; }

    static string[] Keys(DiskTraceSnapshot s)
    {
        var k = new string[s.Name.Count];
        k[0] = "";
        for (int i = 1; i < k.Length; i++)
        {
            string nm = s.Name[i].ToLowerInvariant(), p = k[s.Parent[i]];
            k[i] = p.Length > 0 ? p + "\\" + nm : nm;
        }
        return k;
    }

    public static DiskTraceDelta Build(DiskTraceSnapshot a, DiskTraceSnapshot b, bool files, int maxFiles)
    {
        var d = new DiskTraceDelta();
        // union of both folder trees; a parent always gets a smaller index than its children
        var up = new List<int>(); var un = new List<string>(); var ua = new List<int>(); var ub = new List<int>();
        var map = new Dictionary<string, int>(StringComparer.Ordinal);
        string[] kb = Keys(b), ka = Keys(a);
        int[] bu = new int[kb.Length], au = new int[ka.Length];
        for (int i = 0; i < kb.Length; i++)
        {
            int u = up.Count; bu[i] = u;
            up.Add(i == 0 ? -1 : bu[b.Parent[i]]); un.Add(b.Name[i]); ua.Add(-1); ub.Add(i);
            map[kb[i]] = u;
        }
        for (int i = 0; i < ka.Length; i++)
        {
            int u;
            if (map.TryGetValue(ka[i], out u) && ua[u] < 0) { ua[u] = i; au[i] = u; continue; }
            u = up.Count; au[i] = u;
            up.Add(i == 0 ? -1 : au[a.Parent[i]]); un.Add(a.Name[i]); ua.Add(i); ub.Add(-1);
        }
        int n = up.Count;
        var bA = new long[n]; var bB = new long[n]; var fA = new long[n]; var fB = new long[n]; var own = new long[n];
        var keep = new bool[n];
        for (int u = 0; u < n; u++)
        {
            if (ua[u] >= 0) { bA[u] = a.SubBytes[ua[u]]; fA[u] = a.SubFiles[ua[u]]; own[u] -= a.OwnBytes[ua[u]]; }
            if (ub[u] >= 0) { bB[u] = b.SubBytes[ub[u]]; fB[u] = b.SubFiles[ub[u]]; own[u] += b.OwnBytes[ub[u]]; }
            if (ua[u] < 0) d.DirsNew++;
            if (ub[u] < 0) d.DirsGone++;
            keep[u] = u == 0 || bA[u] != bB[u] || fA[u] != fB[u] || ua[u] < 0 || ub[u] < 0;
        }

        Func<int, string> path = u =>
        {
            var parts = new List<string>();
            for (int x = u; x >= 0; x = up[x]) parts.Add(un[x]);
            parts.Reverse();
            return string.Join("\\", parts);
        };

        var changes = new List<Change>();
        if (files)
        {
            int[] fa = new int[a.FDir.Count], fb = new int[b.FDir.Count];
            for (int j = 0; j < fa.Length; j++) fa[j] = j;
            for (int j = 0; j < fb.Length; j++) fb[j] = j;
            Array.Sort(fa, (x, y) => { int c = au[a.FDir[x]].CompareTo(au[a.FDir[y]]); return c != 0 ? c : string.Compare(a.FName[x], a.FName[y], StringComparison.OrdinalIgnoreCase); });
            Array.Sort(fb, (x, y) => { int c = bu[b.FDir[x]].CompareTo(bu[b.FDir[y]]); return c != 0 ? c : string.Compare(b.FName[x], b.FName[y], StringComparison.OrdinalIgnoreCase); });
            var gone = new List<int>(); var added = new List<int>();
            int p = 0, q = 0;
            while (p < fa.Length || q < fb.Length)
            {
                int c;
                if (p >= fa.Length) c = 1;
                else if (q >= fb.Length) c = -1;
                else
                {
                    c = au[a.FDir[fa[p]]].CompareTo(bu[b.FDir[fb[q]]]);
                    if (c == 0) c = string.Compare(a.FName[fa[p]], b.FName[fb[q]], StringComparison.OrdinalIgnoreCase);
                }
                if (c == 0)
                {
                    int x = fa[p++], y = fb[q++];
                    if (a.FSize[x] != b.FSize[y] || a.FTime[x] != b.FTime[y])
                    {
                        changes.Add(new Change { Kind = 3, Dir = bu[b.FDir[y]], Name = b.FName[y], SizeA = a.FSize[x], SizeB = b.FSize[y] });
                        d.FilesChanged++; d.BytesChanged += b.FSize[y] - a.FSize[x];
                    }
                }
                else if (c < 0) gone.Add(fa[p++]);
                else added.Add(fb[q++]);
            }
            var pool = new Dictionary<string, List<int>>(StringComparer.Ordinal);
            foreach (int x in gone)
            {
                string k = a.FName[x].ToLowerInvariant() + "|" + a.FSize[x] + "|" + a.FTime[x];
                List<int> l;
                if (!pool.TryGetValue(k, out l)) { l = new List<int>(); pool[k] = l; }
                l.Add(x);
            }
            var moved = new HashSet<int>();
            foreach (int y in added)
            {
                string k = b.FName[y].ToLowerInvariant() + "|" + b.FSize[y] + "|" + b.FTime[y];
                List<int> l;
                if (pool.TryGetValue(k, out l) && l.Count > 0)
                {
                    int x = l[l.Count - 1]; l.RemoveAt(l.Count - 1); moved.Add(x);
                    int ud = bu[b.FDir[y]], uo = au[a.FDir[x]];
                    changes.Add(new Change { Kind = 4, Dir = ud, Name = b.FName[y], SizeB = b.FSize[y], Note = path(uo) + "\\" + a.FName[x] });
                    changes.Add(new Change { Kind = 5, Dir = uo, Name = a.FName[x], SizeA = a.FSize[x], Note = path(ud) + "\\" + b.FName[y] });
                    d.FilesMoved++; d.BytesMoved += b.FSize[y];
                }
                else
                {
                    changes.Add(new Change { Kind = 1, Dir = bu[b.FDir[y]], Name = b.FName[y], SizeB = b.FSize[y] });
                    d.FilesNew++; d.BytesNew += b.FSize[y];
                }
            }
            foreach (int x in gone)
                if (!moved.Contains(x))
                {
                    changes.Add(new Change { Kind = 2, Dir = au[a.FDir[x]], Name = a.FName[x], SizeA = a.FSize[x] });
                    d.FilesGone++; d.BytesGone += a.FSize[x];
                }
            if (changes.Count > maxFiles)
            {
                changes.Sort((x, y) => Math.Max(y.SizeA, y.SizeB).CompareTo(Math.Max(x.SizeA, x.SizeB)));
                d.Omitted = changes.Count - maxFiles;
                changes.RemoveRange(maxFiles, changes.Count - maxFiles);
            }
            foreach (var c in changes) keep[c.Dir] = true;
        }
        for (int u = n - 1; u > 0; u--) if (keep[u]) keep[up[u]] = true;

        // nodes: [id, parent, name, kind, bytesA, bytesB, filesA, filesB, status, flagA, flagB, note]
        var id = new int[n];
        int next = 0;
        for (int u = 0; u < n; u++) id[u] = keep[u] ? next++ : -1;
        var sb = new StringBuilder(next * 80 + changes.Count * 90);
        sb.Append("{\"nodes\":[");
        bool first = true;
        for (int u = 0; u < n; u++)
        {
            if (!keep[u]) continue;
            if (!first) sb.Append(','); first = false;
            sb.Append('[').Append(id[u]).Append(',').Append(u == 0 ? -1 : id[up[u]]).Append(',');
            DiskTraceScanner.Str(sb, un[u]);
            sb.Append(",\"d\",").Append(bA[u]).Append(',').Append(bB[u]).Append(',').Append(fA[u]).Append(',').Append(fB[u]).Append(',')
              .Append(ua[u] < 0 ? 1 : ub[u] < 0 ? 2 : 0).Append(',').Append(ua[u] >= 0 ? a.Flag[ua[u]] : 0).Append(',')
              .Append(ub[u] >= 0 ? b.Flag[ub[u]] : 0).Append(",\"\"]");
        }
        foreach (var c in changes)
        {
            bool before = c.Kind == 2 || c.Kind == 3 || c.Kind == 5, after = c.Kind == 1 || c.Kind == 3 || c.Kind == 4;
            sb.Append(",[").Append(next++).Append(',').Append(id[c.Dir]).Append(',');
            DiskTraceScanner.Str(sb, c.Name);
            sb.Append(",\"f\",").Append(c.SizeA).Append(',').Append(c.SizeB).Append(',').Append(before ? 1 : 0).Append(',').Append(after ? 1 : 0)
              .Append(',').Append(c.Kind).Append(",0,0,");
            DiskTraceScanner.Str(sb, c.Note ?? "");
            sb.Append(']');
        }
        sb.Append("],\"grow\":");
        Top(sb, id, own, keep, 1);
        sb.Append(",\"shrink\":");
        Top(sb, id, own, keep, -1);
        sb.Append('}');
        d.Json = sb.ToString();
        return d;
    }

    // the 15 folders whose own files (not counting subfolders) grew (sign 1) or shrank (sign -1) the most
    static void Top(StringBuilder sb, int[] id, long[] own, bool[] keep, int sign)
    {
        var list = new List<int>();
        for (int u = 0; u < own.Length; u++) if (keep[u] && own[u] * sign > 0) list.Add(u);
        list.Sort((x, y) => (own[y] * sign).CompareTo(own[x] * sign));
        sb.Append('[');
        for (int i = 0; i < list.Count && i < 15; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append('[').Append(id[list[i]]).Append(',').Append(own[list[i]]).Append(']');
        }
        sb.Append(']');
    }
}
'@
if (-not ('DiskTraceDelta' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

# ------------------------------------------------------------------------------------------------- page (HTML/CSS/JS)
$css = @'
:root{--bg:#0f1115;--panel:#161a21;--row:#1b2029;--line:#262c37;--fg:#d7dce4;--muted:#8a93a3;--accent:#6ea8fe;--bar:#3a6fd8;--part:#e5c07b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 "Segoe UI",system-ui,sans-serif}
header{padding:20px 24px 12px;border-bottom:1px solid var(--line);background:var(--panel)}
h1{margin:0 0 4px;font-size:20px;font-weight:600}.sub{color:var(--muted);font-size:13px}
.cards{display:flex;flex-wrap:wrap;gap:10px;margin-top:14px}.card{background:var(--row);border:1px solid var(--line);border-radius:8px;padding:8px 12px;min-width:140px}
.card b{display:block;font-size:17px}.card span{color:var(--muted);font-size:12px}
.tools{display:flex;gap:10px;align-items:center;padding:12px 24px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
input{background:var(--row);border:1px solid var(--line);color:var(--fg);border-radius:6px;padding:7px 10px;width:340px;font:inherit}
button{background:var(--row);border:1px solid var(--line);color:var(--fg);border-radius:6px;padding:6px 10px;cursor:pointer;font:inherit}
button:hover{border-color:var(--accent)}main{padding:8px 16px 40px}
.n{display:flex;align-items:center;gap:8px;padding:3px 6px;border-radius:5px;white-space:nowrap}.n:hover{background:var(--row)}
.n.hl{outline:1px solid var(--accent);background:#1d2635}
.c{width:16px;text-align:center;color:var(--muted);cursor:pointer;user-select:none}
.nm{min-width:180px;max-width:420px;overflow:hidden;text-overflow:ellipsis}.d .nm,.g .nm{cursor:pointer}
.f .nm{color:#b9c0cc}.g .nm{color:var(--muted);font-style:italic}.l .nm{color:var(--part)}
.bar{width:120px;height:7px;background:var(--line);border-radius:4px;overflow:hidden;flex:none}.bar>i{display:block;height:100%;background:var(--bar)}
.sz{width:78px;text-align:right;font-variant-numeric:tabular-nums}.ct{width:110px;text-align:right;color:var(--muted);font-variant-numeric:tabular-nums;font-size:12px}
.dt{width:84px;color:var(--muted);font-size:12px}.note{color:var(--muted);font-size:12px;overflow:hidden;text-overflow:ellipsis}
.kids{margin-left:18px;border-left:1px solid var(--line);padding-left:4px}
#res{padding:0 24px}.r{padding:4px 0;cursor:pointer;color:var(--accent);font-size:13px}.r span{color:var(--muted)}
section.help{padding:10px 24px;color:var(--muted);font-size:13px;border-bottom:1px solid var(--line)}
.lock{color:var(--part);font-size:12px;white-space:nowrap}.lock.in{color:var(--muted)}
section.unr{padding:10px 24px;font-size:13px;border-bottom:1px solid var(--line)}section.unr summary{cursor:pointer;color:var(--part)}
section.unr p{margin:6px 0 0;color:var(--muted)}section.unr .list{max-height:320px;overflow:auto;margin-top:6px}
'@
$js = @'
const N=DATA.nodes,L=DATA.text,K={},byId={};
for(const n of N){byId[n[0]]=n;if(n[1]>=0)(K[n[1]]=K[n[1]]||[]).push(n[0]);}
for(const k in K)K[k].sort((a,b)=>byId[b][4]-byId[a][4]);
const SHOW=25,MINPCT=0.01,fmt=v=>v.toLocaleString(L.locale);
function hb(n){const u=[[1099511627776,'TB'],[1073741824,'GB'],[1048576,'MB'],[1024,'KB']];
 for(const [d,s] of u)if(n>=d)return(n/d).toLocaleString(L.locale,{minimumFractionDigits:1,maximumFractionDigits:1})+' '+s;return n+' B';}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
function full(id){const p=[];let n=byId[id];while(n){p.unshift(n[2]);n=n[1]>=0?byId[n[1]]:null;}return p.join('\\');}
function cols(bytes,pb,files,date,isLink,isDirLike){const pct=pb?Math.max(0.5,100*bytes/pb):100;
 return `<span class="bar"><i style="width:${isLink?0:pct.toFixed(1)}%"></i></span><span class="sz">${isLink?'':hb(bytes)}</span>`+
 `<span class="ct">${isDirLike?fmt(files)+' '+L.files:''}</span><span class="dt">${date}</span>`;}
const WHY=[,L.denied,L.deniedPart,L.error,L.errorPart];
function row(id,pb){
 const n=byId[id],kind=n[3],el=document.createElement('div');el.className='w';
 const r=document.createElement('div');r.className='n '+kind;r.id='n'+id;r.title=full(id);
 const has=!!K[id]&&kind==='d',fl=n[11]||0,blind=fl===1||fl===3;
 let h=`<span class="c">${has?'▸':''}</span><span class="nm">${esc(n[2])}</span>`;
 h+=blind?`<span class="bar"></span><span class="sz">?</span><span class="ct"></span><span class="dt"></span>`:cols(n[4],pb,n[5],n[7],kind==='l',kind==='d');
 if(fl)h+=`<span class="lock">🔒 ${esc(WHY[fl])}${blind?' · '+esc(L.unknown):''}</span>`;
 else if(n[12])h+=`<span class="lock in" title="${esc(L.inside.replace('{0}',fmt(n[12])))}">🔒 ${fmt(n[12])}</span>`;
 if(n[8])h+=`<span class="note">${esc(n[8])}</span>`;
 r.innerHTML=h;el.appendChild(r);
 if(has){const t=()=>toggle(el,id);r.querySelector('.c').onclick=t;r.querySelector('.nm').onclick=t;}
 return el;}
function group(list,pb){
 let b=0,f=0;for(const c of list){b+=byId[c][4];f+=byId[c][5];}
 const el=document.createElement('div');el.className='w';const r=document.createElement('div');r.className='n g';
 r.innerHTML=`<span class="c">▸</span><span class="nm">${fmt(list.length)} ${L.smaller}</span>`+cols(b,pb,f,'',false,true);
 el.appendChild(r);return el;}
function fill(k,list,pb,more){
 const show=[],rest=[];
 list.forEach((c,i)=>{(i<SHOW||byId[c][11]||(!more&&byId[c][4]>=pb*MINPCT)?show:rest).push(c);});
 if(more&&rest.length<=200){show.push(...rest);rest.length=0;}
 else if(more){show.push(...rest.splice(0,200));}
 for(const c of show)k.appendChild(row(c,pb));
 if(rest.length){const g=group(rest,pb);k.appendChild(g);
  const r=g.firstChild,open=()=>{const frag=document.createDocumentFragment();fill(frag,rest,pb,true);g.replaceWith(frag);};
  r.querySelector('.c').onclick=open;r.querySelector('.nm').onclick=open;}}
function toggle(el,id,open){let k=el.querySelector(':scope>.kids');const c=el.querySelector(':scope>.n .c');
 if(k){if(open)return k;k.remove();c.textContent='▸';return null;}
 k=document.createElement('div');k.className='kids';fill(k,K[id],byId[id][4],false);el.appendChild(k);c.textContent='▾';return k;}
const T=document.getElementById('tree'),root=N[0][0];
function reset(){T.innerHTML='';const re=row(root,0);T.appendChild(re);toggle(re,root);}reset();
function reveal(id){const chain=[];let n=byId[id];while(n){chain.unshift(n[0]);n=n[1]>=0?byId[n[1]]:null;}
 for(let i=0;i<chain.length-1;i++){const el=document.getElementById('n'+chain[i]).parentElement;const k=toggle(el,chain[i],true);
  let guard=0,g;while(!document.getElementById('n'+chain[i+1])&&(g=k.querySelector(':scope>.w>.n.g'))&&guard++<50000)g.querySelector('.c').click();}
 document.querySelectorAll('.hl').forEach(x=>x.classList.remove('hl'));const t=document.getElementById('n'+id);if(t){t.classList.add('hl');t.scrollIntoView({block:'center'});}}
document.getElementById('q').onkeydown=e=>{if(e.key!=='Enter')return;const q=e.target.value.trim().toLowerCase(),R=document.getElementById('res');R.innerHTML='';
 if(!q)return;let c=0;for(const n of N){if(n[2].toLowerCase().includes(q)){const d=document.createElement('div');d.className='r';
 d.innerHTML=esc(n[2])+' <span>— '+esc(n[1]>=0?full(n[1]):'')+' · '+(n[3]==='l'?L.link:n[11]===1||n[11]===3?'?':hb(n[4]))+'</span>';d.onclick=()=>reveal(n[0]);R.appendChild(d);if(++c>=200)break;}}
 if(!c)R.textContent=L.none;};
document.getElementById('collapse').onclick=()=>{reset();document.getElementById('res').innerHTML='';};
const U=document.getElementById('unread');
if(U)U.ontoggle=()=>{const box=U.querySelector('.list');if(!U.open||box.childElementCount)return;
 const ids=N.filter(n=>n[3]==='d'&&n[11]).map(n=>n[0]).sort((a,b)=>full(a).localeCompare(full(b)));
 for(const id of ids){const d=document.createElement('div');d.className='r';
  d.innerHTML=esc(full(id))+' <span>— '+esc(WHY[byId[id][11]])+'</span>';d.onclick=()=>reveal(id);box.appendChild(d);}};
'@

# ------------------------------------------------------------------------------------------------- analysis page (CSS/JS)
$acss = @'
.bar>i.pos{background:#2ea043}.bar>i.neg{background:#da3633}.up{color:#7ee787}.down{color:#ff7b72}
.an .sz{width:96px}.ba{width:200px;text-align:right;color:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
.st{font-size:12px;padding:0 6px;border-radius:4px;border:1px solid var(--line);color:var(--part);white-space:nowrap}
.st.sd1,.st.sf1,.st.sf4{color:#7ee787}.st.sd2,.st.sf2,.st.sf5{color:#ff7b72}
#tabs{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}#tabs button.on{border-color:var(--accent);color:var(--accent)}
h2{margin:14px 0 2px;font-size:17px;font-weight:600}.notes{margin:8px 0 0;padding-left:18px;color:var(--part);font-size:13px}
.chart{margin-top:14px;max-width:820px}.chart svg{width:100%;height:150px;background:var(--row);border:1px solid var(--line);border-radius:8px}
.legend{font-size:12px;color:var(--muted);margin-bottom:4px}.legend i{display:inline-block;width:12px;height:3px;margin:0 4px 3px 10px;vertical-align:middle}
.lists{display:flex;flex-wrap:wrap;gap:24px;padding:10px 24px;border-bottom:1px solid var(--line)}.lists>div{min-width:320px;flex:1}
.lists h3{margin:0 0 4px;font-size:14px;font-weight:600}.lists .none{color:var(--muted);font-size:13px}.lists .r{overflow-wrap:anywhere}
'@
$ajs = @'
const L=DATA.text,fmt=v=>v.toLocaleString(L.locale),SHOW=25,MINPCT=0.01,$=id=>document.getElementById(id);
function hb(n){const u=[[1099511627776,'TB'],[1073741824,'GB'],[1048576,'MB'],[1024,'KB']];
 for(const [d,s] of u)if(n>=d)return(n/d).toLocaleString(L.locale,{minimumFractionDigits:1,maximumFractionDigits:1})+' '+s;return n+' B';}
function sb(d){return d>0?'+'+hb(d):d<0?'−'+hb(-d):'0 B';}
function sc(d){return d>0?'+'+fmt(d):d<0?'−'+fmt(-d):'0';}
function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}
let D,N=[],K={},byId={};
const dl=id=>byId[id][5]-byId[id][4],ad=id=>Math.abs(dl(id));
function full(id){const p=[];let n=byId[id];while(n){p.unshift(n[2]);n=n[1]>=0?byId[n[1]]:null;}return p.join('\\');}
const ST={d:['',L.newD,L.goneD],f:['',L.newF,L.goneF,L.changedF,L.movedIn,L.movedOut]};
// node: [id, parent, name, kind, bytesBefore, bytesAfter, filesBefore, filesAfter, status, flagBefore, flagAfter, note]
function row(id,pm){
 const n=byId[id],kind=n[3],el=document.createElement('div');el.className='w';
 const r=document.createElement('div');r.className='n '+kind;r.id='n'+id;r.title=full(id);
 const has=!!K[id],d=n[5]-n[4],pct=pm&&d?Math.max(0.5,100*Math.abs(d)/pm):0;
 const nb=kind==='d'?n[8]===1:!n[6],na=kind==='d'?n[8]===2:!n[7];
 let h=`<span class="c">${has?'▸':''}</span><span class="nm">${esc(n[2])}</span>`+
  `<span class="bar"><i class="${d<0?'neg':'pos'}" style="width:${pct.toFixed(1)}%"></i></span>`+
  `<span class="sz ${d>0?'up':d<0?'down':''}">${sb(d)}</span>`+
  `<span class="ba">${nb?'—':hb(n[4])} → ${na?'—':hb(n[5])}</span>`+
  `<span class="ct">${kind==='d'&&n[7]!==n[6]?sc(n[7]-n[6])+' '+L.files:''}</span>`;
 const st=n[8]?ST[kind][n[8]]:'';
 if(st)h+=`<span class="st s${kind}${n[8]}">${esc(st.replace('{0}',n[11]))}</span>`;
 if(n[10])h+=`<span class="lock">🔒 ${esc(L.unreadB)}</span>`;else if(n[9])h+=`<span class="lock">🔒 ${esc(L.unreadA)}</span>`;
 r.innerHTML=h;el.appendChild(r);
 if(has){const t=()=>toggle(el,id);r.querySelector('.c').onclick=t;r.querySelector('.nm').onclick=t;}
 return el;}
function group(list){let s=0;for(const c of list)s+=dl(c);
 const el=document.createElement('div');el.className='w';const r=document.createElement('div');r.className='n g';
 r.innerHTML=`<span class="c">▸</span><span class="nm">${fmt(list.length)} ${L.smaller}</span><span class="bar"></span><span class="sz ${s>0?'up':s<0?'down':''}">${sb(s)}</span>`;
 el.appendChild(r);return el;}
function fill(k,list,pm,more){
 const show=[],rest=[];
 list.forEach((c,i)=>{(i<SHOW||(!more&&ad(c)>=pm*MINPCT)?show:rest).push(c);});
 if(more&&rest.length<=200){show.push(...rest);rest.length=0;}
 else if(more){show.push(...rest.splice(0,200));}
 for(const c of show)k.appendChild(row(c,pm));
 if(rest.length){const g=group(rest);k.appendChild(g);
  const r=g.firstChild,open=()=>{const frag=document.createDocumentFragment();fill(frag,rest,pm,true);g.replaceWith(frag);};
  r.querySelector('.c').onclick=open;r.querySelector('.nm').onclick=open;}}
function toggle(el,id,open){let k=el.querySelector(':scope>.kids');const c=el.querySelector(':scope>.n .c');
 if(k){if(open)return k;k.remove();c.textContent='▸';return null;}
 let pm=0;for(const x of K[id])pm=Math.max(pm,ad(x));
 k=document.createElement('div');k.className='kids';fill(k,K[id],pm,false);el.appendChild(k);c.textContent='▾';return k;}
const T=$('tree');
function reset(){T.innerHTML='';if(!N.length)return;const re=row(N[0][0],0);T.appendChild(re);if(K[N[0][0]])toggle(re,N[0][0]);}
function reveal(id){const chain=[];let n=byId[id];while(n){chain.unshift(n[0]);n=n[1]>=0?byId[n[1]]:null;}
 for(let i=0;i<chain.length-1;i++){const el=document.getElementById('n'+chain[i]).parentElement;const k=toggle(el,chain[i],true);
  let guard=0,g;while(!document.getElementById('n'+chain[i+1])&&(g=k.querySelector(':scope>.w>.n.g'))&&guard++<50000)g.querySelector('.c').click();}
 document.querySelectorAll('.hl').forEach(x=>x.classList.remove('hl'));const t=document.getElementById('n'+id);if(t){t.classList.add('hl');t.scrollIntoView({block:'center'});}}
function chart(t){if(t.length<2)return '';
 const W=800,H=150,P=40;let lo=Infinity,hi=-Infinity;for(const x of t){lo=Math.min(lo,x[1],x[2]);hi=Math.max(hi,x[1],x[2]);}
 if(hi===lo){hi+=1;lo-=1;}const pad=(hi-lo)*0.1;lo-=pad;hi+=pad;
 const X=i=>P+(W-2*P)*i/(t.length-1),Y=v=>H-22-(H-40)*(v-lo)/(hi-lo);
 const line=(k,c)=>`<polyline fill="none" style="stroke:${c}" stroke-width="2" points="${t.map((x,i)=>X(i).toFixed(1)+','+Y(x[k]).toFixed(1)).join(' ')}"/>`+
  t.map((x,i)=>`<circle cx="${X(i).toFixed(1)}" cy="${Y(x[k]).toFixed(1)}" r="3" style="fill:${c}"><title>${esc(x[0])} · ${hb(x[k])}</title></circle>`).join('');
 const tx=(x,y,s,a)=>`<text x="${x}" y="${y}" text-anchor="${a}" style="fill:var(--muted);font-size:11px">${esc(s)}</text>`;
 return `<div class="chart"><div class="legend"><i style="background:var(--accent)"></i>${esc(L.used)}<i style="background:var(--muted)"></i>${esc(L.scanned)}</div>`+
  `<svg viewBox="0 0 ${W} ${H}">`+tx(4,14,hb(hi),'start')+tx(4,H-26,hb(lo),'start')+tx(P,H-6,t[0][0],'start')+tx(W-P,H-6,t[t.length-1][0],'end')+
  line(2,'var(--muted)')+line(1,'var(--accent)')+'</svg></div>';}
function load(i){
 D=DATA.disks[i];N=D.delta?D.delta.nodes:[];K={};byId={};
 for(const n of N){byId[n[0]]=n;if(n[1]>=0)(K[n[1]]=K[n[1]]||[]).push(n[0]);}
 for(const k in K)K[k].sort((a,b)=>ad(b)-ad(a));
 $('dt').textContent=D.title;$('ds').textContent=D.sub;
 $('dn').innerHTML=D.notes.map(x=>'<li>'+esc(x)+'</li>').join('');
 $('dc').innerHTML=D.cards.map(c=>`<div class="card"><b>${esc(c[0])}</b><span>${esc(c[1])}</span></div>`).join('');
 $('dg').innerHTML=chart(D.timeline);
 const li=(h,list)=>`<div><h3>${esc(h)}</h3>`+(list.length?list.map(x=>`<div class="r" data-id="${x[0]}">${esc(full(x[0]))} <span>${sb(x[1])}</span></div>`).join(''):`<div class="none">${esc(L.nothing)}</div>`)+'</div>';
 $('dlist').innerHTML=D.delta?li(L.grew,D.delta.grow)+li(L.shrank,D.delta.shrink):'';
 $('dlist').style.display=D.delta?'':'none';
 $('dlist').querySelectorAll('.r').forEach(e=>e.onclick=()=>reveal(+e.dataset.id));
 $('tools').style.display=D.delta?'':'none';$('res').innerHTML='';
 document.querySelectorAll('#tabs button').forEach((b,j)=>b.classList.toggle('on',j===i));
 reset();}
if(DATA.disks.length>1){$('tabs').innerHTML=DATA.disks.map(d=>`<button>${esc(d.tab)}</button>`).join('');
 document.querySelectorAll('#tabs button').forEach((b,j)=>b.onclick=()=>load(j));}
$('q').onkeydown=e=>{if(e.key!=='Enter')return;const q=e.target.value.trim().toLowerCase(),R=$('res');R.innerHTML='';
 if(!q)return;let c=0;for(const n of N){if(n[2].toLowerCase().includes(q)){const d=document.createElement('div');d.className='r';
 d.innerHTML=esc(n[2])+' <span>— '+esc(n[1]>=0?full(n[1]):'')+' · '+sb(n[5]-n[4])+'</span>';d.onclick=()=>reveal(n[0]);R.appendChild(d);if(++c>=200)break;}}
 if(!c)R.textContent=L.none;};
$('collapse').onclick=()=>{reset();$('res').innerHTML='';};
load(0);
'@

# ------------------------------------------------------------------------------------------------- helpers
function Format-Size([double]$n) {
    foreach ($u in @(@('TB', 1TB), @('GB', 1GB), @('MB', 1MB), @('KB', 1KB))) { if ($n -ge $u[1]) { return [string]::Format($Culture, '{0:N1} {1}', $n / $u[1], $u[0]) } }
    return [string]::Format($Culture, '{0} B', $n)
}
function Format-Signed([double]$n) { if ($n -gt 0) { '+' + (Format-Size $n) } elseif ($n -lt 0) { '−' + (Format-Size (-$n)) } else { '0 B' } }
function Format-Count($n) { [string]::Format($Culture, '{0:N0}', $n) }
function Format-When([DateTime]$utc) { $utc.ToLocalTime().ToString($T.dateFmt, $Culture) }
function Html([string]$s) { [Net.WebUtility]::HtmlEncode($s) }
function Js([string]$s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace '<', '<') + '"' }
function Js-Object($table) { '{' + (($table.GetEnumerator() | ForEach-Object { (Js $_.Key) + ':' + (Js $_.Value) }) -join ',') + '}' }
function Get-PageHead([string]$title, [string]$style) {
    '<!doctype html><html lang="' + $Language + '"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''; script-src ''unsafe-inline''">' +
    '<title>' + (Html $title) + '</title><style>' + $style + '</style></head>'
}
function Save-Page([string]$name, [string]$html, [string]$message) {
    New-Item -ItemType Directory -Force $OutputDir | Out-Null
    $out = Join-Path $OutputDir $name
    [IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding($false)))
    Write-Host ($message -f $out, ([string]::Format($Culture, '{0:N1}', (Get-Item -LiteralPath $out).Length / 1MB)))
    $out
}

function Draw-Rows([int]$top, [string[]]$lines, [int]$sel) {
    $width = [Math]::Max(10, [Console]::WindowWidth - 1)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        [Console]::SetCursorPosition(0, $top + $i)
        $line = ('  {0} {1}' -f $(if ($i -eq $sel) { '>' } else { ' ' }), $lines[$i])
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        $line = $line.PadRight($width)
        if ($i -eq $sel) { Write-Host $line -NoNewline -ForegroundColor Black -BackgroundColor Cyan }
        else { Write-Host $line -NoNewline }
    }
}
function Open-Menu([string]$Title, [string]$Hint, [int]$Count) {
    # Prints the title and reserves $Count lines; returns the first line
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host $Hint -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Count; $i++) { Write-Host '' }
    [Console]::CursorTop - $Count
}
function Close-Menu([int]$top, [int]$Count) { [Console]::SetCursorPosition(0, $top + $Count); Write-Host '' }

function Select-Menu([string]$Title, [string[]]$Items) {
    # Arrow-key menu: returns the chosen index, or -1 on Esc
    $sel = 0
    $top = Open-Menu $Title $T.menuHint $Items.Count
    $cursor = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Draw-Rows $top $Items $sel
            $k = [Console]::ReadKey($true)
            switch ("$($k.Key)") {
                { $_ -in 'UpArrow', 'W' }   { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                { $_ -in 'DownArrow', 'S' } { $sel = ($sel + 1) % $Items.Count }
                'Home'   { $sel = 0 }
                'End'    { $sel = $Items.Count - 1 }
                'Enter'  { Close-Menu $top $Items.Count; return $sel }
                'Escape' { Close-Menu $top $Items.Count; return -1 }
            }
        }
    }
    finally { [Console]::CursorVisible = $cursor }
}

function Select-Main([string]$Title, [object[]]$Rows) {
    # Rows: @{ Text; Options; Pos; Group }. Up/Down picks a row, Left/Right changes its value (rows of the same
    # Group share it). Returns the chosen index, or -1 on Esc.
    $sel = 0
    $wide = ($Rows | ForEach-Object { $_.Text.Length } | Measure-Object -Maximum).Maximum + 3
    $top = Open-Menu $Title $T.mainHint $Rows.Count
    $cursor = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $lines = foreach ($r in $Rows) {
                if ($r.Options) { $r.Text.PadRight($wide) + '◄ ' + $r.Options[$r.Pos] + ' ►' } else { $r.Text }
            }
            Draw-Rows $top @($lines) $sel
            $k = [Console]::ReadKey($true)
            $step = 0
            switch ("$($k.Key)") {
                { $_ -in 'UpArrow', 'W' }    { $sel = ($sel - 1 + $Rows.Count) % $Rows.Count }
                { $_ -in 'DownArrow', 'S' }  { $sel = ($sel + 1) % $Rows.Count }
                { $_ -in 'LeftArrow', 'A' }  { $step = -1 }
                { $_ -in 'RightArrow', 'D' } { $step = 1 }
                'Enter'  { Close-Menu $top $Rows.Count; return $sel }
                'Escape' { Close-Menu $top $Rows.Count; return -1 }
            }
            $r = $Rows[$sel]
            if ($step -and $r.Options) {
                $pos = ($r.Pos + $step + $r.Options.Count) % $r.Options.Count
                foreach ($o in $Rows) { if ($o -eq $r -or ($r.Group -and $o.Group -eq $r.Group)) { $o.Pos = $pos } }
            }
        }
    }
    finally { [Console]::CursorVisible = $cursor }
}

function Select-Many([string]$Title, [string[]]$Items) {
    # Multi-select with an "all" row on top: Space marks, Shift+Up/Down marks a range. Returns the chosen
    # indexes of $Items; Enter with nothing marked takes the highlighted row. Esc returns nothing.
    $rows = @($T.allDrives) + $Items
    $on = New-Object bool[] $rows.Count
    $sel = 0
    $top = Open-Menu $Title $T.pickHint $rows.Count
    $cursor = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $lines = for ($i = 0; $i -lt $rows.Count; $i++) { $(if ($on[$i]) { '[x] ' } else { '[ ] ' }) + $rows[$i] }
            Draw-Rows $top @($lines) $sel
            $k = [Console]::ReadKey($true)
            $shift = ($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
            $prev = $sel
            switch ("$($k.Key)") {
                { $_ -in 'UpArrow', 'W' }   { $sel = if ($shift) { [Math]::Max(1, $sel - 1) } else { ($sel - 1 + $rows.Count) % $rows.Count } }
                { $_ -in 'DownArrow', 'S' } { $sel = if ($shift) { [Math]::Min($rows.Count - 1, [Math]::Max(1, $sel + 1)) } else { ($sel + 1) % $rows.Count } }
                'Spacebar' {
                    if ($sel -eq 0) { $v = -not $on[0]; for ($i = 0; $i -lt $rows.Count; $i++) { $on[$i] = $v } }
                    else { $on[$sel] = -not $on[$sel] }
                }
                'Enter' {
                    Close-Menu $top $rows.Count
                    $picked = @(for ($i = 1; $i -lt $rows.Count; $i++) { if ($on[$i]) { $i - 1 } })
                    if (-not $picked.Count) { $picked = if ($sel -eq 0) { @(0..($Items.Count - 1)) } else { @($sel - 1) } }
                    return , $picked
                }
                'Escape' { Close-Menu $top $rows.Count; return , @() }
            }
            if ($shift -and $prev -ne $sel) { foreach ($i in $prev, $sel) { if ($i -gt 0) { $on[$i] = $true } } }
            $all = $true
            for ($i = 1; $i -lt $rows.Count; $i++) { if (-not $on[$i]) { $all = $false } }
            $on[0] = $all
        }
    }
    finally { [Console]::CursorVisible = $cursor }
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$Interactive = -not ($Drive -or $Analyze)
function Finish([int]$code) { if ($Interactive) { Read-Host $T.pressEnter | Out-Null }; exit $code }

# ------------------------------------------------------------------------------------------------- drives
function Get-FixedVolumes { @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } | Sort-Object DriveLetter) }
function Get-VolumeKey($v) { if ("$($v.UniqueId)" -match '\{([0-9a-fA-F-]{36})\}') { $Matches[1].ToLowerInvariant() } else { 'drive-' + $v.DriveLetter } }
function Get-VolumeDisk($v) { try { Get-Partition -DriveLetter $v.DriveLetter | Get-Disk } catch { $null } }
function Get-VolumeLabel($v) { if ($v -and $v.FileSystemLabel) { $v.FileSystemLabel } else { $T.noLabel } }
function Get-VolumeLine($v) {
    $disk = Get-VolumeDisk $v
    [string]::Format($Culture, '{0}:  {1,-18} {2,8:N1} GB   {5} {3,8:N1} GB   {4}', $v.DriveLetter, (Get-VolumeLabel $v), ($v.Size / 1GB), ($v.SizeRemaining / 1GB),
        $(if ($disk) { $disk.FriendlyName } else { '' }), $T.free)
}

function Get-Targets {
    # Returns @{ Root; Vol } for each drive (or the one folder) to scan
    $vols = Get-FixedVolumes
    if ($Interactive) {
        if (-not $vols) { Write-Host $T.noDrives; Finish 1 }
        $picked = Select-Many $T.pickDrive @($vols | ForEach-Object { Get-VolumeLine $_ })
        if (-not $picked.Count) { exit 0 }
        return @($picked | ForEach-Object { @{ Root = "$($vols[$_].DriveLetter):\"; Vol = $vols[$_] } })
    }
    $specs = @($Drive | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($specs -contains 'all') { return @($vols | ForEach-Object { @{ Root = "$($_.DriveLetter):\"; Vol = $_ } }) }
    foreach ($s in $specs) {
        if ($s -match '^[A-Za-z]:?\\?$') {
            $root = $s.Substring(0, 1).ToUpper() + ':\'
            @{ Root = $root; Vol = (Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue) }
        }
        else { @{ Root = (Resolve-Path -LiteralPath $s).ProviderPath; Vol = $null } }
    }
}

function Resolve-Profile([string]$driveRoot) {
    # User profile whose personal folders get their files listed
    if ($UserProfile) { return $UserProfile }
    if ($driveRoot -ieq $env:SystemDrive) { return $env:USERPROFILE }
    $skip = 'Public', 'Default', 'Default User', 'All Users', 'WDAGUtilityAccount'
    $cands = @(Get-ChildItem "$driveRoot\Users" -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [IO.File]::Exists((Join-Path $_.FullName 'NTUSER.DAT')) } |
        Sort-Object LastWriteTime -Descending)
    if ($cands.Count -eq 1) { return $cands[0].FullName }
    if ($cands.Count -gt 1) {
        $pp = if ($Interactive) { Select-Menu ($T.pickProfile + "  ($driveRoot)") @($cands | ForEach-Object { $_.Name }) } else { 0 }
        if ($pp -lt 0) { exit 0 }
        return $cands[$pp].FullName
    }
    'none'
}

# ------------------------------------------------------------------------------------------------- scan, report, snapshot
function Invoke-Scan([string]$root, [string]$prof, [bool]$allFiles) {
    $t0 = Get-Date
    Write-Host ''
    Write-Host ($T.scanning -f $root) -ForegroundColor Cyan
    $progress = [Action[int]] { param($n) Write-Host ($T.foldersRead -f (Format-Count $n)) }
    $scan = [DiskTraceScanner]::Run($root, $prof, $allFiles, $progress)
    $scan.Aggregate()
    Write-Host ($T.scanDone -f ([int]((Get-Date) - $t0).TotalSeconds), (Format-Count ($scan.Names.Count - 1)), (Format-Count $scan.TotalFiles), $scan.Errors) -ForegroundColor Green
    $scan
}

function Write-Report($scan, [string]$root, $vol, [string]$prof) {
    Write-Host $T.building -ForegroundColor Cyan
    $driveRoot = $root.Substring(0, 2)
    $rootNoSlash = $root.TrimEnd('\')
    $profRel = ''
    if ($prof -ne 'none' -and $prof.Length -gt $rootNoSlash.Length -and $prof.StartsWith($rootNoSlash, 'OrdinalIgnoreCase')) {
        $profRel = $prof.Substring($rootNoSlash.Length).Trim('\')
    }
    $nodes = $scan.NodesJson($profRel, $(if ($Language -eq 'pt-BR') { 1 } else { 0 }))

    $isFolder = $root.Length -gt 3
    $label = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { $T.driveWord }
    $title = if ($isFolder) { $T.titleFolder -f $root } else { $T.titleDrive -f $driveRoot, $label }
    $cards = New-Object System.Collections.Generic.List[object]
    if ($vol -and -not $isFolder) {
        $cards.Add(@((Format-Size $vol.Size), $T.capacity)); $cards.Add(@((Format-Size ($vol.Size - $vol.SizeRemaining)), $T.used)); $cards.Add(@((Format-Size $vol.SizeRemaining), $T.freeCard))
        $notSeen = ($vol.Size - $vol.SizeRemaining) - $scan.TotalBytes
        $cards.Add(@((Format-Size ([Math]::Abs($notSeen))), $(if ($notSeen -ge 0) { $T.notSeen } else { $T.notSeenNeg })))
    }
    $cards.Add(@((Format-Count $scan.TotalFiles), $T.filesCounted)); $cards.Add(@((Format-Count ($scan.Names.Count - 1)), $T.folders))
    foreach ($c in $scan.TopChildren(4)) { $p = $c.Split('|'); $cards.Add(@((Format-Size ([double]$p[1])), ($T.largest + $p[0]))) }
    $cardsHtml = ($cards | ForEach-Object { '<div class="card"><b>' + (Html $_[0]) + '</b><span>' + (Html $_[1]) + '</span></div>' }) -join ''
    $sub = $T.generated -f (Get-Date).ToString($T.dateFmt, $Culture), $root
    $help = ($T.help -f $scan.Errors) + $(if ($vol -and -not $isFolder) { $T.notSeenHelp } else { '' })
    $unreadHtml = ''
    if ($scan.Errors -gt 0) {
        $unreadHtml = '<section class="unr"><details id="unread"><summary>' + (Html ($T.unreadTitle -f (Format-Count $scan.Errors))) + '</summary><p>' +
                      (Html $T.unreadText) + '</p><div class="list"></div></details></section>'
    }

    $html = (Get-PageHead $title $css) + '<body><header><h1>' + (Html $title) + '</h1><div class="sub">' + (Html $sub) +
            '</div><div class="cards">' + $cardsHtml + '</div></header>' + $unreadHtml + '<section class="help">' + (Html $help) + '</section>' +
            '<div class="tools"><input id="q" placeholder="' + (Html $T.search) + '"><button id="collapse">' + (Html $T.collapse) + '</button></div>' +
            '<div id="res"></div><main id="tree"></main><script>const DATA={"nodes":' + $nodes + ',"text":' + (Js-Object $T.js) + '};' + "`n" + $js + '</script></body></html>'
    Save-Page ('disktrace-{0}-{1}-{2}.html' -f $driveRoot.Substring(0, 1), ($label -replace '[^\w-]', '_'), (Get-Date -Format 'yyyy-MM-dd_HHmm')) $html $T.pageAt
}

function Save-Snapshot($scan, $vol, [bool]$allFiles) {
    $disk = Get-VolumeDisk $vol
    $mode = if ($allFiles) { 'full' } else { 'summary' }
    $head = [ordered]@{
        format = 'disktrace-snapshot'; version = 1; tool = $Version; mode = $mode
        taken = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); admin = $IsAdmin
        volume = [ordered]@{ id = (Get-VolumeKey $vol); letter = "$($vol.DriveLetter)"; label = "$($vol.FileSystemLabel)"; fs = "$($vol.FileSystem)"
                             size = [long]$vol.Size; free = [long]$vol.SizeRemaining
                             disk = $(if ($disk) { "$($disk.FriendlyName)" } else { '' }); serial = $(if ($disk) { "$($disk.SerialNumber)".Trim() } else { '' }) }
        scanned = $scan.TotalBytes; files = $scan.TotalFiles; folders = $scan.Names.Count - 1; unread = $scan.Errors
    }
    $dir = Join-Path $SnapshotDir $head.volume.id
    New-Item -ItemType Directory -Force $dir | Out-Null
    $path = Join-Path $dir ('{0}.{1}.tsv.gz' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $mode)
    $scan.WriteSnapshot($path, ($head | ConvertTo-Json -Compress -Depth 4))
    Write-Host ($T.snapSaved -f $path, ([string]::Format($Culture, '{0:N1}', (Get-Item -LiteralPath $path).Length / 1MB))) -ForegroundColor Green
    if ($allFiles -and $KeepFull -gt 0) {
        $old = @(Get-ChildItem -LiteralPath $dir -Filter '*.full.tsv.gz' -File | Sort-Object Name -Descending | Select-Object -Skip $KeepFull)
        if ($old.Count) {
            Add-Type -AssemblyName Microsoft.VisualBasic
            foreach ($f in $old) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
                Write-Host ($T.recycled -f $f.Name)
            }
        }
    }
}

# ------------------------------------------------------------------------------------------------- analysis
function Get-PeriodLabel([string]$p) { switch ($p) { 'last' { $T.pLast } 'all' { $T.pAll } default { $T.pDays -f $p } } }

function Get-StoredVolumes {
    if (-not (Test-Path -LiteralPath $SnapshotDir)) { return @() }
    $mounted = @{}
    foreach ($v in Get-FixedVolumes) { $mounted[(Get-VolumeKey $v)] = $v }
    foreach ($d in @(Get-ChildItem -LiteralPath $SnapshotDir -Directory | Sort-Object Name)) {
        $snaps = @(@(foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.tsv.gz' -File)) {
            try { $h = [DiskTraceSnapshot]::ReadHeader($f.FullName) | ConvertFrom-Json }
            catch { Write-Host ($T.badSnapshot -f $f.FullName) -ForegroundColor Yellow; continue }
            [pscustomobject]@{ Path = $f.FullName; Taken = [DateTimeOffset]::FromUnixTimeSeconds([long]$h.taken).UtcDateTime; H = $h }
        }) | Sort-Object Taken)
        if ($snaps.Count) { [pscustomobject]@{ Key = $d.Name; Snaps = $snaps; Latest = $snaps[-1].H; Mounted = $mounted[$d.Name] } }
    }
}

function Select-Pair($snaps, [string]$period) {
    # Newest snapshot against the baseline for the period; Short when no snapshot is old enough
    if ($snaps.Count -lt 2) { return $null }
    $b = $snaps[-1]
    $older = @($snaps[0..($snaps.Count - 2)])
    $short = $false
    switch ($period) {
        'last' { $a = $older[-1] }
        'all' { $a = $older[0] }
        default {
            $limit = [DateTime]::UtcNow.AddDays(-[int]$period)
            $c = @($older | Where-Object { $_.Taken -le $limit })
            if ($c.Count) { $a = $c[-1] } else { $a = $older[0]; $short = $true }
        }
    }
    [pscustomobject]@{ A = $a; B = $b; Short = $short; Range = @($snaps | Where-Object { $_.Taken -ge $a.Taken -and $_.Taken -le $b.Taken }) }
}

function Get-AnalysisDisk($sv, [string]$period) {
    $h = $sv.Latest
    $letter = if ($sv.Mounted) { "$($sv.Mounted.DriveLetter)" } else { $h.volume.letter }
    $label = if ($h.volume.label) { $h.volume.label } else { $T.noLabel }
    $tab = '{0}: {1}' -f $letter, $label
    $notes = New-Object System.Collections.Generic.List[string]
    $cards = New-Object System.Collections.Generic.List[object]
    $pair = Select-Pair $sv.Snaps $period
    if (-not $pair) {
        $notes.Add(($T.aNeedTwo -f $sv.Snaps.Count))
        return '{"tab":' + (Js $tab) + ',"title":' + (Js $tab) + ',"sub":"","notes":[' + (($notes | ForEach-Object { Js $_ }) -join ',') + '],"cards":[],"timeline":[],"delta":null}'
    }
    $ha = $pair.A.H; $hb = $pair.B.H
    $files = $ha.mode -eq 'full' -and $hb.mode -eq 'full'
    Write-Host ($T.comparing -f $tab, (Format-When $pair.A.Taken), (Format-When $pair.B.Taken)) -ForegroundColor Cyan
    $sa = [DiskTraceSnapshot]::Load($pair.A.Path, $files)
    $sb = [DiskTraceSnapshot]::Load($pair.B.Path, $files)
    $delta = [DiskTraceDelta]::Build($sa, $sb, $files, 300000)
    $sa = $null; $sb = $null; [GC]::Collect()

    if ($pair.Short) { $notes.Add(($T.aShort -f (Format-When $pair.A.Taken), [int]([DateTime]::UtcNow - $pair.A.Taken).TotalDays)) }
    if (-not $files) { $notes.Add($T.aSummary) }
    if ([bool]$ha.admin -ne [bool]$hb.admin) { $notes.Add($T.aAdmin) }
    if ($ha.unread -or $hb.unread) { $notes.Add(($T.aUnread -f (Format-Count $ha.unread), (Format-Count $hb.unread))) }
    if ($delta.Omitted) { $notes.Add(($T.aOmitted -f (Format-Count $delta.Omitted))) }

    $usedA = [long]$ha.volume.size - [long]$ha.volume.free; $usedB = [long]$hb.volume.size - [long]$hb.volume.free
    $cards.Add(@((Format-Signed ($usedB - $usedA)), $T.cUsed)); $cards.Add(@((Format-Signed ([long]$hb.scanned - [long]$ha.scanned)), $T.cScanned))
    $cards.Add(@((Format-Count $delta.DirsNew), $T.cDirsNew)); $cards.Add(@((Format-Count $delta.DirsGone), $T.cDirsGone))
    if ($files) {
        $cards.Add(@(('{0} · {1}' -f (Format-Count $delta.FilesNew), (Format-Signed $delta.BytesNew)), $T.cFilesNew))
        $cards.Add(@(('{0} · {1}' -f (Format-Count $delta.FilesGone), (Format-Signed (-$delta.BytesGone))), $T.cFilesGone))
        $cards.Add(@(('{0} · {1}' -f (Format-Count $delta.FilesChanged), (Format-Signed $delta.BytesChanged)), $T.cFilesChanged))
        $cards.Add(@(('{0} · {1}' -f (Format-Count $delta.FilesMoved), (Format-Size $delta.BytesMoved)), $T.cFilesMoved))
    }
    $days = [Math]::Round(($pair.B.Taken - $pair.A.Taken).TotalDays, 1)
    $sub = $T.aRange -f (Format-When $pair.A.Taken), (Format-When $pair.B.Taken), ([string]::Format($Culture, '{0:N1}', $days)), $(if ($files) { $T.aModeFull } else { $T.aModeSummary })
    $timeline = ($pair.Range | ForEach-Object {
        '[' + (Js (Format-When $_.Taken)) + ',' + ([long]$_.H.volume.size - [long]$_.H.volume.free) + ',' + [long]$_.H.scanned + ']' }) -join ','
    '{"tab":' + (Js $tab) + ',"title":' + (Js $tab) + ',"sub":' + (Js $sub) + ',"notes":[' + (($notes | ForEach-Object { Js $_ }) -join ',') + '],' +
    '"cards":[' + (($cards | ForEach-Object { '[' + (Js $_[0]) + ',' + (Js $_[1]) + ']' }) -join ',') + '],"timeline":[' + $timeline + '],"delta":' + $delta.Json + '}'
}

function Invoke-Analysis([string]$period) {
    $stored = @(Get-StoredVolumes)
    if (-not $stored.Count) { Write-Host $T.noSnapshots; Finish 1 }
    if ($Interactive) {
        $items = foreach ($sv in $stored) {
            $letter = if ($sv.Mounted) { "$($sv.Mounted.DriveLetter)" } else { $sv.Latest.volume.letter }
            [string]::Format($Culture, $T.storedItem, $letter, $(if ($sv.Latest.volume.label) { $sv.Latest.volume.label } else { $T.noLabel }),
                $sv.Snaps.Count, (Format-When $sv.Snaps[-1].Taken), $(if ($sv.Mounted) { '' } else { $T.offline }))
        }
        $picked = Select-Many $T.pickStored @($items)
        if (-not $picked.Count) { exit 0 }
        $chosen = @($picked | ForEach-Object { $stored[$_] })
    }
    else {
        $specs = @($Drive | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().TrimEnd('\').TrimEnd(':') } | Where-Object { $_ })
        if (-not $specs.Count -or $specs -contains 'all') { $chosen = $stored }
        else {
            $chosen = @(foreach ($s in $specs) {
                $m = @($stored | Where-Object { ($_.Mounted -and "$($_.Mounted.DriveLetter)" -ieq $s) -or (-not $_.Mounted -and $_.Latest.volume.letter -ieq $s) })
                if (-not $m.Count) { Write-Host ($T.noDriveMatch -f $s) -ForegroundColor Yellow }
                $m
            })
            if (-not $chosen.Count) { Finish 1 }
        }
    }
    $disks = @($chosen | ForEach-Object { Get-AnalysisDisk $_ $period })
    Write-Host $T.building -ForegroundColor Cyan
    $title = $T.aTitle -f (Get-PeriodLabel $period)
    $html = (Get-PageHead $title ($css + $acss)) + '<body><header><h1>' + (Html $title) + '</h1><div class="sub">' +
            (Html ($T.generated -f (Get-Date).ToString($T.dateFmt, $Culture), $SnapshotDir)) + '</div><div id="tabs"></div>' +
            '<h2 id="dt"></h2><div class="sub" id="ds"></div><ul class="notes" id="dn"></ul><div class="cards" id="dc"></div><div id="dg"></div></header>' +
            '<div class="lists" id="dlist"></div><section class="help">' + (Html $T.aHelp) + '</section>' +
            '<div class="tools" id="tools"><input id="q" placeholder="' + (Html $T.search) + '"><button id="collapse">' + (Html $T.collapse) + '</button></div>' +
            '<div id="res"></div><main id="tree" class="an"></main><script>const DATA={"disks":[' + ($disks -join ',') + '],"text":' + (Js-Object $T.ajs) + '};' +
            "`n" + $ajs + '</script></body></html>'
    $out = Save-Page ('disktrace-analysis-{0}-{1}.html' -f $period, (Get-Date -Format 'yyyy-MM-dd_HHmm')) $html $T.analysisAt
    if (-not $NoOpen) { Invoke-Item -LiteralPath $out }
}

# ------------------------------------------------------------------------------------------------- main
$periods = @('last', '7', '30', '90', '180', '360', 'all')
if ($Interactive) {
    $modes = @($T.modeSummary, $T.modeFull)
    $rows = @(
        @{ Text = $T.actReport },
        @{ Text = $T.actSnap; Options = $modes; Pos = 0; Group = 'mode' },
        @{ Text = $T.actSnapReport; Options = $modes; Pos = 0; Group = 'mode' },
        @{ Text = $T.actAnalyze; Options = @($periods | ForEach-Object { Get-PeriodLabel $_ }); Pos = 2 })
    $choice = Select-Main $T.mainTitle $rows
    if ($choice -lt 0) { exit 0 }
    $action = @('report', 'snapshot', 'snapreport', 'analyze')[$choice]
    $allFiles = $rows[1].Pos -eq 1
    $period = $periods[$rows[3].Pos]
}
else {
    $action = if ($Analyze) { 'analyze' } elseif ($Snapshot -and $Report) { 'snapreport' } elseif ($Snapshot) { 'snapshot' } else { 'report' }
    $allFiles = [bool]$Full
    $period = $Analyze
}

if ($action -eq 'analyze') { Invoke-Analysis $period; Finish 0 }

$targets = @(Get-Targets)
$snap = $action -ne 'report'
if ($snap) {
    foreach ($target in $targets) { if ($target.Root.Length -gt 3 -or -not $target.Vol) { Write-Host ($T.snapFolder -f $target.Root) -ForegroundColor Yellow; Finish 1 } }
    if ($allFiles) { Write-Host ''; Write-Host $T.fullWarn -ForegroundColor Yellow }
}
foreach ($target in $targets) {   # not $t: PowerShell names are case-insensitive and $T holds the strings
    $prof = Resolve-Profile $target.Root.Substring(0, 2)
    $scan = Invoke-Scan $target.Root $prof ($snap -and $allFiles)
    if ($snap) { Save-Snapshot $scan $target.Vol ($snap -and $allFiles) }
    if ($action -ne 'snapshot') {
        $out = Write-Report $scan $target.Root $target.Vol $prof
        if (-not $NoOpen) { Invoke-Item -LiteralPath $out }
    }
    $scan = $null; [GC]::Collect()
}
Finish 0
