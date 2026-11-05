# Extração de Render Backend-Independente — CoreXEngine

Este documento descreve a camada de extração de render da CoreXEngine: a
fundação **independente de backend** (CPU) que todas as tiers de renderer
(Low/Medium/Advanced) consumirão. O código vive em `src/render/` e é exposto como
`corex.render`.

> Estado: **camada de extração implementada e testada**. Os backends GPU
> Low/Medium e o contrato Advanced ainda são planejados; nenhum backend GPU foi
> escolhido. Esta camada não tem dependência de GPU, então roda e é totalmente
> testada headless. Ela consome os transforms world-space
> ([scene-transforms.md](scene-transforms.md)) e, no futuro, os artefatos de
> textura `CXTX` ([asset-decoders.md](asset-decoders.md)).

## Visão geral

A extração transforma uma cena + câmera em uma **draw list** pronta para o
backend GPU:

```
cena (Transform + Renderable) ──► world transforms (snapshot O(n))
                               ──► AABB world por renderable
                               ──► frustum culling
                               ──► DrawCommands ordenados ──► backend GPU
```

É trabalho puramente de CPU, reutilizando o snapshot de world transforms da cena
e a iteração de views do ECS — baixo acoplamento e cache-friendly.

## Convenções matemáticas

- Matrizes `Mat4` **column-major** (`m[c*4+r]`), as mesmas de
  [scene-transforms.md](scene-transforms.md).
- Sistema **right-handed**; a câmera olha para **-Z**.
- Clip space estilo OpenGL: NDC com `z ∈ [-1, 1]` (near → -1, far → +1).
- `clip = projection * view * world` (vetor-coluna).

## Câmera (`corex.render.camera`)

- `perspective(fov_y, aspect, near, far)` — projeção perspectiva (fov vertical em
  radianos; `near < far`, ambos positivos).
- `orthographic(left, right, bottom, top, near, far)` — projeção ortográfica.
- `lookAt(eye, target, up)` — matriz de view; `eye == target` (caso degenerado)
  retorna identidade.
- `Camera` — combina `view`, `projection`, `view_projection` (= `projection *
  view`) e `position` (olho, usado para ordenação por profundidade).
  `Camera.perspectiveLookAt(...)` é um construtor de conveniência.

## Culling (`corex.render.culling`)

- `Aabb { center, extents }` — caixa alinhada por centro + semi-extensões;
  `fromMinMax`, `min`, `max`.
- `Sphere { center, radius }`.
- `Plane { normal, d }` — inside quando `dot(normal, p) + d >= 0`; normalizada
  para que `distanceToPoint` seja uma distância euclidiana com sinal.
- `Frustum.fromMat4(view_projection)` — extrai os 6 planos normalizados
  (Gribb–Hartmann): left/right/bottom/top/near/far.
- `Classification { outside, intersecting, inside }`.
- `Frustum.classifyAabb` / `classifySphere` — teste conservador: `outside` só
  quando totalmente fora de algum plano (seguro para descartar).
- `transformAabb(m, b)` — transforma uma AABB local em world de forma
  conservadora (método de Arvo): transforma o centro e escala as extensões pelos
  valores absolutos da parte linear; envolve a caixa sob rotação e escala não
  uniforme.

## Draw list (`corex.render.draw`)

- `Renderable { mesh, material, bounds }` — componente de cena **plain-data**
  (handles opacos + AABB local). Adicione ao schema com
  `Component(Renderable, "renderable")`; serializa como qualquer componente.
  `isValid` rejeita bounds não finitos ou extensões negativas.
- `DrawCommand { entity, mesh, material, world, bounds, depth }` — um draw call
  visível, auto-contido (carrega a matriz world e os bounds world), então a draw
  list sobrevive ao snapshot transitório de transforms.
