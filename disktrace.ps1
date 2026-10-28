<#
.SYNOPSIS
    Pick a drive and get an offline HTML report of how its files are laid out.

.DESCRIPTION
    DiskTrace 1.0.0 -- pure Windows PowerShell; no Python, no install.

    METADATA ONLY: DiskTrace NEVER opens files and NEVER reads file contents. It only lists directories and reads
    file system metadata (name, size, last-write date, attributes) through directory enumeration. Nothing on the
    scanned drive is changed.

    The scan is a small C# class compiled on the fly by Windows (Add-Type). Reparse points (junctions, symlinks)
    are listed but never followed. The page is a single self-contained HTML file that makes no network request
    (Content-Security-Policy default-src 'none'). Running as administrator reads more protected system folders;
    it is not required.

    The interface follows the Windows display language (pt-BR when Portuguese, English otherwise);
    -Language overrides it.

.EXAMPLE
    .\disktrace.ps1                      # arrow-key menu: Up/Down or W/S, Enter, Esc
.EXAMPLE
    .\disktrace.ps1 -Drive D -NoOpen     # no menu
.EXAMPLE
    .\disktrace.ps1 -Drive C:\Projects -UserProfile none -OutputDir C:\Reports -Language en
#>
param(
    [string]$OutputDir,
    [string]$Drive,                 # skip the menu: a drive letter (D, D:) or any folder
    [string]$UserProfile,           # skip profile detection; 'none' = do not list personal files
    [ValidateSet('', 'en', 'pt-BR')][string]$Language = '',
    [switch]$NoOpen
)
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------------------------- strings
if (-not $Language) { $Language = if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'pt*') { 'pt-BR' } else { 'en' } }
$Culture = [Globalization.CultureInfo]::GetCultureInfo($(if ($Language -eq 'pt-BR') { 'pt-BR' } else { 'en-US' }))
$Strings = @{
    'en' = @{
        menuHint = '  Up/Down or W/S to move · Enter to choose · Esc to quit'
        pickDrive = 'Choose a drive:'
        pickProfile = 'This drive has more than one user profile. Which one should be used to list personal files?'
        noLabel = '(no label)'; free = 'free'; noDrives = 'No drive found.'
        scanning = 'Scanning {0} (metadata only: names, sizes and dates; file contents are never read)...'; foldersRead = '  {0} folders read'
        building = 'Building the page...'
        done = 'Done in {0} s: {1} folders, {2} files, {3} protected folders could not be read.'
        pageAt = 'Page: {0} ({1} MB)'; pressEnter = 'Press Enter to exit'; outDir = 'DiskTrace'
        titleDrive = 'Drive {0} - {1}'; titleFolder = 'Folder {0}'; driveWord = 'drive'
        generated = 'DiskTrace · generated {0} · {1}'; dateFmt = 'yyyy-MM-dd HH:mm'
        capacity = 'capacity'; used = 'used'; freeCard = 'free'; filesCounted = 'files counted'; folders = 'folders'; largest = 'largest: '
        help = 'Click a folder to open it; "smaller items" opens too. The bar compares the size with the parent folder; hover to see the full path. Files are listed one by one when they are 100 MB or larger or sit in personal folders. Reparse points (junctions, links) are shown but not followed. Metadata only (names, sizes and dates): no file was opened and no file content was read. {0} folders could not be read (protected by the system) and are left out of the totals.'
        search = 'Search folder or file (Enter)'; collapse = 'Collapse all'
        js = @{ smaller = 'smaller items'; files = 'files'; none = 'Nothing found.'; link = 'shortcut'; locale = 'en-US' }
    }
    'pt-BR' = @{
        menuHint = '  ↑/↓ ou W/S para mover · Enter para escolher · Esc para sair'
        pickDrive = 'Escolha o disco:'
        pickProfile = 'Esse disco tem mais de um perfil de usuário. Qual usar para listar os arquivos pessoais?'
        noLabel = '(sem nome)'; free = 'livres'; noDrives = 'Nenhum disco encontrado.'
        scanning = 'Varrendo {0} (só metadados: nomes, tamanhos e datas; o conteúdo dos arquivos nunca é lido)...'; foldersRead = '  {0} pastas lidas'
        building = 'Montando a página...'
        done = 'Pronto em {0} s: {1} pastas, {2} arquivos, {3} pastas protegidas não lidas.'
        pageAt = 'Página: {0} ({1} MB)'; pressEnter = 'Enter para sair'; outDir = 'DiskTrace'
        titleDrive = 'Disco {0} - {1}'; titleFolder = 'Pasta {0}'; driveWord = 'disco'
        generated = 'DiskTrace · gerado em {0} · {1}'; dateFmt = 'dd/MM/yyyy HH:mm'
        capacity = 'capacidade'; used = 'usado'; freeCard = 'livre'; filesCounted = 'arquivos contados'; folders = 'pastas'; largest = 'maior: '
        help = 'Clique numa pasta para abrir; "itens menores" também abre. A barra compara o tamanho com a pasta de cima; passe o mouse para ver o caminho completo. Arquivos aparecem individualmente quando têm 100 MB ou mais ou estão nas pastas pessoais. Atalhos do sistema (junções, links) aparecem mas não são seguidos. Só metadados (nomes, tamanhos e datas): nenhum arquivo foi aberto e nenhum conteúdo foi lido. {0} pastas não puderam ser lidas (protegidas pelo sistema) e ficam de fora dos totais.'
        search = 'Buscar pasta ou arquivo (Enter)'; collapse = 'Recolher tudo'
        js = @{ smaller = 'itens menores'; files = 'arq.'; none = 'Nada encontrado.'; link = 'atalho'; locale = 'pt-BR' }
    }
}
$T = $Strings[$Language]
if (-not $OutputDir) { $OutputDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) $T.outDir }

