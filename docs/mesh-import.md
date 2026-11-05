# Importação de Malhas (OBJ) e Artefato CXMH — CoreXEngine

Este documento descreve o importador de malhas da CoreXEngine: o decodificador
do subconjunto geométrico de **Wavefront OBJ** e o artefato engine-ready
**`CXMH`** que ele produz. O código vive em `src/assets/mesh.zig` e é exposto
como `corex.assets.mesh` (com `corex.assets.Mesh` / `corex.assets.MeshView`).

> Estado: **implementado e testado**. É a parte "modelo" do item de decodificadores
> de assets do roadmap. Consome o mesmo pipeline/cache dos demais importers
> ([asset-import.md](asset-import.md)) e alimenta a camada de extração de render
> ([render-extraction.md](render-extraction.md)): os `bounds` da malha podem
> inicializar `Renderable.bounds`, e os handles de mesh referenciam o artefato.
> Outros formatos de modelo (glTF/FBX/DAE) ainda não têm decodificador.

## Visão geral

```
fonte .obj ──► decodeObj ──► Mesh (vértices intercalados + índices u32 + bounds)
                          ──► serialize ──► artefato CXMH ──► cache endereçado por conteúdo
                                                          ──► parse (view zero-copy) ──► renderer
```

O importer é uma transformação pura `bytes -> bytes`, com identidade própria
(`id = "obj"`, `version = 1`). A versão participa da chave de cache, então mudar
o layout e incrementar a versão invalida automaticamente as entradas afetadas.

## Subconjunto OBJ suportado

Honesto e documentado — o que não é suportado é **ignorado**, nunca "adivinhado":

- `v x y z [w]` — posições (`w` ignorado).
- `vn x y z` — normais (normalizadas na importação; comprimento zero é rejeitado).
- `vt u v [w]` — UVs (`w` ignorado; passadas sem alteração, origem inferior-esquerda).
- `f a b c ...` — faces poligonais, **trianguladas em leque** `(0,i,i+1)`. Cada
  canto pode ser `v`, `v/vt`, `v//vn` ou `v/vt/vn`; índices são 1-based, negativos
  resolvem relativos ao fim atual. Índice `0`, fora de faixa ou referência
  adiantada são rejeitados.
- Normais ausentes recebem uma **normal flat por face** (produto vetorial das
  arestas, normalizado; face degenerada → normal `(0,0,0)`). UVs ausentes → `(0,0)`.
- Vértices são **deduplicados** por referência `(posição, uv, normal)`. Com
  normais explícitas compartilhadas, cantos coincidentes entre faces são
  mesclados; com normais flat, cada face mantém seus próprios vértices (correto
  para flat shading).
- Comentários `#`, linhas em branco, CRLF e diretivas de grupo/material
  (`o`, `g`, `s`, `usemtl`, `mtllib`, ...) são ignorados — materiais são trabalho
  futuro.

## Artefato `CXMH`

Layout little-endian, cabeçalho de 44 bytes:

| Offset | Campo | Tipo |
| --- | --- | --- |
| 0..4 | magic `"CXMH"` | 4 bytes |
| 4..8 | `format_version` (= 1) | u32 |
| 8..12 | `vertex_format` (= 0, p3n3t2) | u32 |
| 12..16 | `vertex_count` | u32 |
| 16..20 | `index_count` (múltiplo de 3) | u32 |
| 20..32 | `bounds_min` | [3]f32 |
| 32..44 | `bounds_max` | [3]f32 |
| 44.. | vértices intercalados (`vertex_count * 32`) + índices (`index_count * 4`) | bytes |

Cada vértice tem 32 bytes: `position[3] f32`, `normal[3] f32`, `uv[2] f32`
(formato `p3n3t2`). Os índices formam uma triangle list (`u32`).

## API

- `decodeObj(gpa, source) DecodeError!Mesh` — decodifica OBJ em malha indexada.
- `Mesh { vertices: []Vertex, indices: []u32, bounds_min, bounds_max }` — malha
  owned; `deinit(gpa)` libera; `triangleCount()`.
