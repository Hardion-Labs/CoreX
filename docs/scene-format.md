# Formato de Cena — arquivo `.scene`

Cenas da CoreXEngine são documentos JSON UTF-8 versionados. Elas descrevem
entidades, hierarquia e componentes armazenados no ECS. A engine **lê e valida**
cenas; a criação de projetos continua fora do escopo da engine (ver
[scope.md](scope.md)).

> Estado: `format_version = 1` implementado para o schema padrão da engine
> (`corex.scene.EngineScene`), que atualmente contém o componente `transform`.
> Ferramentas podem definir schemas adicionais com `Scene(.{ Component(T, "nome") })`.

## Estrutura

```json
{
  "format_version": 1,
  "name": "main",
  "entities": [
    {
      "id": 1,
      "name": "Root",
      "components": {
        "transform": {
          "position": [0, 0, 0],
          "rotation": [0, 0, 0, 1],
          "scale": [1, 1, 1]
        }
      }
    },
    {
      "id": 2,
      "name": "Child",
      "parent": 1,
      "components": {
        "transform": { "position": [0, 1, 0] }
      }
    }
  ]
}
```

## Campos da raiz

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `format_version` | inteiro | sim | Versão do formato de cena. Suportada: `1`. Versões desconhecidas são rejeitadas. |
| `name` | string | sim | Nome de exibição da cena. Não vazio, até 128 bytes, sem caracteres de controle nem separadores de caminho. |
| `entities` | array | não | Lista de entidades. Padrão: `[]` (cena vazia). |

## Campos de entidade

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `id` | inteiro > 0 | sim | Identificador estável da cena, único no documento. Nunca é reutilizado pela engine ao criar novas entidades em runtime. |
| `name` | string | não | Nome de exibição. Mesmas regras do nome da cena. |
| `parent` | inteiro > 0 | não | `id` da entidade pai. Deve existir, não pode ser a própria entidade e não pode formar ciclo. |
| `components` | objeto | não | Componentes tipados. Padrão: `{}`. |

Campos desconhecidos e campos duplicados são rejeitados (JSON estrito).

## Componente `transform`

Componente local da entidade em relação ao pai (ou à raiz da cena). Todos os
campos são opcionais e usam os valores identidade quando ausentes:

| Campo | Tipo | Padrão | Descrição |
|---|---|---|---|
| `position` | `[f32, f32, f32]` | `[0, 0, 0]` | Posição local. |
| `rotation` | `[f32, f32, f32, f32]` | `[0, 0, 0, 1]` | Quaternion `[x, y, z, w]`. |
| `scale` | `[f32, f32, f32]` | `[1, 1, 1]` | Escala local. |

Valores não finitos (NaN/Infinity) são rejeitados. A propagação de transform
world-space é uma extensão futura do sistema de cenas/renderização; o formato
armazena o transform local autoral.

## Regras de validação

- `format_version` deve ser `1`.
- Nomes seguem a regra compartilhada de nomes de exibição (manifesto e cenas).
- IDs de entidade devem ser únicos e maiores que zero.
- Pais devem referenciar entidades existentes; auto-parentesco e ciclos são
  rejeitados.
- Componentes desconhecidos para o schema carregado são rejeitados.
- O documento é limitado a 16 MiB e a 1.000.000 de entidades.
- Caminhos de cena vindos do manifesto/CLI continuam relativos à raiz do
  projeto, sem travessia (`..`), conforme [project-format.md](project-format.md).

## Inicialização

- `editor` e `runtime`: a cena inicial (manifesto ou `--scene`) é resolvida,
  validada e carregada no ECS. Se nenhuma cena for indicada, uma cena vazia é
  preparada. Falhas de cena produzem código de saída **6**.
- `validate`: não carrega cena; valida manifesto, compatibilidade, configurações
  e índice de assets. O contrato de inicialização permanece o mesmo
  ([launch-contract.md](launch-contract.md)).

## API e propriedade

`corex.scene.EngineScene` (ou `Scene(schema)`) é dono de sua arena, do mundo ECS
e dos mapas de ID. Chame `deinit` exatamente uma vez. `parse`/`load` retornam uma
cena owned; `serialize` retorna bytes owned. `save` escreve em caminho relativo
ao projeto e cria diretórios pais; não é atômico contra crash (quem precisar de
substituição atômica deve escrever um arquivo temporário e renomear).

Handles de entidade em runtime são handles geracionais do ECS; os IDs estáveis
do arquivo ficam em um mapeamento separado. Use `createEntity`/`destroyEntity` da
cena (não o mundo ECS bruto) para manter IDs e hierarquia consistentes. Destruir
uma entidade reparenta seus filhos diretos para o pai dela (ou para a raiz).

## Relacionados

- Arquitetura: [architecture.md](architecture.md)
- Formato de projeto: [project-format.md](project-format.md)
- Versionamento: [versioning.md](versioning.md)
- Contrato de inicialização: [launch-contract.md](launch-contract.md)
