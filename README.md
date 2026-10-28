# DiskTrace

Pick a drive, get an offline HTML report of how its files are laid out.

DiskTrace maps storage *layout* (what takes space, and where). It does not trace disk I/O.

- **One file, no dependencies.** Pure Windows PowerShell 5.1 (the one that ships with Windows); also runs on
  PowerShell 7. The scan is a small C# class that Windows compiles on the fly with `Add-Type`. No Python, nothing
  to install.
- **Read-only.** Only names, sizes and dates are read. No file is opened and nothing on the scanned drive changes.
  Junctions and symbolic links are listed but never followed.
- **Offline.** The report is a single self-contained HTML file with a `Content-Security-Policy` of
  `default-src 'none'`: no fonts, scripts or images are loaded, and the page cannot make network requests.
- **Readable.** Dark theme and a lazy tree view: folder names only (the full path shows on hover), size bars,
  file counts, newest date, short notes on well-known Windows folders, a search box, and small folders grouped
  into an expandable "smaller items" row.
- **English and Portuguese.** Follows the Windows display language (`pt-BR` when Portuguese, English otherwise).

## Usage

Double-click `disktrace.cmd`, choose a drive with the arrow keys (or W/S) and press Enter. The report opens in the
browser and is saved to `Documents\DiskTrace`.

```powershell
.\disktrace.ps1                                     # menu
.\disktrace.ps1 -Drive D -NoOpen                    # no menu
.\disktrace.ps1 -Drive C:\Projects -UserProfile none -OutputDir C:\Reports -Language en
```

| Parameter | Meaning |
|---|---|
| `-Drive` | Drive letter (`D`, `D:`) or any folder; skips the menu |
| `-UserProfile` | Profile folder whose personal files are listed individually; `none` lists none. Default: your profile on the system drive, or the profile found on the chosen drive |
| `-OutputDir` | Where the report is written |
| `-Language` | `en` or `pt-BR`; default follows Windows |
| `-NoOpen` | Do not open the browser at the end |

Running as administrator reads more protected system folders; it is not required. Folders that cannot be read are
counted and left out of the totals.

### What is listed individually

Every folder is in the report. Files are listed one by one when they are 100 MB or larger, or when they sit in the
user's personal folders (the 15 largest per folder, outside `AppData`, caches, `.git`, `node_modules` and build
output).

## Roadmap

- **Snapshots:** keep a compact, versioned snapshot of each scan (per-folder size, file count, newest date, large
  files) next to the report.
- **Deltas:** compare two snapshots, for example week over week: what grew, what shrank, what appeared or
  disappeared.
- **Scheduled scans:** an optional weekly scheduled task that takes a snapshot.

## License

[MIT](LICENSE)

## Português

Escolha um disco e receba um relatório HTML offline de como os arquivos estão distribuídos. O DiskTrace mostra a
*ocupação* do disco, não rastreia leituras e gravações. Dê dois cliques em `disktrace.cmd`, escolha o disco com as
setas (ou W/S) e Enter. O relatório abre no navegador e fica em `Documentos\DiskTrace`. Só lê nomes, tamanhos e
datas, não abre arquivos, não segue atalhos do sistema e a página não acessa a rede. A interface segue o idioma do
Windows; `-Language pt-BR` ou `-Language en` força. Próximos passos: guardar uma foto de cada varredura e comparar
fotos para ver o que mudou entre semanas.