- `Vertex` — `extern struct` de 32 bytes (posição + normal + uv).
- `serialize(gpa, mesh) ImportError![]u8` — valida e escreve o artefato `CXMH`.
- `parse(bytes) error{InvalidAsset}!MeshView` — view **zero-copy** e segura quanto
  a alinhamento: validação linear de estrutura, faixa de índices e finitude dos
  floats; accessors `vertexAt(i)` / `indexAt(i)` leem campos little-endian
  explicitamente (sem casts de ponteiro).
- `importObj(gpa, source) ImportError![]u8` — `decodeObj` + `serialize`.
- `obj_importer` (`id="obj"`, `version=1`) e `bindings` (`.obj`).

Limites: `max_vertices = 4.000.000` (128 MB de vértices), `max_indices =
12.000.000` (48 MB de índices); total < teto de 256 MiB do cache.

## Integração com o pipeline

`assets.engineRegistry()` agora inclui os bindings de malha (`.obj`), então o
pipeline importa `.obj` para `CXMH` automaticamente, com cache e GC como qualquer
outro asset. `.obj` já é classificado como `AssetKind.model` pelo índice.

```zig
const corex = @import("corex");
const A = corex.assets;
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "obj", kind == .model
const artifact = (try cache.get(gpa, key)).?;
defer gpa.free(artifact);
const view = try A.mesh.parse(artifact);
// view.vertexAt(i).position / .normal / .uv, view.indexAt(i), view.bounds_*
```

## Garantias e testes

- **Decodificação**: triângulo com posição/normal/UV; triangulação em leque de
  quad; índices negativos; dedup com normais explícitas vs. flat por face;
  formas de canto `v/vt` e `v//vn`; comentários/CRLF/diretivas ignoradas;
  normalização de normais e rejeição de normal zero.
- **Rejeição**: sem faces, face com < 3 cantos, índice 0/fora de faixa/adiantado,
  canto com partes demais, floats não finitos, posição com < 3 componentes.
- **Artefato**: roundtrip serialize/parse preservando vértices/índices/bounds;
  rejeição de magic/version/format/counts/length inválidos, truncamento, índice
  fora de faixa e vértice não finito (bytes crafted); serialize rejeita malha
  inválida.
- **Pipeline**: teste end-to-end OBJ → CXMH → cache → parse, com cache hit na
  segunda execução.
- **Segurança de memória**: `checkAllAllocationFailures` em decode/serialize/
  import sem vazamentos; a transferência de ownership em duas fases do
  `decodeObj` libera o primeiro slice se o segundo falhar.

## Desempenho

- Uma passada sobre as linhas da fonte; listas de posições/normais/UVs e um
  `AutoHashMap` de dedup com chave de 96 bits `(v, vt, vn)`.
- Triangulação em leque O(n) por face; só os vértices usados entram no buffer.
- `parse` faz uma passada linear de validação (finitude + faixa de índices),
  garantindo que o consumidor nunca veja índice fora de faixa ou NaN.
- Artefato auto-contido e cache-friendly para upload direto pelo backend GPU.

## Limitações e próximos passos

- Apenas o subconjunto geométrico de OBJ; sem materiais/`.mtl`, sem grupos como
  submalhas, sem smoothing groups, sem cores por vértice.
- Sem glTF/FBX/DAE; esses formatos ainda caem em `raw`.
- Sem LOD, skinning, morph targets ou compressão de malha.
- A ligação dos handles de `Renderable.mesh` com o artefato `CXMH` e o upload GPU
  são trabalho do backend de render futuro.

## Relacionados

- Importação e cache: [asset-import.md](asset-import.md)
- Decodificadores de textura / CXTX: [asset-decoders.md](asset-decoders.md)
- Extração de render: [render-extraction.md](render-extraction.md)
- Arquitetura: [architecture.md](architecture.md)
