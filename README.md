# CoreX

**Uma engine de jogos modular, escrita 100% em Zig.**

CoreX está sendo construída para oferecer uma base clara e extensível para jogos: núcleo, ECS, memória, renderização, recursos e sistemas fundamentais — com foco em desempenho, controle explícito e código fácil de manter.

> **Status:** início do desenvolvimento. A estrutura atual é um scaffold; os subsistemas listados no roadmap ainda serão implementados. A versão-alvo é Zig **0.17.0**.

## Visão geral

- **Linguagem:** Zig 0.17.0
- **Licença:** MIT — consulte [`LICENSE`](LICENSE)
- **Abordagem:** modular, orientada a dados e sem dependências de runtime externas
- **Plataformas e backends:** a definir conforme o desenvolvimento

## Objetivos

- Manter o núcleo pequeno, explícito e previsível.
- Dar controle sobre alocação e ciclo de vida dos recursos.
- Construir sistemas desacoplados e testáveis.
- Evitar dependências externas no runtime sempre que possível.
- Documentar decisões de arquitetura e compatibilidade.

## Estrutura do projeto

```text
CoreX/
├── build.zig          # Configuração de build
├── src/
│   ├── main.zig       # Ponto de entrada do scaffold
│   └── corex.zig      # Módulo público inicial
├── docs/
│   └── architecture.md
├── .gitignore
├── LICENSE
└── README.md
```

## Requisitos

- Zig **0.17.0** (versão-alvo do projeto)
- Git

## Começar

Clone o repositório e entre no diretório:

```sh
git clone https://github.com/Hardion-Labs/CoreX.git
cd CoreX
```

Compile e execute o scaffold:

```sh
zig build
zig build run
```

> O scaffold valida a estrutura inicial do projeto; ainda não é uma engine pronta para produção nem inclui sistemas de jogo implementados.

## Roadmap

- [x] Criar a estrutura inicial do projeto e definir o escopo.
- [ ] Validar build e testes continuamente com Zig 0.17.0.
- [ ] Núcleo: ciclo de vida, configuração e logging.
- [ ] Memória: allocators e políticas de propriedade documentadas.
- [ ] ECS: entidades, componentes e sistemas.
- [ ] Recursos: carregamento, cache e liberação explícita.
- [ ] Renderização: definir API e backends suportados.
- [ ] Janela, entrada, áudio e tempo.
- [ ] Exemplos, documentação de API e pipeline de CI.

O roadmap é indicativo e pode mudar à medida que as decisões técnicas forem validadas.

## Desenvolvimento

Antes de propor uma contribuição, confira [`docs/architecture.md`](docs/architecture.md). Mantenha o código em Zig, minimize dependências e inclua testes para comportamentos novos ou alterados.

Sugestão de verificação local:

```sh
zig build
zig build test
```

## Contribuições

Issues e pull requests são bem-vindos. Para mudanças grandes, abra primeiro uma issue para discutir objetivo, escopo e impacto na arquitetura.

## Licença

CoreX é distribuída sob a licença MIT. Consulte [`LICENSE`](LICENSE).
