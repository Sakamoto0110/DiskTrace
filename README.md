# DiskTrace

[English](#english) · [Português](#português)

## English

Pick drives, get offline HTML reports of how their files are laid out, take dated snapshots, and see what changed
between them.

DiskTrace maps storage *layout* (what takes space, and where). It does not trace disk I/O.

> [!IMPORTANT]
> **DiskTrace reads metadata only. It never opens a file and never reads file contents.**
> It enumerates directories and reads, for each entry, only what the file system already reports in the directory
> listing: name, size, last-write date and attributes. No file is opened, read, hashed or modified, and nothing on
> the scanned drive is changed. Reports and snapshots therefore contain file and folder *names* (keep them private
> if your names are sensitive), but never anything that is inside a file.

- **One file, no dependencies.** Pure Windows PowerShell 5.1 (the one that ships with Windows); also runs on
  PowerShell 7. The scan is a small C# class that Windows compiles on the fly with `Add-Type`. No Python, nothing
  to install.
- **Metadata only, read-only.** See above. Junctions and symbolic links are listed but never followed.
- **Offline.** Every page is a single self-contained HTML file with a `Content-Security-Policy` of
  `default-src 'none'`: no fonts, scripts or images are loaded, and the page cannot make network requests.
- **Readable.** Dark theme and a lazy tree view: folder names only (the full path shows on hover), size bars,
  file counts, newest date, short notes on well-known Windows folders, a search box, and small folders grouped
  into an expandable "smaller items" row.
- **Snapshots and analysis.** Dated snapshots of each drive, and a page that shows what grew, shrank, appeared,
  disappeared or moved over a period.
- **Nothing hidden.** Folders that cannot be opened are listed at the top of the report (see below).
- **English and Portuguese.** Follows the Windows display language (`pt-BR` when Portuguese, English otherwise).

### Usage

> [!TIP]
> **Downloaded the zip?** Windows marks files from the internet, and may show a security warning the first time.
> Before extracting, right-click the zip → **Properties** → check **Unblock** → **OK**. Or, in PowerShell, from the
> extracted folder: `Get-ChildItem -Recurse | Unblock-File`.

Double-click `disktrace.cmd`. The menu offers:

| Option | What it does |
|---|---|
| Build a report now | Scans the chosen drives and opens one report per drive |
| Take a snapshot ◄ summary / full ► | Scans the chosen drives and saves a dated snapshot of each |
| Take a snapshot and open the report | Both, from a single scan |
| Analysis ◄ period ► | Compares snapshots: since the last one, the last 7, 30, 90, 180 or 360 days, or everything |

Up/Down (or W/S) picks an option, Left/Right (or A/D) changes its value, Enter confirms. In the drive list, Space
marks a drive, Shift+Up/Down marks several in a row, and the first row, **All drives**, marks them all; Enter with
nothing marked takes the highlighted drive. Reports are saved to `Documents\DiskTrace`.

```powershell
.\disktrace.ps1                                     # menu
.\disktrace.ps1 -Drive D -NoOpen                    # report, no menu
.\disktrace.ps1 -Drive all -Snapshot                # summary snapshot of every fixed drive
.\disktrace.ps1 -Drive C,D -Snapshot -Full -Report  # full snapshots of C and D, plus their reports
.\disktrace.ps1 -Analyze 30                         # what changed in the last 30 days, every drive with snapshots
.\disktrace.ps1 -Drive C:\Projects -UserProfile none -OutputDir C:\Reports -Language en
```

| Parameter | Meaning |
|---|---|
| `-Drive` | Drive letters (`D`, `D:`, `C,D`), `all`, or one folder (reports only); skips the menu |
| `-Snapshot` | Save a snapshot instead of a report; add `-Report` for both |
| `-Full` | Full snapshot: name, size and date of every file |
| `-Analyze` | `last`, `7`, `30`, `90`, `180`, `360` or `all`: build the analysis page |
| `-KeepFull` | Keep only the newest N full snapshots per drive; older ones go to the Recycle Bin. Default `0` keeps all |
| `-SnapshotDir` | Where snapshots are kept. Default: `%LOCALAPPDATA%\DiskTrace\snapshots` |
| `-UserProfile` | Profile folder whose personal files are listed individually; `none` lists none. Default: your profile on the system drive, or the profile found on the chosen drive |
| `-OutputDir` | Where pages are written |
| `-Language` | `en` or `pt-BR`; default follows Windows |
| `-NoOpen` | Do not open the browser at the end |

Running as administrator reads more protected system folders; it is not required.

### Snapshots

Snapshots are kept in `%LOCALAPPDATA%\DiskTrace\snapshots`, one folder per volume. A volume is identified by its
volume ID, not by its letter, so a drive that changes letter keeps its history. Each snapshot is a gzip-compressed,
tab-separated text file named by date, for example `2026-10-28_201302.summary.tsv.gz`.

| Mode | Contents | Size (example: 1.4 million files) |
|---|---|---|
| summary | Per-folder totals (size, file count, newest date) and files of 100 MB or more | about 3 MB |
| full | Per-folder totals and the name, size and date of every file | about 22 MB |

A full snapshot is the list of every file name on the drive: still metadata only, but keep it private.

For regular snapshots, create a task in Task Scheduler that runs
`powershell -NoProfile -ExecutionPolicy Bypass -File <path>\disktrace.ps1 -Drive all -Snapshot -NoOpen`.

### Analysis

The analysis compares the newest snapshot of each drive with the snapshot at the start of the period: the newest one
taken on or before that date. If no snapshot is that old, the oldest one is used and the page says so.

- Cards: change in used space and in what the scan counted, new and removed folders, and, when both snapshots are
  full, new, removed, changed and moved files.
- A chart of used space over the snapshots in the period.
- The folders whose own files grew or shrank the most.
- A tree with only what changed: green grew, red shrank, size before → after, change in file count, and labels for
  new, removed and moved items. A file that disappeared and reappeared elsewhere with the same name, size and date
  is shown as moved.

When one of the two snapshots is a summary, changes are shown per folder. The page also warns when the two
snapshots differ in which folders could be opened (for example, one taken as administrator).

### Folders that cannot be opened

Nothing is hidden. Every folder DiskTrace could not open (usually protected by Windows) is listed at the top of the
report, with the reason, and marked with 🔒 in the tree; each parent folder shows how many sit below it. Their size
is unknown, so it is left out of the totals. For a whole drive, a "used, not seen by the scan" card shows the used
space minus what the scan added up (unopened folders, NTFS metadata, restore points); hard links and compressed
files are counted at full size, which makes that number smaller.

### What is listed individually

Every folder is in the report. Files are listed one by one when they are 100 MB or larger, or when they sit in the
user's personal folders (the 15 largest per folder, outside `AppData`, caches, `.git`, `node_modules` and build
output).

