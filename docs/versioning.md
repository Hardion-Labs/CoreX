# Versionamento e Compatibilidade — CoreXEngine

## Versão da engine

A CoreXEngine usa [Semantic Versioning 2.0.0](https://semver.org/lang/pt-BR/):
`MAJOR.MINOR.PATCH[-PRE][+BUILD]`.

A versão atual da engine é exposta por `corex.version` e impressa por
`corex-engine --version`. A versão alvo do compilador é **Zig 0.17.0**, exposta
por `corex.zig_version`.

Durante o desenvolvimento inicial a engine usa versões `0.x.y` (ex.:
`0.1.0-dev`). O sufixo `-dev` marca builds de desenvolvimento.

## Política de compatibilidade de projetos

Um projeto declara a versão da engine para a qual foi criado no campo
`engine_version` do manifesto `.corex`. A engine verifica compatibilidade antes
de carregar o projeto:

- **MAJOR diferente** → incompatível. Mudanças de MAJOR quebram compatibilidade.
- **MAJOR == 0** (fase inicial): `MINOR` deve ser **igual**. Em `0.x`, cada
  incremento de MINOR pode quebrar compatibilidade; por isso exige-se igualdade.
- **MAJOR >= 1**: `MINOR` do projeto deve ser **menor ou igual** ao da engine
  (compatibilidade retroativa dentro do mesmo MAJOR). Um projeto que exige um
  MINOR mais novo que o da engine é incompatível.
- `PATCH`, `PRE` e `BUILD` não afetam a compatibilidade. São registrados para
  diagnóstico.

Resultado da verificação:

- Compatível → a inicialização prossegue.
- Incompatível → a engine rejeita o projeto com código de saída **4** e uma
  mensagem indicando as versões envolvidas.

A engine **não** instala, baixa, seleciona nem troca de versão silenciosamente.
A seleção de versão é responsabilidade exclusiva do CoreXHub. Se o projeto for
incompatível, cabe ao usuário (ou ao Hub) iniciar a versão correta da engine.

## Versão selecionada pelo Hub (`--engine-version`)

Quando iniciada pelo Hub, a engine pode receber `--engine-version <semver>` com a
versão que o Hub selecionou. Esse valor é **informativo**:

- A engine registra a versão recebida.
- Se divergir da versão real do binário em execução, a engine emite um aviso.
- A engine não toma nenhuma ação de instalação/seleção com base nesse valor.

Isso mantém a fronteira clara: o Hub decide qual versão iniciar; a engine apenas
reporta qual versão é.

## Versionamento de formato

Formatos de arquivo (manifesto `.corex`, cenas, assets, export templates) têm
versão própria, independente da versão da engine:

- O manifesto `.corex` usa `format_version` (atualmente `1`).
- Cenas `.scene` usam `format_version` próprio (atualmente `1`), independente do
  manifesto e da versão da engine ([scene-format.md](scene-format.md)).
- O cache de importação de assets usa `format_version` próprio (atualmente `1`),
  embutido em cada entrada; a chave de cache também incorpora a versão do
  importer, de modo que incrementar qualquer uma delas invalida as entradas
  afetadas ([asset-import.md](asset-import.md)).
- Versões de formato desconhecidas são rejeitadas.
- Mudanças incompatíveis de formato incrementam a versão do formato.

## Contratos estáveis

Fazem parte do contrato estável de integração:

- Os argumentos de linha de comando e seus significados ([launch-contract.md](launch-contract.md)).
- Os códigos de saída ([launch-contract.md](launch-contract.md)).
- O formato do manifesto `.corex` e sua `format_version` ([project-format.md](project-format.md)).
- O formato de cena `.scene` e sua `format_version` ([scene-format.md](scene-format.md)).
- A política de compatibilidade deste documento.

Mudanças nesses contratos exigem incremento de versão apropriado e nota no
[CHANGELOG](../CHANGELOG.md).
