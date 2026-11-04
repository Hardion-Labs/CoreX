# Formato de Projeto — arquivo `.corex`

O arquivo `.corex` é o **ponto de entrada** de um projeto CoreXEngine. É um
documento JSON UTF-8 que descreve o projeto e aponta para seus recursos. A engine
o recebe via `--project` e o valida antes de carregar qualquer conteúdo.

A engine **não cria** arquivos `.corex`. A criação de projetos é responsabilidade
do CoreXHub (ou de ferramenta externa). A engine apenas lê e valida.

## Estrutura

```json
{
  "format_version": 1,
  "name": "MyGame",
  "id": "3f2b8c1e-9d4a-4e7b-8c1e-9d4a4e7b8c1e",
  "engine_version": "0.1.0",
  "initial_scene": "scenes/main.scene",
  "asset_directories": ["assets"],
  "script_directories": ["scripts"]
}
```

## Campos

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `format_version` | inteiro | sim | Versão do formato do manifesto. Atualmente suportada: `1`. |
| `name` | string | sim | Nome de exibição do projeto. Não vazio, sem separadores de caminho nem caracteres de controle. |
| `id` | string | não | Identificador estável do projeto (ex.: UUID). Atribuído por quem cria o projeto (Hub). A engine não o gera. |
| `engine_version` | string (semver) | sim | Versão da engine para a qual o projeto foi criado. Usada na verificação de compatibilidade. |
| `initial_scene` | string | não | Cena inicial, relativa à raiz do projeto. Padrão: nenhuma (o editor/runtime prepara uma cena vazia). |
| `asset_directories` | array de string | não | Diretórios de assets, relativos à raiz. Padrão: `["assets"]`. |
| `script_directories` | array de string | não | Diretórios de scripts, relativos à raiz. Padrão: `["scripts"]`. |

Campos desconhecidos são rejeitados na validação estrita para evitar erros
silenciosos de digitação. Versões futuras do formato poderão adicionar campos;
isso sempre incrementa `format_version`.

## Regras de caminho

Todos os caminhos dentro do manifesto (`initial_scene`, `asset_directories`,
`script_directories`) devem ser:

- **Relativos** à raiz do projeto (o diretório que contém o `.corex`).
- Livres de travessia (`..` não é permitido em nenhum componente).
- Livres de caminhos absolutos.
- Não vazios.

Essas regras existem para que um projeto não possa referenciar arquivos fora da
sua própria raiz. A engine rejeita o manifesto (código de saída 3) se qualquer
caminho violar essas regras.

A raiz do projeto é o diretório que contém o arquivo `.corex`. Por exemplo, para
`/path/MyGame/MyGame.corex`, a raiz é `/path/MyGame`.

## Compatibilidade de versão

O campo `engine_version` é comparado com a versão da engine em execução usando a
política de [versioning.md](versioning.md). Projetos incompatíveis são rejeitados
com código de saída 4. A engine não tenta instalar nem selecionar outra versão.

## Exemplo mínimo

```json
{
  "format_version": 1,
  "name": "MyGame",
  "engine_version": "0.1.0"
}
```

Com o manifesto mínimo, a engine usa `asset_directories = ["assets"]`,
`script_directories = ["scripts"]` e nenhuma cena inicial explícita.

## Estabilidade

`format_version = 1` é o contrato atual. Mudanças incompatíveis no formato
incrementam `format_version`. A engine suporta apenas as versões de formato que
declara explicitamente; versões desconhecidas são rejeitadas.