# ------------------------------------------------------------------------------------------------- scanner (C#)
$cs = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
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
    public int Errors;
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
    public static DiskTraceScanner Run(string root, string profile, Action<int> progress)
    {
        var s = new DiskTraceScanner();
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
            try
            {
                foreach (var e in new DirectoryInfo(cur.Value).EnumerateFileSystemInfos())
                {
                    FileAttributes at;
                    try { at = e.Attributes; } catch { s.Errors++; continue; }
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
                    try { size = f.Length; t = f.LastWriteTimeUtc.Ticks; } catch { s.Errors++; continue; }
                    s.OwnFiles[idx]++; s.OwnBytes[idx] += size;
                    if (t > s.Newest[idx]) s.Newest[idx] = t;
                    if (size >= BigFile) { s.FileDir.Add(idx); s.FileName.Add(e.Name); s.FileSize.Add(size); s.FileTime.Add(t); }
                    else if (list)
                    {
                        top.Add(new Item { Size = size, Name = e.Name, Time = t });
                        if (top.Count > 4 * TopFiles) { top.Sort((a, b) => b.Size.CompareTo(a.Size)); top.RemoveRange(TopFiles, top.Count - TopFiles); }
                    }
                }
            }
            catch { s.Errors++; }
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

    static void Str(StringBuilder sb, string v)
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
    public string[] Paths;

    public void Aggregate()
    {
        int n = Names.Count;
        SubBytes = new long[n]; SubFiles = new long[n]; SubDirs = new long[n]; SubNewest = new long[n]; Paths = new string[n];
        for (int i = 0; i < n; i++) { SubBytes[i] = OwnBytes[i]; SubFiles[i] = OwnFiles[i]; SubNewest[i] = Newest[i]; }
        for (int i = n - 1; i > 0; i--)   // a child always has a larger index than its parent
        {
            int p = Parent[i];
            SubBytes[p] += SubBytes[i]; SubFiles[p] += SubFiles[i]; SubDirs[p] += 1 + SubDirs[i];
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

    // nodes: [id, parent, name, kind, bytes, files, subdirs, newest, note, ownBytes, ownFiles]; kind d=folder f=file l=link
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
            sb.Append(',').Append(OwnBytes[i]).Append(',').Append(OwnFiles[i]).Append(']');
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
}
'@
if (-not ('DiskTraceScanner' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

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
function row(id,pb){
 const n=byId[id],kind=n[3],el=document.createElement('div');el.className='w';
 const r=document.createElement('div');r.className='n '+kind;r.id='n'+id;r.title=full(id);
 const has=!!K[id]&&kind==='d';
 let h=`<span class="c">${has?'▸':''}</span><span class="nm">${esc(n[2])}</span>`+cols(n[4],pb,n[5],n[7],kind==='l',kind==='d');
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
 list.forEach((c,i)=>{(i<SHOW||(!more&&byId[c][4]>=pb*MINPCT)?show:rest).push(c);});
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
 d.innerHTML=esc(n[2])+' <span>— '+esc(n[1]>=0?full(n[1]):'')+' · '+(n[3]==='l'?L.link:hb(n[4]))+'</span>';d.onclick=()=>reveal(n[0]);R.appendChild(d);if(++c>=200)break;}}
 if(!c)R.textContent=L.none;};
document.getElementById('collapse').onclick=()=>{reset();document.getElementById('res').innerHTML='';};
'@

# ------------------------------------------------------------------------------------------------- helpers
function Format-Size([double]$n) {
    foreach ($u in @(@('TB', 1TB), @('GB', 1GB), @('MB', 1MB), @('KB', 1KB))) { if ($n -ge $u[1]) { return [string]::Format($Culture, '{0:N1} {1}', $n / $u[1], $u[0]) } }
    return [string]::Format($Culture, '{0} B', $n)
}
function Format-Count($n) { [string]::Format($Culture, '{0:N0}', $n) }
function Html([string]$s) { [Net.WebUtility]::HtmlEncode($s) }
function Js([string]$s) { '"' + ($s -replace '\\', '\\' -replace '"', '\"' -replace '<', '\u003c') + '"' }

function Select-Menu([string]$Title, [string[]]$Items) {
    # Arrow-key menu: returns the chosen index, or -1 on Esc
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host $T.menuHint -ForegroundColor DarkGray
    $sel = 0
    $width = [Math]::Max(10, [Console]::WindowWidth - 1)
    foreach ($it in $Items) { Write-Host '' }
    $top = [Console]::CursorTop - $Items.Count
    $cursor = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            for ($i = 0; $i -lt $Items.Count; $i++) {
                [Console]::SetCursorPosition(0, $top + $i)
                $line = ('  {0} {1}' -f $(if ($i -eq $sel) { '>' } else { ' ' }), $Items[$i])
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
                $line = $line.PadRight($width)
                if ($i -eq $sel) { Write-Host $line -NoNewline -ForegroundColor Black -BackgroundColor Cyan }
                else { Write-Host $line -NoNewline }
            }
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'W'         { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $sel = ($sel + 1) % $Items.Count }
                'S'         { $sel = ($sel + 1) % $Items.Count }
                'Home'      { $sel = 0 }
                'End'       { $sel = $Items.Count - 1 }
                'Enter'     { [Console]::SetCursorPosition(0, $top + $Items.Count); Write-Host ''; return $sel }
                'Escape'    { [Console]::SetCursorPosition(0, $top + $Items.Count); Write-Host ''; return -1 }
            }
        }
    }
    finally { [Console]::CursorVisible = $cursor }
}
function Finish([int]$code) { if (-not $Drive) { Read-Host $T.pressEnter | Out-Null }; exit $code }

