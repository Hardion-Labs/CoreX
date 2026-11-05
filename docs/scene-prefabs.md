# Prefabs de Cena — CoreXEngine

Prefabs são subárvores de entidades reutilizáveis e versionadas. Eles permitem
capturar um trecho de uma cena (por exemplo, um inimigo com filhos e
componentes) e instanciá-lo várias vezes em outras cenas, com IDs estáveis
remapeados e hierarquia/componentes copiados por valor.

> Estado: **implementado e testado**. Prefabs reutilizam o formato de cena
> (`format_version = 1`) e o ECS; não duplicam serialização nem armazenamento.
> Streaming de cena, change tracking e gerenciamento de múltiplas cenas continuam
> planejados.

## Formato `.prefab`

Um arquivo `.prefab` (ou `.corexprefab`) é um documento JSON estrito com a mesma
forma de um `.scene` (ver [scene-format.md](scene-format.md)), mas com **exatamente
uma entidade raiz** (uma entidade sem `parent`). Documentos com zero ou múltiplas
raízes são rejeitados com `error.InvalidPrefab`.

```json
{
  "format_version": 1,
  "name": "enemy",
  "entities": [
    {
      "id": 1,
      "name": "Root",
      "components": { "transform": { "position": [0, 1, 0] } }
    },
    { "id": 2, "name": "Child", "parent": 1 }
  ]
}
```

As mesmas regras de validação de cena se aplicam: campos desconhecidos/duplicados
rejeitados, IDs únicos > 0, pais existentes, sem ciclos, componentes plain-data e
nomes válidos. O schema padrão da engine é `corex.scene.EnginePrefab` (apenas
`transform`); ferramentas podem usar `Prefab(.{ Component(T, "nome"), ... })`.

## API

`corex.scene.Prefab(schemas)` (e `corex.scene.prefab`):

- `parse(gpa, bytes) !Prefab` — lê um documento prefab estrito.
- `load(gpa, io, dir, path) !Prefab` — carrega relativo ao projeto (caminho seguro).
- `fromScene(gpa, source, root_entity, opt_name) !Prefab` — captura a subárvore
  enraizada em `root_entity` de uma cena viva. A cena de origem não é alterada; o
  pai original da raiz capturada é descartado.
- `instantiate(target, parent_id) !ecs.Entity` — instancia no `target` (mesmo
  schema), anexando a raiz clonada a `parent_id` (ou como raiz se `null`). Retorna
  o handle da nova raiz.
- `serialize(gpa) ![]u8` / `save(io, dir, path)` — serialização determinística
  (mesmo layout de cena, entidades em ordem crescente de ID).
- `deinit`, `count`, `root`, `name`, `root_id`.

A base é `Scene.cloneSubtree(source, root_id, parent_id)`, que também está
disponível diretamente em qualquer `Scene(schemas)` para composição de cenas.

## Garantias

- **Remapeamento de IDs**: a instanciação aloca novos IDs estáveis no target em
  ordem crescente de ID da origem, então é determinística e nunca colide com IDs
  existentes. Links de `parent` dentro da subárvore são remapeados; a raiz clonada
  é anexada ao `parent_id` solicitado.
- **Cópia por valor**: componentes são plain-data e copiados por valor; instâncias
  múltiplas são independentes (mutar uma não afeta outra nem o prefab).
- **Atomicidade em erro**: se qualquer etapa falhar (por exemplo, componente
  inválido ou falha de alocação), as entidades criadas pela chamada são
  destruídas e o target permanece inalterado, exceto pelo avanço monotônico de
  IDs (IDs nunca são reutilizados).
- **Hierarquia profunda**: a coleta da subárvore é iterativa (sem recursão),
  segura para hierarquias arbitrariamente profundas.
- **Segurança de memória**: allocators explícitos, propriedade documentada,
  sondas `checkAllAllocationFailures` e teste de rollback em falha de componente.

## Integração com assets

`AssetKind.prefab` classifica `.prefab`/`.corexprefab`. O `engineRegistry()`
inclui o importer `prefab` (id `prefab`, versão 1), que valida o documento
(single-root) e o re-serializa canonicamente antes de armazenar no cache
endereçado por conteúdo. Prefabs participam do pipeline/cache/GC como qualquer
outro asset.

```zig
const corex = @import("corex");
const A = corex.assets;
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "prefab", kind == .prefab
```

## Exemplo

```zig
const corex = @import("corex");
const S = corex.scene;

var prefab = try S.EnginePrefab.parse(gpa, prefab_bytes);
defer prefab.deinit();

var level = try S.EngineScene.init(gpa, "level");
defer level.deinit();
const anchor = try level.createEntity("Anchor", null);

const a = try prefab.instantiate(&level, level.idOf(anchor));
const b = try prefab.instantiate(&level, level.idOf(anchor));
// a e b são raízes independentes, cada uma com sua subárvore clonada.

// Capturar um prefab a partir de uma cena viva:
var captured = try S.EnginePrefab.fromScene(gpa, &level, a, "captured");
defer captured.deinit();
const bytes = try captured.serialize(gpa);
defer gpa.free(bytes);
```

## Limitações e próximos passos

- Prefabs não têm overrides por instância nem variantes aninhadas (prefab dentro
  de prefab com edição); a instanciação é uma cópia por valor completa.
- Não há referências cruzadas entre entidades via componentes (componentes são
  plain-data; IDs de entidade em componentes não são remapeados automaticamente).
- Streaming de cena, change tracking e multi-scene management continuam planejados.

## Relacionados

- Formato de cena: [scene-format.md](scene-format.md)
- Transforms world-space: [scene-transforms.md](scene-transforms.md)
- Importação e cache: [asset-import.md](asset-import.md)
- Arquitetura: [architecture.md](architecture.md)
