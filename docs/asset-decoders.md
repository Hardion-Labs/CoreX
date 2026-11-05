# Decodificadores de Textura e Artefato CXTX — CoreXEngine

Este documento descreve os decodificadores de imagem da CoreXEngine e o artefato
de textura pronto para a engine (`CXTX`). O código vive em `src/assets/image.zig`
(decodificação pura) e `src/assets/texture.zig` (artefato + importers), exposto
como `corex.assets.image` e `corex.assets.texture` (tipos `corex.assets.Image` e
`corex.assets.Texture`).

> Estado: **implementado e testado** para **BMP, TGA e QOI**. PNG, JPEG, áudio,
> modelo e fonte ainda não têm decodificador e continuam importados como `raw`
> (cópia verbatim). Isso é documentado como limitação, não como capacidade
> existente.

## Visão geral

O pipeline de importação seleciona um importer pela extensão. Para texturas, o
importer **decodifica** a origem para **RGBA8** (8 bits por canal, row-major,
top-down) e a **serializa** num contêiner auto-descritivo `CXTX`, que é o
artefato derivado armazenado no cache endereçado por conteúdo. O renderer poderá
fazer upload direto dos pixels sem re-analisar o formato de origem.

```
origem (.bmp/.tga/.qoi) → decode → Image RGBA8 → serialize → CXTX → cache
```

## Formatos suportados

| Formato | Extensão | Modos | Profundidade | Observações |
|---|---|---|---|---|
| BMP | `.bmp` | `BI_RGB` (não comprimido) | 24, 32 bpp | Bottom-up e top-down; padding de linha em 24 bpp; BGR→RGB; alfa do 4º byte em 32 bpp. |
| TGA | `.tga` | True-color não comprimido (tipo 2) e RLE (tipo 10) | 24, 32 bpp | Bit 5 do descritor define top-down; BGR(A)→RGBA(A). |
| QOI | `.qoi` | Decode **e** encode | 3/4 canais | Quite OK Image; encode habilita roundtrip lossless e futuro export. |

Rejeições honestas (erro `InvalidImage`/`InvalidAsset`, sem acesso fora dos
limites): BMP comprimido ou com bpp diferente de 24/32; TGA com mapa de cores,
escala de cinza ou RLE que excede a contagem de pixels; QOI com magic/canais
inválidos, truncado ou sem o marcador de fim; dimensões zero ou acima de
`max_dimension`; buffer de pixels acima de `max_pixel_bytes`.

## Artefato `CXTX`

Layout little-endian, tamanho total `20 + width*height*4`:

| Bytes | Campo | Tipo |
|---|---|---|
| 0..4 | magic `"CXTX"` | 4 bytes |
| 4..8 | `format_version` (= 1) | u32 |
| 8..12 | `width` | u32 |
| 12..16 | `height` | u32 |
| 16..20 | `pixel_format` (0 = RGBA8) | u32 |
| 20.. | pixels RGBA8 (row-major, top-down) | `width*height*4` bytes |

`texture.parse` valida magic, versão, formato de pixel, dimensões e o tamanho
exato, retornando uma **view zero-copy** (`Texture`) sobre os bytes do artefato
(o caller é dono dos bytes). `texture.serialize` produz o artefato a partir de
uma `Image`. A identidade do importer (`bmp`/`tga`/`qoi`, versão 1) participa da
chave do cache; mudar o layout e incrementar a versão invalida as entradas
afetadas automaticamente.

## API

```zig
const A = corex.assets;

// Decodificação pura (o caller libera Image.pixels com deinit):
var img = try A.image.decodeBmp(gpa, source); // ou decodeTga / decodeQoi
defer img.deinit(gpa);

// Encode QOI lossless (roundtrip / futuro export):
const qoi_bytes = try A.image.encodeQoi(gpa, img);
defer gpa.free(qoi_bytes);

// Artefato CXTX:
const artifact = try A.texture.serialize(gpa, img);
defer gpa.free(artifact);
const tex = try A.texture.parse(artifact); // view zero-copy
// tex.width / tex.height / tex.pixel_format / tex.pixels

// Importers (source -> CXTX), já registrados no engineRegistry:
const bytes = try A.texture.importQoi(gpa, source); // importBmp / importTga
defer gpa.free(bytes);
```

Limites públicos: `image.max_dimension = 16384`, `image.max_pixel_bytes = 256 MiB`
(alinhado ao teto de artefato do cache). Toda leitura é bounds-checked e toda
alocação é limitada e verificada contra overflow.

## Integração com o pipeline

`assets.engineRegistry()` registra `.bmp`/`.tga`/`.qoi` → importers de textura,
antes dos importers de cena/JSON/texto, com fallback `raw`. `.qoi` foi adicionado
à classificação de textura do índice (`AssetKind.fromExtension`). O contrato do
pipeline, do cache e do startup permanece inalterado: o artefato `CXTX` é apenas
mais um payload derivado, armazenado e verificado como qualquer outro.

```zig
var report = try A.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = A.engineRegistry(),
});
// report.entries[i].importer_id == "qoi", .kind == .texture, .key -> artefato CXTX
```

## Garantias e testes

- **Roundtrip QOI**: `encodeQoi` → `decodeQoi` preserva exatamente os pixels
  (gradiente com alfa e um caso que exercita chunks RUN/INDEX/DIFF/LUMA/RGBA).
- **Fixtures conhecidas**: BMP 24 bpp bottom-up com padding, BMP 32 bpp top-down
  com alfa, TGA não comprimido e RLE (run + literal), QOI de 1 pixel conhecido.
- **Rejeição de corrupção**: magic/compressão/bpp/canais inválidos, truncamento,
  offset além do arquivo, RLE que excede a contagem de pixels, marcador de fim
  ausente.
- **Segurança de memória**: sondas `checkAllAllocationFailures` nos decodificadores
  e no serialize; nenhuma fuga em falha de alocação.
- **Ponta a ponta**: um teste importa um `.qoi` pelo pipeline, lê o artefato de
  volta do cache via `key`, faz `parse` e compara os pixels; uma segunda execução
  é cache hit (sem reimportar).

## Desempenho

- Decodificação em passada única, sem recursão, com escrita direta no buffer de
  pixels (cache-friendly). QOI é um formato projetado para velocidade.
- `encodeQoi` pré-reserva a capacidade máxima (`14 + w*h*5 + 8`) e usa
  `appendAssumeCapacity`, evitando realocações durante o encode.
- O artefato `CXTX` é auto-descritivo: o renderer não re-analisa a origem.

## Limitações e próximos passos

- Sem PNG (requer inflate), JPEG, BMP comprimido, TGA indexado, canais de 16 bits
  ou HDR; esses casos são rejeitados ou caem em `raw`, nunca "adivinhados".
- Sem mipmaps, compressão de textura (BC/ASTC) ou conversão de espaço de cor;
  o artefato é sempre RGBA8 linear.
- O pipeline ainda não está ligado ao startup/editor; a integração e o
  hot-reload são próximos passos, assim como decodificadores de áudio e de
  outros formatos de modelo (o importador de malha OBJ já existe — ver
  [mesh-import.md](mesh-import.md)).

## Relacionados

- Importação e cache: [asset-import.md](asset-import.md)
- Importação de malhas (OBJ) / CXMH: [mesh-import.md](mesh-import.md)
- Arquitetura: [architecture.md](architecture.md)
- Versionamento: [versioning.md](versioning.md)