### Roadmap

- **Scheduled snapshots:** create the weekly task from the menu.

### License

[MIT](LICENSE)

## Português

Escolha discos, receba relatórios HTML offline de como os arquivos estão distribuídos, tire snapshots datados e veja
o que mudou entre eles.

O DiskTrace mapeia a *ocupação* do disco (o que ocupa espaço, e onde). Ele não rastreia leituras e gravações no disco.

> [!IMPORTANT]
> **O DiskTrace lê apenas metadados. Ele nunca abre arquivos e nunca lê o conteúdo deles.**
> Ele lista as pastas e lê, de cada item, só o que o próprio sistema de arquivos já informa na listagem: nome,
> tamanho, data da última alteração e atributos. Nenhum arquivo é aberto, lido, tem hash calculado ou é alterado, e
> nada no disco varrido é modificado. Por isso relatórios e snapshots contêm *nomes* de arquivos e pastas (guarde-os
> com cuidado se os nomes forem sensíveis), mas nunca nada do que está dentro de um arquivo.

- **Um arquivo, sem dependências.** Windows PowerShell 5.1 puro (o que já vem no Windows); também roda no
  PowerShell 7. A varredura é uma pequena classe C# que o Windows compila na hora com `Add-Type`. Sem Python, nada
  para instalar.
