# CLAUDE.md

Orientações para instâncias do Claude Code e desenvolvedores que forem trabalhar
neste repositório.

## 1. Visão geral

Este repo (`dockers/`) é a **camada de orquestração / self-hosting** de uma stack
caseira: cada serviço tem seu próprio `docker-compose.*.yml` na raiz, e um
**Traefik** (atrás de um túnel Cloudflare) roteia tudo por `Host(...)`. Aqui não
mora a lógica de negócio — ela vive nos subprojetos (`backend/`, `bolao/`,
`jone-piece/`, …), cada um um **repositório git independente** clonado dentro
desta pasta.

> 📖 A referência operacional completa de **cada** `docker-compose.*.yml` (imagem,
> portas, volumes, comandos, pegadinhas) está em **`must_know.md`** na raiz. Este
> CLAUDE.md é o mapa de alto nível; consulte o `must_know.md` para o detalhe de um
> serviço específico.

## 2. Stack e arquitetura

```
Internet → Cloudflared (túnel) → Traefik (:80/:443, dashboard :8080)
                                    ├── nextjs-app   → Jone Piece (Next.js)      [rede: traefik]
                                    ├── bolao-app    → Bolão Copa 2026 (Vite SPA/PWA) [rede: traefik]
                                    ├── jone-api     → backend Fastify           [traefik + jonepiece_net]
                                    ├── smash        → Smash Night Manager (Vite)[rede: traefik]
                                    ├── 3d           → Jone 3D (Vite)            [rede: traefik]
                                    ├── n8n          → automações                [rede: traefik]
                                    └── filebrowser  → arquivos                  [rede: traefik]

   jonepiece-db (Postgres 16) ──< jone-api,  jonepiece-backup (pg_dump 4/4h)   [rede: jonepiece_net, privada]
   plex (network_mode: host, fora do Traefik, :32400)
```

**Duas redes Docker, ambas `external: true`** (precisam existir antes de subir):
- `traefik` — roteamento HTTP/HTTPS público (criada pelo compose do Traefik, tem `name: traefik`).
- `jonepiece_net` — tráfego privado com o Postgres, **não exposto** (crie à mão: `docker network create jonepiece_net`).

**O `backend/` é uma API Fastify única que serve dois apps** por prefixo
(ver `backend/src/index.ts`):
- `/jone-piece/*` → arcos, capítulos, highlights, config, auth, reading-progress.
- `/bolao/*` → palpites, resultados, ranking, prazos, amistosos da Copa 2026.

Tecnologias por subprojeto:

| Subprojeto            | Stack                                  | Build / runtime                       |
| --------------------- | -------------------------------------- | ------------------------------------- |
| `backend/`            | Fastify 5 + TS + `pg` + JWT + Swagger  | `tsc` → Node 20; migrations no startup |
| `jone-piece/jone-piece/` | Next.js 15 + React 18 + Tailwind + Radix | `next build`                       |
| `bolao/`              | React 18 + Vite 5 (sem router/UI libs) | `vite build` → nginx (PWA instalável) |
| `smash-night-manager/`| React + Vite + Radix                   | `vite build` → nginx                  |
| `jone-3d/`            | React + Vite + Radix                   | `vite build` → nginx (gitignored)     |

## 3. Estrutura de pastas

```
dockers/
  docker-compose.*.yml   # 1 arquivo por serviço (traefik, postgres, backend, nextjs, bolao, …)
  .env                   # TODAS as variáveis (gitignored) — lido por todos os composes
  must_know.md           # referência detalhada de cada compose (LEIA antes de mexer em infra)
  scripts/               # scripts auxiliares (ex.: pg_backup.sh, usado pelo backup.yml)

  backend/               # API Fastify (repo git próprio). src/routes/{jone-piece,bolao}/, src/db/migrations/
  jone-piece/jone-piece/ # frontend Next.js do Jone Piece (repo git próprio; note a pasta dupla)
  bolao/                 # frontend do Bolão (repo git próprio) — tem seu próprio CLAUDE.md
  smash-night-manager/   # frontend Smash (repo git próprio)
  jone-3d/               # frontend Jone 3D (repo git próprio, conteúdo gitignored aqui)

  n8n-compose/, openclaw/# Dockerfiles/compose de serviços auxiliares
  media/, plexmediaserver/, repomix/, old/   # dados/legado (gitignored)
```

Cada subprojeto tem seu próprio histórico git, `package.json` e build. **Antes de
trabalhar dentro de um deles, leia o CLAUDE.md / must_know.md local** se existir
(ex.: `bolao/CLAUDE.md`, `jone-piece/must_know.md`) — eles documentam convenções
específicas (estado, scoring, adaptadores id↔nome, etc.).

## 4. Comandos essenciais

Todos os comandos de Docker rodam **a partir de `dockers/`**.

