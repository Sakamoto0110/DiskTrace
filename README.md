# DiskTrace

[English](#english) · [Português](#português)

## English

Pick a drive, get an offline HTML report of how its files are laid out.

DiskTrace maps storage *layout* (what takes space, and where). It does not trace disk I/O.

> [!IMPORTANT]
> **DiskTrace reads metadata only. It never opens a file and never reads file contents.**
> It enumerates directories and reads, for each entry, only what the file system already reports in the directory
> listing: name, size, last-write date and attributes. No file is opened, read, hashed or modified, and nothing on
> the scanned drive is changed. The report therefore contains file and folder *names* (keep it private if your
> names are sensitive), but never anything that is inside a file.

- **One file, no dependencies.** Pure Windows PowerShell 5.1 (the one that ships with Windows); also runs on
  PowerShell 7. The scan is a small C# class that Windows compiles on the fly with `Add-Type`. No Python, nothing
  to install.
- **Metadata only, read-only.** See above. Junctions and symbolic links are listed but never followed.
- **Offline.** The report is a single self-contained HTML file with a `Content-Security-Policy` of
  `default-src 'none'`: no fonts, scripts or images are loaded, and the page cannot make network requests.
- **Readable.** Dark theme and a lazy tree view: folder names only (the full path shows on hover), size bars,
  file counts, newest date, short notes on well-known Windows folders, a search box, and small folders grouped
  into an expandable "smaller items" row.
- **Nothing hidden.** Folders that cannot be opened are listed at the top of the report (see below).
- **English and Portuguese.** Follows the Windows display language (`pt-BR` when Portuguese, English otherwise).

### Usage

> [!TIP]
> **Downloaded the zip?** Windows marks files from the internet, and may show a security warning the first time.
> Before extracting, right-click the zip → **Properties** → check **Unblock** → **OK**. Or, in PowerShell, from the
> extracted folder: `Get-ChildItem -Recurse | Unblock-File`.

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

Running as administrator reads more protected system folders; it is not required.

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

- **Snapshots:** keep a compact, versioned snapshot of each scan (per-folder size, file count, newest date, large
  files) next to the report.
- **Deltas:** compare two snapshots, for example week over week: what grew, what shrank, what appeared or
  disappeared.
- **Scheduled scans:** an optional weekly scheduled task that takes a snapshot.

### License

[MIT](LICENSE)

## Português

Escolha um disco e receba um relatório HTML offline de como os arquivos estão distribuídos.

O DiskTrace mapeia a *ocupação* do disco (o que ocupa espaço, e onde). Ele não rastreia leituras e gravações no disco.

> [!IMPORTANT]
> **O DiskTrace lê apenas metadados. Ele nunca abre arquivos e nunca lê o conteúdo deles.**
> Ele lista as pastas e lê, de cada item, só o que o próprio sistema de arquivos já informa na listagem: nome,
> tamanho, data da última alteração e atributos. Nenhum arquivo é aberto, lido, tem hash calculado ou é alterado, e
> nada no disco varrido é modificado. Por isso o relatório contém *nomes* de arquivos e pastas (guarde-o com cuidado
> se os nomes forem sensíveis), mas nunca nada do que está dentro de um arquivo.

- **Um arquivo, sem dependências.** Windows PowerShell 5.1 puro (o que já vem no Windows); também roda no
  PowerShell 7. A varredura é uma pequena classe C# que o Windows compila na hora com `Add-Type`. Sem Python, nada
  para instalar.
- **Só metadados, só leitura.** Veja acima. Junções e links simbólicos são listados, mas nunca seguidos.
- **Offline.** O relatório é um único arquivo HTML autocontido com `Content-Security-Policy` igual a
  `default-src 'none'`: nenhuma fonte, script ou imagem é carregada, e a página não consegue fazer requisições de
  rede.
- **Legível.** Tema escuro e árvore carregada sob demanda: só o nome das pastas (o caminho completo aparece ao
  passar o mouse), barras de tamanho, número de arquivos, data mais recente, notas curtas sobre pastas conhecidas do
  Windows, uma caixa de busca e pastas pequenas agrupadas numa linha "itens menores" que pode ser aberta.
- **Nada escondido.** As pastas que não puderam ser abertas são listadas no topo do relatório (veja abaixo).
- **Inglês e português.** Segue o idioma de exibição do Windows (`pt-BR` quando português, inglês nos outros
  casos).

### Uso

> [!TIP]
> **Baixou o zip?** O Windows marca arquivos vindos da internet e pode mostrar um aviso de segurança na primeira
> vez. Antes de extrair, clique com o direito no zip → **Propriedades** → marque **Desbloquear** → **OK**. Ou, no
> PowerShell, dentro da pasta extraída: `Get-ChildItem -Recurse | Unblock-File`.

Dê dois cliques em `disktrace.cmd`, escolha o disco com as setas (ou W/S) e aperte Enter. O relatório abre no
navegador e fica salvo em `Documentos\DiskTrace`.

```powershell
.\disktrace.ps1                                     # menu
.\disktrace.ps1 -Drive D -NoOpen                    # sem menu
.\disktrace.ps1 -Drive C:\Projetos -UserProfile none -OutputDir C:\Relatorios -Language pt-BR
```

| Parâmetro | Significado |
|---|---|
| `-Drive` | Letra do disco (`D`, `D:`) ou qualquer pasta; pula o menu |
| `-UserProfile` | Pasta de perfil cujos arquivos pessoais são listados individualmente; `none` não lista nenhum. Padrão: o seu perfil no disco do sistema, ou o perfil encontrado no disco escolhido |
| `-OutputDir` | Onde o relatório é gravado |
| `-Language` | `en` ou `pt-BR`; o padrão segue o Windows |
| `-NoOpen` | Não abre o navegador no final |

Rodar como administrador lê mais pastas protegidas do sistema; não é obrigatório.

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

- **Snapshots:** guardar uma foto compacta e versionada de cada varredura (tamanho por pasta, número de arquivos,
  data mais recente, arquivos grandes) junto do relatório.
- **Deltas:** comparar dois snapshots, por exemplo de uma semana para outra: o que cresceu, o que diminuiu, o que
  apareceu ou sumiu.
- **Varreduras agendadas:** uma tarefa agendada semanal, opcional, que tira um snapshot.

### Licença

[MIT](LICENSE)