- **Só metadados, só leitura.** Veja acima. Junções e links simbólicos são listados, mas nunca seguidos.
- **Offline.** Toda página é um único arquivo HTML autocontido com `Content-Security-Policy` igual a
  `default-src 'none'`: nenhuma fonte, script ou imagem é carregada, e a página não consegue fazer requisições de
  rede.
- **Legível.** Tema escuro e árvore carregada sob demanda: só o nome das pastas (o caminho completo aparece ao
  passar o mouse), barras de tamanho, número de arquivos, data mais recente, notas curtas sobre pastas conhecidas do
  Windows, uma caixa de busca e pastas pequenas agrupadas numa linha "itens menores" que pode ser aberta.
- **Snapshots e análise.** Snapshots datados de cada disco, e uma página que mostra o que cresceu, diminuiu,
  apareceu, sumiu ou foi movido num período.
- **Nada escondido.** As pastas que não puderam ser abertas são listadas no topo do relatório (veja abaixo).
- **Inglês e português.** Segue o idioma de exibição do Windows (`pt-BR` quando português, inglês nos outros
  casos).

### Uso

> [!TIP]
> **Baixou o zip?** O Windows marca arquivos vindos da internet e pode mostrar um aviso de segurança na primeira
> vez. Antes de extrair, clique com o direito no zip → **Propriedades** → marque **Desbloquear** → **OK**. Ou, no
> PowerShell, dentro da pasta extraída: `Get-ChildItem -Recurse | Unblock-File`.

Dê dois cliques em `disktrace.cmd`. O menu oferece:

| Opção | O que faz |
|---|---|
| Gerar relatório agora | Varre os discos escolhidos e abre um relatório por disco |
| Tirar snapshot ◄ resumido / completo ► | Varre os discos escolhidos e salva um snapshot datado de cada um |
| Tirar snapshot e abrir relatório | Os dois, com uma única varredura |
| Análise ◄ período ► | Compara snapshots: desde o último, os últimos 7, 30, 90, 180 ou 360 dias, ou tudo |

↑/↓ (ou W/S) escolhe a opção, ←/→ (ou A/D) troca o valor dela, Enter confirma. Na lista de discos, Espaço marca um
disco, Shift+↑/↓ marca vários em sequência, e a primeira linha, **Todos os discos**, marca todos; Enter sem nada
marcado usa o disco destacado. Os relatórios ficam salvos em `Documentos\DiskTrace`.

```powershell
.\disktrace.ps1                                     # menu
.\disktrace.ps1 -Drive D -NoOpen                    # relatório, sem menu
.\disktrace.ps1 -Drive all -Snapshot                # snapshot resumido de todos os discos fixos
.\disktrace.ps1 -Drive C,D -Snapshot -Full -Report  # snapshots completos de C e D, mais os relatórios
.\disktrace.ps1 -Analyze 30                         # o que mudou nos últimos 30 dias, em todo disco com snapshots
.\disktrace.ps1 -Drive C:\Projetos -UserProfile none -OutputDir C:\Relatorios -Language pt-BR
```

| Parâmetro | Significado |
|---|---|
| `-Drive` | Letras de disco (`D`, `D:`, `C,D`), `all`, ou uma pasta (só relatórios); pula o menu |
| `-Snapshot` | Salva um snapshot em vez de um relatório; acrescente `-Report` para os dois |
| `-Full` | Snapshot completo: nome, tamanho e data de cada arquivo |
| `-Analyze` | `last`, `7`, `30`, `90`, `180`, `360` ou `all`: gera a página de análise |
| `-KeepFull` | Mantém só os N snapshots completos mais novos de cada disco; os mais antigos vão para a Lixeira. O padrão `0` mantém todos |
| `-SnapshotDir` | Onde os snapshots ficam. Padrão: `%LOCALAPPDATA%\DiskTrace\snapshots` |
| `-UserProfile` | Pasta de perfil cujos arquivos pessoais são listados individualmente; `none` não lista nenhum. Padrão: o seu perfil no disco do sistema, ou o perfil encontrado no disco escolhido |
| `-OutputDir` | Onde as páginas são gravadas |
| `-Language` | `en` ou `pt-BR`; o padrão segue o Windows |
| `-NoOpen` | Não abre o navegador no final |

