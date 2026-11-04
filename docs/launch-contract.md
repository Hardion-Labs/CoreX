# Contrato de Inicialização — CoreXEngine

Este é o contrato estável de inicialização da CoreXEngine. Ele define como o
editor/runtime são iniciados, tanto diretamente pela linha de comando quanto
pelo CoreXHub. A integração com o Hub ocorre **exclusivamente** por este
contrato, pelos formatos documentados e por contratos de versão.

A engine **nunca** depende do Hub para executar. `--hub-launch` é apenas um
marcador informativo de origem; não habilita nenhum comportamento do qual a
engine precise para funcionar.

## Executável

O binário chama-se `corex-engine`.

```sh
corex-engine [opções]
```

## Argumentos

| Argumento | Valor | Descrição |
|---|---|---|
| `--project`, `-p` | caminho | Caminho do arquivo `.corex` (ponto de entrada do projeto). Aceita caminho absoluto ou relativo; relativo é resolvido para absoluto a partir do diretório de trabalho. Obrigatório nos modos `editor`, `runtime` e `validate`. |
| `--hub-launch` | — | Marcador informativo de que o processo foi iniciado pelo CoreXHub. Não cria dependência nem altera a independência da engine. |
| `--engine-version` | semver | Versão da engine que o Hub selecionou, apenas informativa. A engine registra e, se divergir da sua própria versão, emite um aviso. A engine **não** instala nem seleciona versões. |
| `--mode`, `-m` | `editor` \| `runtime` \| `validate` | Modo de inicialização. Padrão: `editor`. |
| `--scene` | caminho | Sobrescreve a cena inicial do manifesto. Caminho relativo ao projeto, sem `..`. |
| `--headless` | — | Força execução sem janela gráfica (splash/editor em modo headless, apenas log). O modo gráfico é planejado; enquanto a biblioteca GUI não existir, a execução é headless por padrão. |
| `--jobs` | inteiro > 0 | Número de workers do sistema de jobs. Padrão: núcleos lógicos menos um (mínimo 1). |
| `--log-level` | `error` \| `warn` \| `info` \| `debug` | Nível de log. Padrão: `info`. |
| `--version`, `-v` | — | Imprime a versão da engine e sai com código 0. |
| `--help`, `-h` | — | Imprime a ajuda e sai com código 0. |

Argumentos desconhecidos, valores ausentes ou modos inválidos resultam em erro
de uso (código de saída 2).

### Modos

- **`editor`** (padrão): executa a sequência completa de inicialização e abre a
  sessão do editor. Enquanto o editor gráfico não estiver implementado, a sessão
  é aberta em modo headless e a prontidão é reportada.
- **`runtime`**: executa a inicialização e prepara a sessão de runtime do
  projeto (sem editor).
- **`validate`**: valida manifesto, compatibilidade, configurações e índice de
  assets, e sai. Não prepara cena nem abre editor. Útil para o Hub e para CI.

## Exemplos

Iniciar pelo Hub:

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --hub-launch
```

Iniciar diretamente o editor:

```sh
corex-engine --project "/path/MyGame/MyGame.corex"
```

Validar um projeto (sem abrir editor):

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --mode validate
```

Executar o runtime em modo headless com 4 workers:

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --mode runtime --headless --jobs 4
```

## Sequência de inicialização

Ao receber um projeto, a engine executa, nesta ordem:

1. **Inicializar serviços essenciais** — jobs, logging, diagnóstico.
2. **Abrir splash screen** — reporta progresso da inicialização (headless por
   enquanto; splash gráfico é planejado).
3. **Validar manifesto e compatibilidade** — lê o `.corex`, valida formato e
   campos, e verifica compatibilidade de versão com a engine.
4. **Carregar configurações em workers** — carrega as configurações do projeto
   de forma assíncrona no sistema de jobs.
5. **Indexar assets** — varre os diretórios de assets e constrói o índice.
6. **Preparar a cena inicial** — resolve e verifica a cena inicial (manifesto ou
   `--scene`). Não se aplica ao modo `validate`.
7. **Abrir o editor gráfico** — abre a sessão do editor (ou prepara o runtime no
   modo `runtime`). Não se aplica ao modo `validate`.

Falhas em qualquer etapa interrompem a sequência e produzem o código de saída
correspondente. A splash screen é fechada em todos os caminhos de saída.

## Códigos de saída

| Código | Significado |
|---|---|
| 0 | Sucesso. |
| 1 | Erro interno inesperado. |
| 2 | Uso inválido da linha de comando (argumento desconhecido, valor ausente, modo inválido, projeto ausente quando obrigatório). |
| 3 | Manifesto do projeto inválido (JSON malformado, campo obrigatório ausente, `format_version` não suportado, caminho inseguro). |
| 4 | Versão do projeto incompatível com a engine. |
| 5 | Projeto não encontrado ou erro de E/S ao lê-lo. |
| 6 | Falha ao preparar configurações, assets ou cena inicial. |

Os códigos de saída fazem parte do contrato estável e não devem ser reordenados
ou reutilizados com outro significado.

## Independência do Hub

- A engine não cria, registra, lista nem gerencia projetos.
- A engine não instala, seleciona nem gerencia versões da engine.
- A engine não mantém catálogo de projetos recentes.
- A engine não chama o Hub, não lê configuração do Hub e não requer que o Hub
  esteja presente.
- Toda comunicação do Hub para a engine ocorre por argumentos de inicialização
  e pelos formatos de arquivo documentados.

## Relacionados

- Formato do projeto: [project-format.md](project-format.md)
- Versionamento e compatibilidade: [versioning.md](versioning.md)
- Escopo: [scope.md](scope.md)
