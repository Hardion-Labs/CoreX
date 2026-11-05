# Importação de Assets e Cache — CoreXEngine

Este documento descreve o pipeline de importação de assets e o cache
endereçado por conteúdo da CoreXEngine. O código vive em `src/assets/` e é
exposto publicamente como `corex.assets`. O índice de assets (etapa de startup)
permanece em `src/core/assets.zig` e não teve seu contrato alterado.

> Estado: **implementado e testado**. Decodificadores de **textura** para
> **BMP, TGA e QOI** existem e produzem um artefato `CXTX` (RGBA8) — ver
> [asset-decoders.md](asset-decoders.md). Demais formatos binários (PNG, JPEG,
> áudio, modelo, fonte) ainda não têm decodificador e usam o importer `raw`
> (cópia verbatim) até que decodificadores sejam registrados. Isso está
> documentado abaixo e não é descrito como capacidade existente.

## Visão geral

O pipeline transforma assets de origem em artefatos derivados prontos para a
engine e os armazena em um cache incremental e reprodutível:

1. O índice de assets (`AssetIndex`) lista os arquivos de origem (caminho,
   tamanho, tipo).
2. Para cada asset, o pipeline lê a origem, seleciona um **importer** pela
   extensão e calcula uma **chave de cache** a partir do hash do conteúdo +
   identidade/versão do importer + opções.
3. Se a chave já existe no cache e é íntegra, o artefato é reutilizado
   (**cache hit**, sem reimportar). Caso contrário, o importer roda e o
   resultado é gravado de forma atômica (**import**).
4. Um **relatório** (`Report`) registra o resultado por asset e os totais.

Como a chave depende do conteúdo da origem e da versão do importer, o cache é
automaticamente invalidado quando a origem muda ou quando o importer é
atualizado — sem necessidade de um índice separado ou de timestamps.

## Importers

Um `Importer` é uma identidade estável (`id` + `version`) mais uma função pura
`bytes de origem -> bytes derivados`. A versão participa da chave de cache;
alterar o comportamento de um importer e incrementar sua versão invalida as
entradas afetadas.

Importers embutidos (`corex.assets.importer`):

| ID     | Versão | Comportamento                                                        |
|--------|--------|----------------------------------------------------------------------|
| `raw`  | 1      | Cópia verbatim para assets binários/opacos (sem decodificação).        |
| `text` | 1      | Valida UTF-8, remove BOM e normaliza CRLF/CR para LF.                  |
| `json` | 1      | Valida JSON estrito (rejeita campos duplicados) e reminifica sem perdas. |

O importer de cenas (`corex.assets.scene_importer`, ID `scene`) reutiliza o
sistema de cenas: valida o documento `.scene` (hierarquia, componentes,
transforms) e o re-serializa de forma canônica e determinística. Cenas inválidas
são rejeitadas em tempo de importação.

Importers de textura (`corex.assets.texture`, IDs `bmp`/`tga`/`qoi`, versão 1)
decodificam a imagem para RGBA8 e a serializam no artefato `CXTX`. Ver
[asset-decoders.md](asset-decoders.md) para formatos suportados, layout do
artefato e limitações.

Contrato de um importer:

```zig
pub const ImportError = error{ InvalidAsset, OutOfMemory };
// fn (gpa: Allocator, source: []const u8) ImportError![]u8
```

- Os bytes retornados são alocados com o allocator recebido; o caller libera.
- O importer não deve reter `source`.
- `InvalidAsset` indica origem inválida para aquele importer; o pipeline marca o
  asset como `failed` e continua o lote.

### Registro de importers

`Registry` mapeia extensões (com ponto, case-insensitive) para importers, com um
fallback para extensões não casadas:

- `importer.defaultRegistry()`: JSON + texto, fallback `raw`.
- `assets.engineRegistry()`: texturas (BMP/TGA/QOI) + cenas + JSON + texto,
  fallback `raw` (registro padrão da engine).

Camadas superiores podem estender o registro (por exemplo, decodificadores de
textura/áudio/modelo) sem alterar o pipeline:

```zig
const reg = corex.assets.Registry{
    .bindings = &.{.{ .extensions = &.{".png"}, .importer = my_png_importer }},
    .fallback = corex.assets.importer.raw_importer,
};
```

## Cache endereçado por conteúdo

`corex.assets.Cache` armazena um arquivo autodescritivo por chave, nomeado pelo
digest hexadecimal minúsculo (BLAKE3-256). Layout de cada arquivo:

```text
magic "CXAC" (4 bytes) | format_version u32 LE | meta_len u32 LE | meta JSON | payload
```

O objeto JSON de metadados registra: chave, caminho de origem, hash da origem,
importer e versão, hash e tamanho do artefato, e o tipo do asset.

Garantias:

- **Escrita atômica**: grava em arquivo temporário e faz `rename`. Um crash não
  deixa entrada parcial visível.
- **Verificação de integridade**: na leitura, o hash e o tamanho do payload são
  recalculados e comparados aos metadados. Entrada corrompida/truncada é tratada
  como *miss* e reimportada (auto-recuperação).
- **Invalidação por versão**: `format_version` do cache e a versão do importer
  participam da chave; incrementá-los invalida as entradas afetadas.
- **Concorrência segura**: contador atômico de arquivos temporários + `rename`
  atômico permitem gravações paralelas, inclusive de chaves idênticas.

API principal:

```zig
var cache = try corex.assets.Cache.open(io, cache_dir);
defer cache.deinit();

const key = corex.assets.cache.deriveKey(source_hash, "text", 1, options_hash);
try cache.put(gpa, key, info, payload, tmp_suffix);
const bytes = try cache.get(gpa, key); // ?[]u8; null em miss/corrupção
```