- `SortMode`:
  - `front_to_back` — mais perto primeiro (bom para opacos / early-z).
  - `back_to_front` — mais longe primeiro (necessário para alpha blending).
  - `by_material` — agrupa por material, depois mesh (minimiza trocas de estado).
  Empates são desfeitos pelo `entity.key()` para **determinismo**.
- `RenderFrame { commands, culled }` — draw list ordenada + diagnóstico de
  culling; o caller é dono e chama `deinit`.
- `extractDrawList(scene, cam, mode, gpa)` — genérica sobre qualquer
  `*Scene(schema)` com `Transform` + `Renderable`. Calcula o snapshot de world
  transforms uma vez, faz o culling da AABB world de cada renderable e ordena os
  sobreviventes. Falha apenas por alocação (a cena já é válida).

## Exemplo

```zig
const corex = @import("corex");
const R = corex.render;

const MyScene = corex.scene.Scene(.{
    corex.scene.Component(corex.scene.Transform, "transform"),
    corex.scene.Component(R.Renderable, "renderable"),
});

var scene = try MyScene.init(gpa, "main");
defer scene.deinit();
const e = try scene.createEntity("cube", null);
try scene.addComponent(e, corex.scene.Transform{ .position = .{ 0, 0, 0 } });
try scene.addComponent(e, R.Renderable{ .mesh = 1, .material = 2 });

const cam = R.Camera.perspectiveLookAt(
    .{ 0, 0, 10 }, .{ 0, 0, 0 }, .{ 0, 1, 0 },
    std.math.pi / 3.0, 16.0 / 9.0, 0.1, 500,
);
var frame = try R.extractDrawList(&scene, cam, .front_to_back, gpa);
defer frame.deinit();
// frame.commands[i].world / .mesh / .material prontos para o backend GPU.
```

## Garantias e testes

- **Matemática da câmera**: near/far mapeiam para NDC -1/+1; `lookAt` coloca o
  olho na origem e objetos à frente têm view-z negativo; caso degenerado retorna
  identidade.
- **Frustum**: matriz identidade produz o cubo NDC `[-1,1]^3`; uma câmera
  perspectiva real descarta o que está atrás, ao lado e além do far.
- **Classificação**: inside/intersecting/outside para AABB e esfera;
  `transformAabb` envolve os 8 cantos sob rotação (verificado explicitamente).
- **Extração**: cena vazia → frame vazio; objeto off-screen é descartado
  (`culled`); entidade sem `Renderable` não desenha; a matriz world reflete a
  hierarquia; ordenação front/back e por material corretas; **determinismo** para
  cenas idênticas; bounds escalados ainda descartam corretamente.
- **Segurança de memória**: sonda `checkAllAllocationFailures` na extração sem
  vazamentos; allocators explícitos; propriedade documentada.

## Desempenho

- Reutiliza o snapshot O(n) de world transforms (uma passada por frame).
- Culling por AABB é O(1) por renderable (6 planos); só os visíveis viram
  `DrawCommand`.
- Ordenação com `std.mem.sort` e ordenação total (empate por `entity.key()`),
  logo o resultado é determinístico independente da estabilidade do sort.
- `DrawCommand` é plain-data e auto-contido, cache-friendly para o backend.

## Limitações e próximos passos

- Não há backend GPU ainda (Low/Medium/Advanced planejados); esta camada só
  produz a draw list, não rasteriza.
- Sem LOD, occlusion culling, instancing ou batching automático; `by_material`
  apenas ordena para reduzir trocas de estado.
- `Renderable` usa handles opacos de mesh/material; a resolução para recursos GPU
  e a ligação com o cache de assets são trabalho do backend futuro.
- Sem transparência por objeto além da ordenação `back_to_front`; materiais
  transparentes/opacos ainda não são separados em sublistas.

## Relacionados

- Transforms world-space: [scene-transforms.md](scene-transforms.md)
- Decodificadores de textura / CXTX: [asset-decoders.md](asset-decoders.md)
- Arquitetura: [architecture.md](architecture.md)
- Versionamento: [versioning.md](versioning.md)