```bash
# Ordem de bootstrap em servidor novo:
docker network create jonepiece_net                                   # rede privada (1x por máquina)
docker compose -f docker-compose.traefik.yml  up -d                   # cria a rede `traefik` + roteador
docker compose -f docker-compose.postgres.yml up -d                   # banco
docker compose -f docker-compose.backend.yml  up -d --build           # API (migrations rodam no startup)
docker compose -f docker-compose.backup.yml   up -d                   # pg_dump a cada 4h
docker compose -f docker-compose.nextjs.yml   up -d --build           # frontends…
docker compose -f docker-compose.bolao.yml    up -d --build
# … cloudflared, n8n, filebrowser, smash, 3d, plex

# Operação genérica (troque <nome>):
docker compose -f docker-compose.<nome>.yml up -d [--build]           # subir/atualizar
docker compose -f docker-compose.<nome>.yml down                      # parar (preserva volumes nomeados)
docker compose -f docker-compose.<nome>.yml logs -f                   # logs
docker compose -f docker-compose.<nome>.yml config                    # validar (resolve o .env)

# Banco de dados:
docker exec -it jonepiece-db psql -U jonepiece -d jonepiece           # psql dentro do container
psql -h localhost -p 5433 -U jonepiece -d jonepiece                   # de fora (porta 5433, só localhost)

# API (Swagger): http://localhost:4000/docs  (prod: https://<DOMAIN_NAME_JONE_API>/docs)
```

Desenvolvimento local de cada app (fora do Docker):

```bash
# backend
cd backend && npm install && npm run dev        # tsx watch, porta 4000 (precisa do Postgres no ar)
                          npm run build          # tsc → dist/

# jone-piece (frontend Next.js)
cd jone-piece/jone-piece && npm run dev          # next dev --turbopack
                            npm run test:run      # vitest run    /  npm run lint

# bolao / smash / jone-3d (Vite)
cd bolao && npm run dev                           # vite, http://localhost:5173
            npm run build                         # tsc -b + vite build
            npm run typecheck                      # (bolao) tsc --noEmit — não há testes/linter
```

### Migrations (backend)

São arquivos `.sql` numerados em `backend/src/db/migrations/`, executados
**automaticamente** no startup do container (`runMigrations` em
`src/index.ts`); a tabela `_migrations` registra o que já rodou, então nunca
reexecutam. Para adicionar uma: crie `0NN_descricao.sql`, depois
`docker compose -f docker-compose.backend.yml up -d --build`.

## 5. Configuração

Tudo vem de **um único `.env` na raiz de `dockers/`** (gitignorado). Não há
`.env` por serviço — cada compose interpola desse arquivo. Principais chaves
(lista completa e quem usa cada uma está no `must_know.md`):

| Variável | Usada por |
| --- | --- |
| `POSTGRES_PASSWORD` | postgres, backend, backup |
| `JWT_SECRET` | backend |
| `JONE_PIECE_MEDIA_DIR` | nextjs (volumes de capítulos), backup |
| `DOMAIN_NAME_JONE` / `DOMAIN_NAME_JONE_API` / `DOMAIN_NAME_BOLAO` | nextjs, backend (CORS via `ALLOWED_ORIGIN`), bolao |
| `SUBDOMAIN_*` / `DOMAIN_NAME_*` | n8n, filebrowser, smash, 3d, plex |
| `TUNNEL_TOKEN` | cloudflared |

Para dev local de frontend, cada subprojeto usa seu próprio `.env`/`.env.local`
(ex.: `jone-piece/jone-piece/.env.local` com `API_URL=http://localhost:4000`).

## 6. Convenções e cuidados

- **`--build` é obrigatório** ao mudar código ou build args de qualquer serviço com
  `build:` (backend, nextjs, bolao, smash, 3d, n8n). Sem ele a imagem antiga continua rodando.
- **Build args de front entram em build time:** `NEXT_PUBLIC_API_URL` (Next) e
  `VITE_API_URL` (Vite) são embutidos na imagem ao buildar. Mudou a URL da API →
  **rebuild**; passar via `-e` no `docker run` não funciona.
- **Redes externas primeiro:** `jonepiece_net` é criada à mão; a `traefik` nasce com
  o compose do Traefik. Subir um serviço antes das redes existirem falha.
- **NUNCA `down -v`** em serviços com dados. Volumes/dados persistentes:
  `jonepiece_pgdata` (Postgres), `~/.n8n` (n8n), `plexmediaserver/` (Plex), `filebrowser.db`.
  Sempre faça `pg_dump` antes de qualquer operação destrutiva no banco.
- **Subprojetos são repos git separados:** commits de código de um app vão no repo
  daquele app, não neste. Este repo versiona os composes, `.env` (ignorado),
  scripts e docs. `media/`, `plexmediaserver/`, `repomix/`, `old/`, `jone-3d/`,
  `openclaw/` e `.env` estão no `.gitignore`.
- **Conflito de nome `smash`:** `docker-compose.smash.yml` e `docker-compose.3d.yml`
  definem ambos um serviço chamado `smash` — mantenha-os em projetos/arquivos separados
  para não colidir nome de container.
- **Postgres:** porta `5433` no host (5432 já estava ocupada por outro Postgres local);
  o banco só é acessível por `localhost` e pela rede `jonepiece_net`, nunca pelo Traefik.
- **Backend exposto só em `127.0.0.1:4000`**; o acesso público é via Traefik em
  `DOMAIN_NAME_JONE_API`. Backups (`backup.yml`) são independentes do banco — subir/derrubar não o afeta.
- **Código e comentários:** o padrão dos subprojetos é código em inglês e comentários
  (quando necessários, explicando o *porquê*) em português. Siga o estilo já presente
  em cada repo.