# ------------------------------------------------------------------------------------------------- choose the drive
if ($Drive) {
    $root = if ($Drive -match '^[A-Za-z]:?$') { $Drive.Substring(0, 1).ToUpper() + ':\' } else { (Resolve-Path -LiteralPath $Drive).ProviderPath }
    $vol = Get-Volume -DriveLetter $root.Substring(0, 1) -ErrorAction SilentlyContinue
}
else {
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 } | Sort-Object DriveLetter)
    if (-not $vols) { Write-Host $T.noDrives; Finish 1 }
    $items = foreach ($v in $vols) {
        $disk = try { Get-Partition -DriveLetter $v.DriveLetter | Get-Disk } catch { $null }
        $name = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { $T.noLabel }
        [string]::Format($Culture, '{0}:  {1,-18} {2,8:N1} GB   {5} {3,8:N1} GB   {4}', $v.DriveLetter, $name, ($v.Size / 1GB), ($v.SizeRemaining / 1GB),
            $(if ($disk) { $disk.FriendlyName } else { '' }), $T.free)
    }
    $pick = Select-Menu $T.pickDrive @($items)
    if ($pick -lt 0) { exit 0 }
    $vol = $vols[$pick]
    $root = "$($vol.DriveLetter):\"
}
$driveRoot = $root.Substring(0, 2)

# user profile (its personal folders get their files listed)
if (-not $UserProfile) {
    $UserProfile = 'none'
    if ($driveRoot -ieq $env:SystemDrive) { $UserProfile = $env:USERPROFILE }
    else {
        $skip = 'Public', 'Default', 'Default User', 'All Users', 'WDAGUtilityAccount'
        $cands = @(Get-ChildItem "$driveRoot\Users" -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skip -notcontains $_.Name -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [IO.File]::Exists((Join-Path $_.FullName 'NTUSER.DAT')) } |
            Sort-Object LastWriteTime -Descending)
        if ($cands.Count -eq 1) { $UserProfile = $cands[0].FullName }
        elseif ($cands.Count -gt 1) {
            $pp = if ($Drive) { 0 } else { Select-Menu $T.pickProfile @($cands | ForEach-Object { $_.Name }) }
            if ($pp -lt 0) { exit 0 }
            $UserProfile = $cands[$pp].FullName
        }
    }
}

