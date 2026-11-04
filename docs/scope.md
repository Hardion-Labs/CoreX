# CoreXEngine — Escopo Definitivo

Este documento registra o escopo definitivo do projeto mantido neste repositório.
Ele é a referência de fronteira entre a **CoreXEngine** e o **CoreXHub**.

## Identidade do projeto

O projeto deste repositório é exclusivamente a **CoreXEngine**: uma engine de jogos
modular escrita em Zig 0.17.0, com runtime independente, editor gráfico próprio e
ferramentas de produção de conteúdo.

O **CoreXHub** é um produto independente, mantido em outro repositório. Nada do
CoreXHub é implementado, incorporado ou duplicado aqui.

## Fora do escopo — CoreXHub

As responsabilidades abaixo pertencem ao CoreXHub e **não** devem ser
implementadas na CoreXEngine:

- Criar projetos.
- Registrar projetos.
- Gerenciar projetos recentes.
- Instalar versões da engine.
- Selecionar versões da engine.
- Gerenciar instalações.
- Gerenciar Export Templates (instalação/aquisição).
- Iniciar a CoreXEngine com o projeto selecionado (o Hub é quem inicia; a engine
  apenas aceita ser iniciada).

## Dentro do escopo — CoreXEngine

A CoreXEngine implementa:

- Engine Core em Zig 0.17.0.
- Runtime independente.
- Editor gráfico próprio.
- Biblioteca GUI própria.
- Renderer Low.
- Renderer Medium.
- Contratos para Renderer Advanced.
- ECS.
- Sistema de cenas.
- Sistema de assets.
- Importação e cache.
- Serialização.
- VM Lua.
- Gameplay scripting.
- Native Module API para C++.
- Sistema de jobs e carregamento assíncrono.
- Splash screen.
- Sistema de versionamento da engine.
- Sistema de exportação.
- Export Templates (formato/empacotamento consumidos pela engine).
- Ferramentas de diagnóstico e profiling.

> Observação sobre Export Templates: a **aquisição, instalação e gestão** de
> templates pertencem ao Hub. A engine define o **formato**, o **empacotamento**
> e o **consumo** dos templates durante a exportação.

## Integração com o CoreXHub

A integração ocorre exclusivamente por:

1. Argumentos de inicialização documentados.
2. Formatos de arquivo documentados (`.corex`, cenas, assets, templates).
3. Contratos estáveis (CLI, manifesto, códigos de saída, versão).

A engine disponibiliza uma interface de inicialização documentada em
[launch-contract.md](launch-contract.md). O Hub pode iniciar a engine passando:

- Caminho absoluto do projeto (arquivo `.corex`).
- Versão da engine selecionada (informativa; a engine não instala/seleciona versões).
- Argumentos adicionais documentados.

Exemplo:

```sh
corex-engine --project "/path/MyGame/MyGame.corex" --hub-launch
```

O editor também aceita inicialização direta pela linha de comando, sem o Hub.
**A engine nunca depende do Hub para executar.**

## Regras de arquitetura

- Não criar Project Manager interno.
- Não criar catálogo de projetos.
- Não implementar criação de projetos na engine.
- Não instalar ou selecionar versões silenciosamente.
- Não acoplar a engine ao CoreXHub.

O arquivo `.corex` é o ponto de entrada do projeto. Ao receber um projeto, a
engine executa a sequência de inicialização definida em
[launch-contract.md](launch-contract.md):

1. Inicializar serviços essenciais.
2. Abrir splash screen.
3. Validar manifesto e compatibilidade.
4. Carregar configurações em workers.
5. Indexar assets.
6. Preparar a cena inicial.
7. Abrir o editor gráfico.

## Estado de implementação

Este documento define o escopo alvo. O estado real de cada subsistema é
registrado em [architecture.md](architecture.md) e no [CHANGELOG](../CHANGELOG.md).
Funcionalidades ainda não implementadas são marcadas como planejadas e não devem
ser descritas como existentes.