`get` retorna bytes de propriedade do caller (liberar com o mesmo allocator).
`has` verifica sem reter o payload; `remove` apaga uma entrada.

## Pipeline

`corex.assets.pipeline` orquestra a importação de um `AssetIndex`:

```zig
var report = try corex.assets.pipeline.run(gpa, io, project_root, index, &cache, .{
    .registry = corex.assets.engineRegistry(),
});
defer report.deinit();
```

- `run(...)` importa assets concorrentemente via `Io.Group` (por exemplo
  `JobSystem.io()`). Requer um allocator thread-safe.
- `runSequential(...)` importa um a um, sem paralelismo, para contextos
  single-thread ou allocators não thread-safe.
- Cada task escreve apenas seu próprio slot do relatório; os totais são
  calculados após a conclusão do grupo.
- Uma falha por asset é registrada (`status = .failed`, `error_name`) e não
  aborta o restante do lote.

Opções (`Options`):

| Campo              | Padrão              | Efeito                                        |
|--------------------|---------------------|-----------------------------------------------|
| `force`            | `false`             | Ignora cache hits e reimporta tudo.            |
| `registry`         | `defaultRegistry()` | Registro de importers por extensão.            |
| `max_source_bytes` | 64 MiB              | Limite de leitura por arquivo de origem.       |
| `options_salt`     | `""`                | Bytes extras dobrados na chave de cache.       |

O relatório (`Report`) contém uma entrada por asset na ordem do índice, com
`status` (`imported`, `cached`, `failed`), `importer_id`, `key`, `output_size` e
`error_name`, além dos totais (`imported`, `cached`, `failed`,
`total_output_bytes`). `Report.liveKeys(gpa)` coleta as chaves de todos os assets
importados/cacheados com sucesso — o conjunto `live` para a coleta de lixo.

## Coleta de lixo (GC)

`Cache.gc(gpa, live)` faz uma varredura **mark-and-sweep**: apaga toda entrada
cuja chave **não** está em `live` e mantém o restante. É o complemento do ciclo
import → cache: quando uma origem muda, é removida ou um importer é
versionado, a entrada antiga vira órfã e o GC a reclaima.

```zig
var report = try corex.assets.pipeline.run(gpa, io, root, idx, &cache, .{
    .registry = corex.assets.engineRegistry(),
});
defer report.deinit();

const live = try report.liveKeys(gpa); // chaves válidas do índice atual
defer gpa.free(live);

const stats = try cache.gc(gpa, live);
// stats.scanned / .kept / .removed / .bytes_freed
```

Garantias e comportamento:

- `live` deve ser o conjunto **completo** de chaves a reter — tipicamente de uma
  execução do pipeline sobre o índice inteiro. Entradas fora desse conjunto são
  removidas; o GC não "adivinha" o que ainda é referenciado.
- Entradas são identificadas estritamente pelo nome de arquivo (64 dígitos
  hexadecimais minúsculos). Arquivos temporários (`.tmp.N`) e arquivos estranhos
  **não** são tocados.
- Complexidade O(entradas + live), com um hash set para pertinência; a iteração
  de diretório usa buffer fixo. `bytes_freed` soma o tamanho em disco das
  entradas removidas.
- É uma operação de **manutenção**: execute quando não houver `put` concorrente
  em andamento (não faz parte do caminho de importação por frame). É idempotente:
  uma segunda varredura com o mesmo `live` nada remove.
- Assets que falharam na importação não contribuem com chave; seu artefato antigo
  (se existir) é tratado como órfão e removido, o que é correto pois a origem
  atual é inválida.

## Limitações

- Decodificadores de textura existem para **BMP, TGA e QOI** (ver
  [asset-decoders.md](asset-decoders.md)). PNG, JPEG, áudio, modelo e fonte ainda
  não têm decodificador e usam o importer `raw` (cópia verbatim); serão
  registrados como importers específicos quando existirem.
- O importer `json` preserva a ordem de chaves da origem (minifica, não ordena
  chaves); a determinismo é por conteúdo de origem, o que é suficiente para o
  cache endereçado por conteúdo.
- O pipeline ainda não está ligado ao startup/editor; é uma API pública
  independente. A integração com o startup e o hot-reload são próximos passos.
- A coleta de lixo (GC) de entradas órfãs do cache está **implementada**
  (`Cache.gc`, ver acima). Ainda não há rastreamento de dependências entre assets
  nem limpeza de arquivos temporários deixados por escritas interrompidas
  (crash); ambos são extensões planejadas.
- `run` paralelo exige allocator thread-safe; caso contrário use
  `runSequential`.

## Segurança de memória

- Allocators explícitos em todas as APIs que alocam; propriedade documentada.
- Leituras limitadas (`max_source_bytes`, `max_cache_file_bytes`) para evitar
  consumo ilimitado de memória.
- Escrita atômica + verificação de hash evitam confiar em artefatos parciais ou
  corrompidos.
- Caminhos de origem vêm do índice (relativos ao projeto); o pipeline lê
  relativos ao diretório raiz do projeto.
- Testes incluem sondas de falha de alocação (`checkAllAllocationFailures`) nos
  importers e testes de corrupção/truncamento no cache.

## Links relacionados

- [architecture.md](architecture.md) — mapa de subsistemas e estado.
- [asset-decoders.md](asset-decoders.md) — decodificadores de textura e artefato CXTX.
- [scene-format.md](scene-format.md) — formato de cena validado pelo importer.
- [versioning.md](versioning.md) — política de versionamento de formatos.
- [launch-contract.md](launch-contract.md) — contrato de startup (inalterado).