# ------------------------------------------------------------------------------------------------- scan and page
$t0 = Get-Date
Write-Host ''
Write-Host ($T.scanning -f $root) -ForegroundColor Cyan
$progress = [Action[int]] { param($n) Write-Host ($T.foldersRead -f (Format-Count $n)) }
$scan = [DiskTraceScanner]::Run($root, $UserProfile, $progress)
$scan.Aggregate()
Write-Host $T.building -ForegroundColor Cyan
$rootNoSlash = $root.TrimEnd('\')
$profRel = ''
if ($UserProfile -ne 'none' -and $UserProfile.Length -gt $rootNoSlash.Length -and $UserProfile.StartsWith($rootNoSlash, 'OrdinalIgnoreCase')) {
    $profRel = $UserProfile.Substring($rootNoSlash.Length).Trim('\')
}
$nodes = $scan.NodesJson($profRel, $(if ($Language -eq 'pt-BR') { 1 } else { 0 }))

$isFolder = $Drive -and $root.Length -gt 3
$label = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { $T.driveWord }
$title = if ($isFolder) { $T.titleFolder -f $root } else { $T.titleDrive -f $driveRoot, $label }
$cards = New-Object System.Collections.Generic.List[object]
if ($vol -and -not $isFolder) {
    $cards.Add(@((Format-Size $vol.Size), $T.capacity)); $cards.Add(@((Format-Size ($vol.Size - $vol.SizeRemaining)), $T.used)); $cards.Add(@((Format-Size $vol.SizeRemaining), $T.freeCard))
}
$cards.Add(@((Format-Count $scan.TotalFiles), $T.filesCounted)); $cards.Add(@((Format-Count ($scan.Names.Count - 1)), $T.folders))
foreach ($c in $scan.TopChildren(4)) { $p = $c.Split('|'); $cards.Add(@((Format-Size ([double]$p[1])), ($T.largest + $p[0]))) }
$cardsHtml = ($cards | ForEach-Object { '<div class="card"><b>' + (Html $_[0]) + '</b><span>' + (Html $_[1]) + '</span></div>' }) -join ''
$sub = $T.generated -f (Get-Date).ToString($T.dateFmt, $Culture), $root
$text = '{' + (($T.js.GetEnumerator() | ForEach-Object { (Js $_.Key) + ':' + (Js $_.Value) }) -join ',') + '}'

$html = '<!doctype html><html lang="' + $Language + '"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''; script-src ''unsafe-inline''">' +
        '<title>' + (Html $title) + '</title><style>' + $css + '</style></head><body><header><h1>' + (Html $title) + '</h1><div class="sub">' + (Html $sub) +
        '</div><div class="cards">' + $cardsHtml + '</div></header><section class="help">' + (Html ($T.help -f $scan.Errors)) + '</section>' +
        '<div class="tools"><input id="q" placeholder="' + (Html $T.search) + '"><button id="collapse">' + (Html $T.collapse) + '</button></div>' +
        '<div id="res"></div><main id="tree"></main><script>const DATA={"nodes":' + $nodes + ',"text":' + $text + '};' + "`n" + $js + '</script></body></html>'

New-Item -ItemType Directory -Force $OutputDir | Out-Null
$out = Join-Path $OutputDir ('disktrace-{0}-{1}-{2}.html' -f $driveRoot.Substring(0, 1), ($label -replace '[^\w-]', '_'), (Get-Date -Format 'yyyy-MM-dd_HHmm'))
[IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding($false)))
Write-Host ($T.done -f ([int]((Get-Date) - $t0).TotalSeconds), (Format-Count ($scan.Names.Count - 1)), (Format-Count $scan.TotalFiles), $scan.Errors) -ForegroundColor Green
Write-Host ($T.pageAt -f $out, ([string]::Format($Culture, '{0:N1}', (Get-Item -LiteralPath $out).Length / 1MB)))
if (-not $NoOpen) { Invoke-Item -LiteralPath $out }
Finish 0
