# Arquitetura e princípios

Este documento registra os princípios iniciais da CoreX. A arquitetura ainda está em desenvolvimento; as decisões abaixo são diretrizes, não promessas de funcionalidades já implementadas.

## Princípios

1. **Zig de ponta a ponta:** código do runtime e ferramentas do projeto em Zig; dependências nativas externas só serão adotadas com justificativa documentada.
2. **Propriedade explícita:** APIs devem deixar claro quem aloca, possui e libera cada recurso.
3. **Composição:** subsistemas devem poder ser usados e testados de forma independente sempre que possível.
4. **Dados antes de abstrações:** priorizar estruturas e percursos adequados ao trabalho real da engine, evitando abstrações sem necessidade comprovada.
5. **Compatibilidade visível:** documentar a versão de Zig suportada e validar mudanças com build e testes.

## Subsistemas planejados

- **Core:** inicialização, configuração, logging e utilitários compartilhados.
- **Memória:** políticas de alocação com allocators explícitos e limites de vida documentados.
- **ECS:** entidades, componentes e sistemas com API orientada a dados.
- **Recursos:** carregamento, cache, dependências e liberação previsível.
- **Renderização:** API independente de backend; escolha de backends após protótipos e avaliação de plataformas.
- **Sistemas de plataforma:** janela, entrada, áudio e relógio, conforme o escopo for definido.

## Diretrizes para APIs

- Preferir passar allocators explicitamente em operações que podem alocar.
- Evitar estado global mutável; quando inevitável, documentar ciclo de vida e sincronização.
- Definir comportamento de erro e propriedade dos dados nas APIs públicas.
- Adicionar testes para regras, invariantes e casos de erro.
- Manter a superfície pública concentrada em `src/corex.zig`, conforme os subsistemas forem implementados.

## Estado atual

O repositório contém apenas o scaffold inicial de build, ponto de entrada e metadados. ECS, alocadores especializados, renderização, gerenciamento de recursos e sistemas de plataforma ainda não estão implementados.
