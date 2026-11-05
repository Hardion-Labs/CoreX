# Transforms World-Space — CoreXEngine

Este documento descreve a propagação de transforms locais para o espaço de mundo
(world-space) das cenas da CoreXEngine. A matemática vive em
`src/scene/transform.zig` e é exposta como `corex.scene.transform` (com os tipos
`corex.scene.Mat4`, `Vec3` e `Quat`). Os métodos de cena ficam em
`src/scene/scene.zig` (`Scene.computeWorldTransforms` e `Scene.worldMatrix`).

> Estado: **implementado e testado**. O arquivo `.scene` continua armazenando
> apenas o transform **local** autoral (TRS, `format_version = 1`); matrizes
> world-space são **calculadas em runtime** e nunca serializadas. Isso preserva o
> contrato do formato de cena (ver [scene-format.md](scene-format.md)).

## Por que matrizes (e não TRS componente a componente)

Compor dois transforms combinando posição/rotação/escala componente a componente
perde cisalhamento (shear) quando há **escala não uniforme sob rotação**. Por
isso a propagação usa matrizes 4×4 completas:

```
world_filho = world_pai * local_filho
```

onde `local_filho = T * R * S` (escala aplicada primeiro, depois rotação, depois
translação). Multiplicação de matrizes preserva o shear corretamente em qualquer
profundidade de hierarquia.

## Convenções matemáticas

- `Mat4 = [16]f32`, **column-major**: o elemento da linha `r`, coluna `c` é
  `m[c*4 + r]`. Compatível com o layout esperado por APIs gráficas column-major.
- `Vec3 = [3]f32`; `Quat = [4]f32` no formato `[x, y, z, w]`.
- `transform.identity()` retorna a matriz identidade.
- `transform.fromTransform(t)` constrói `M = T * R * S` a partir de um
  `Transform` local. O quaternion é **normalizado** internamente; um quaternion
  de comprimento zero é tratado como identidade.
- `transform.multiply(a, b)` retorna `a * b`.
- `transform.transformPoint(m, v)` aplica `m` a um ponto (translação incluída);
  `transform.transformDirection(m, v)` aplica apenas a parte linear (sem
  translação), útil para direções/normais.
- Helpers de quaternion: `quatNormalize`, `quatMultiply`, `quatRotateVec3`,
  `quatFromAxisAngle`.
- `transform.approxEqual(a, b, epsilon)` compara matrizes com tolerância absoluta
  (útil em testes; não usar como igualdade exata em lógica de jogo).

## API da cena

### `Scene.computeWorldTransforms(gpa) Error!WorldTransforms`

Calcula as matrizes world-space de **todas** as entidades vivas em uma única
passada **iterativa** O(n) (pais antes dos filhos). Não usa recursão, portanto
hierarquias arbitrariamente profundas são seguras (sem risco de stack overflow).
Entidades sem o componente `Transform` usam o transform local identidade.
Requer que o schema da cena contenha `Transform` (caso contrário, erro de
compilação). O chamador é dono do snapshot e deve chamar `deinit`.

Este é o caminho recomendado por frame: calcule uma vez após os transforms
mudarem e consulte muitas entidades via `WorldTransforms.get`.

### `WorldTransforms` (snapshot)

- `matrices: []Mat4` e `entities: []Entity` — arrays densos paralelos, ordenados
  por **ID estável crescente** (determinismo).
- `count() usize` — número de entidades no snapshot.
- `get(entity) ?Mat4` — matriz world-space de um handle presente no snapshot, ou
  `null` para um handle ausente.
- `deinit()` — libera os arrays e o índice.

O snapshot é **congelado**: é válido até a hierarquia ou os transforms locais
mudarem; recalcule para atualizar. Ele é **generation-safe**: um slot reciclado
com nova geração não consegue ler a matriz da entidade anterior (o handle novo
não está no snapshot). Um handle que estava vivo no momento do cálculo continua
retornando a sua própria matriz congelada mesmo se a entidade for destruída
depois — isso é dado da própria entidade, não de outra.

### `Scene.worldMatrix(gpa, entity) Error!Mat4`

Conveniência para uma única entidade: sobe a cadeia de pais até a raiz e compõe
de cima para baixo. Aloca um buffer temporário de cadeia; para uso por frame
sobre muitas entidades prefira `computeWorldTransforms`. Retorna
`error.EntityNotAlive` para um handle morto. Requer `Transform` no schema.

## Exemplo

```zig
const corex = @import("corex");
const gpa = allocator;

var scene = try corex.scene.EngineScene.init(gpa, "main");
defer scene.deinit();

const root = try scene.createEntity("Root", null);
try scene.addComponent(root, corex.scene.Transform{
    .position = .{ 10, 0, 0 },
    .scale = .{ 2, 2, 2 },
});
const child = try scene.createEntity("Child", scene.idOf(root));
try scene.addComponent(child, corex.scene.Transform{ .position = .{ 1, 0, 0 } });

// Lote (recomendado por frame):
var wt = try scene.computeWorldTransforms(gpa);
defer wt.deinit();
if (wt.get(child)) |world| {
    const origem = corex.scene.transform.transformPoint(world, .{ 0, 0, 0 });
    // origem == { 12, 0, 0 }  (root * child * origem)
}

// Unidade única:
const m = try scene.worldMatrix(gpa, child);
```

## Garantias e testes

- **Determinismo**: a ordem densa é por ID estável crescente; snapshots idênticos
  para a mesma cena.
- **Sem recursão**: avaliação topológica iterativa com pilha explícita no heap;
  um teste de estresse com cadeia de 2000 níveis valida propagação correta sem
  stack overflow.
- **Generation-safe**: handles reciclados não leem dados de entidades anteriores.
- **Identidade para entidades sem Transform**: a entidade herda o world do pai.
- **Referências de pai para frente**: pais definidos depois dos filhos no JSON
  são resolvidos corretamente (resolução em duas passadas).
- **Segurança de memória**: caminhos de falha de alocação são testados com
  `checkAllAllocationFailures` (sem vazamentos). A inicialização do snapshot
  registra a limpeza antes de qualquer alocação falível.
- **Paridade**: `worldMatrix` (unidade) e `computeWorldTransforms` (lote)
  produzem a mesma matriz para a mesma entidade.

## Desempenho e uso

- `computeWorldTransforms` é O(n) em tempo e usa memória temporária O(n)
  (liberada antes do retorno), além dos arrays do snapshot. Faça uma vez por
  frame (ou quando os transforms mudarem) e consulte via `get`.
- `worldMatrix` é O(profundidade) e aloca um buffer de cadeia; adequado para
  consultas pontuais, não para varrer a cena inteira por frame.
- O snapshot não rastreia mudanças automaticamente: se a cena mudar, recalcule.
  Rastreamento de mudanças (change tracking) é uma extensão futura.

## Limitações e próximos passos

- Não há cache incremental/dirty-tracking entre frames; cada cálculo é completo.
- Não há suporte a múltiplas cenas ou streaming de transforms neste incremento.
- O renderer/editor ainda consumirão estas matrizes quando forem implementados;
  este incremento entrega apenas a matemática e a propagação no sistema de cenas.

## Relacionados

- Formato de cena: [scene-format.md](scene-format.md)
- Arquitetura: [architecture.md](architecture.md)
- Versionamento: [versioning.md](versioning.md)