Rodar como administrador lê mais pastas protegidas do sistema; não é obrigatório.

### Snapshots

Os snapshots ficam em `%LOCALAPPDATA%\DiskTrace\snapshots`, uma pasta por volume. O volume é identificado pelo ID
dele, não pela letra, então um disco que muda de letra mantém o histórico. Cada snapshot é um arquivo de texto
separado por tabulações e comprimido com gzip, com a data no nome, por exemplo
`2026-10-28_201302.summary.tsv.gz`.

| Modo | Conteúdo | Tamanho (exemplo: 1,4 milhão de arquivos) |
|---|---|---|
| resumido | Totais por pasta (tamanho, número de arquivos, data mais recente) e arquivos de 100 MB ou mais | cerca de 3 MB |
| completo | Totais por pasta e o nome, tamanho e data de cada arquivo | cerca de 22 MB |

Um snapshot completo é a lista de todos os nomes de arquivo do disco: continua sendo só metadados, mas guarde-o com
cuidado.

Para snapshots regulares, crie uma tarefa no Agendador de Tarefas que rode
`powershell -NoProfile -ExecutionPolicy Bypass -File <caminho>\disktrace.ps1 -Drive all -Snapshot -NoOpen`.

### Análise

A análise compara o snapshot mais novo de cada disco com o snapshot do início do período: o mais novo tirado até
aquela data. Se nenhum snapshot for tão antigo, usa o mais antigo que existir, e a página avisa.

- Cartões: mudança no espaço usado e no que a varredura somou, pastas novas e removidas e, quando os dois snapshots
  são completos, arquivos novos, removidos, alterados e movidos.
- Um gráfico do espaço usado ao longo dos snapshots do período.
- As pastas cujos próprios arquivos mais cresceram ou diminuíram.
- Uma árvore só com o que mudou: verde cresceu, vermelho diminuiu, tamanho antes → depois, mudança no número de
  arquivos, e marcas para itens novos, removidos e movidos. Um arquivo que sumiu e reapareceu em outro lugar com o
  mesmo nome, tamanho e data aparece como movido.

Quando um dos dois snapshots é resumido, as mudanças aparecem por pasta. A página também avisa quando os dois
snapshots diferem nas pastas que puderam ser abertas (por exemplo, um tirado como administrador).

### Pastas que não puderam ser abertas

Nada fica escondido. Toda pasta que o DiskTrace não conseguiu abrir (em geral protegida pelo Windows) é listada no
topo do relatório, com o motivo, e marcada com 🔒 na árvore; cada pasta acima dela mostra quantas existem lá dentro.
O tamanho delas é desconhecido, por isso fica de fora dos totais. Para um disco inteiro, o cartão "usado e não visto
pela varredura" mostra o espaço usado menos o que a varredura somou (pastas não abertas, metadados do NTFS, pontos de
restauração); hard links e arquivos comprimidos entram com o tamanho cheio, o que diminui esse número.

### O que é listado individualmente

Toda pasta está no relatório. Arquivos são listados um a um quando têm 100 MB ou mais, ou quando estão nas pastas
pessoais do usuário (os 15 maiores de cada pasta, fora `AppData`, caches, `.git`, `node_modules` e saídas de build).

### Próximos passos

- **Snapshots agendados:** criar a tarefa semanal pelo próprio menu.

### Licença

[MIT](LICENSE)
