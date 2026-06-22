# Must Know — Docker Compose Files

> Referência rápida de **todos** os `docker-compose.*.yml` da pasta `dockers/`:
> o que cada um faz, como configurar e os principais comandos.
> Todos os comandos devem ser rodados a partir de `dockers/`.

---

## Visão geral da arquitetura

```
Internet
   │
   ├── Cloudflared (tunnel)  ─┐
   │                          ▼
   └────────────────────►  Traefik  (:80 / :443, dashboard :8080)
                              │  (roteia por Host, rede `traefik`)
                              ├── nextjs-app     → Jone Piece (front)
                              ├── bolao-app      → Bolão (front)
                              ├── jone-api       → backend (também em jonepiece_net)
                              ├── smash          → Smash Night Manager
                              ├── 3d / smash(3d) → Jone 3D
                              ├── n8n            → automações
                              └── filebrowser    → arquivos

      jonepiece-db  (Postgres, rede `jonepiece_net`)
          ▲   ▲
          │   └── jonepiece-backup  (pg_dump a cada 4h)
          └────── jone-api

      plex  (network_mode: host — fora do Traefik)
```

### Duas redes Docker (ambas **externas** — criadas fora dos composes)

| Rede           | Quem usa                                                        | Para quê                                  |
| -------------- | --------------------------------------------------------------- | ----------------------------------------- |
| `traefik`      | traefik, nextjs, bolao, jone-api, smash, 3d, n8n, filebrowser, cloudflared | Roteamento HTTP/HTTPS público             |
| `jonepiece_net`| jonepiece-db, jone-api, jonepiece-backup                        | Tráfego privado com o Postgres (não exposto) |

> ⚠️ Como são `external: true`, precisam existir **antes** de subir os serviços:
> ```bash
> docker network create jonepiece_net
> # a rede `traefik` é criada pelo próprio compose do Traefik (tem `name: traefik`)
> ```

---

## Variáveis de ambiente (`.env`)

Todos os composes leem do arquivo `.env` na raiz de `dockers/`. Principais chaves:

| Variável                  | Usada por                       |
| ------------------------- | ------------------------------- |
| `POSTGRES_PASSWORD`       | postgres, backend, backup       |
| `JWT_SECRET`              | backend                         |
| `JONE_PIECE_MEDIA_DIR`    | nextjs (capítulos), backup      |
| `DOMAIN_NAME_JONE` / `DOMAIN_NAME_JONE_API` | nextjs, backend, bolao |
| `DOMAIN_NAME_BOLAO`       | bolao, backend (CORS)           |
| `SUBDOMAIN_* / DOMAIN_NAME_*` | n8n, filebrowser, smash, 3d, plex |
| `TUNNEL_TOKEN`            | cloudflared                     |
| `GENERIC_TIMEZONE`, `SSL_EMAIL` | n8n / geral               |
| `VAPID_PUBLIC_KEY`        | backend (Web Push) **+ bolao** (build-arg `VITE_VAPID_PUBLIC_KEY`) |
| `VAPID_PRIVATE_KEY`       | backend (Web Push) — privada, nunca no front |
| `VAPID_SUBJECT`           | backend (Web Push) — `mailto:` ou URL do app |

> **Web Push do bolão:** gere o par 1× com `npx web-push generate-vapid-keys`.
> A pública vai em `VAPID_PUBLIC_KEY` (usada pelo backend e embutida no bundle do
> bolão em build time); a privada em `VAPID_PRIVATE_KEY` (só backend). Sem as
> chaves o push fica desligado (no-op). Trocar a pública exige **rebuild** do
> `bolao` (é `VITE_*`, build time).

---

## Ordem de inicialização (servidor novo)

```bash
# 1. Rede privada do banco (uma vez por máquina)
docker network create jonepiece_net

# 2. Traefik (cria a rede `traefik` e é o roteador de tudo)
docker compose -f docker-compose.traefik.yml up -d

# 3. Banco de dados
docker compose -f docker-compose.postgres.yml up -d

# 4. Backend (as migrations rodam sozinhas no startup)
docker compose -f docker-compose.backend.yml up -d --build

# 5. Backups do banco
docker compose -f docker-compose.backup.yml up -d

# 6. Frontends e demais serviços (na ordem que quiser)
docker compose -f docker-compose.nextjs.yml up -d --build
docker compose -f docker-compose.bolao.yml up -d --build
# ... cloudflared, n8n, filebrowser, smash, 3d, plex
```

---

## Comandos genéricos (valem para qualquer arquivo)

```bash
# Subir / atualizar (use --build quando o serviço tem `build:`)
docker compose -f docker-compose.<nome>.yml up -d [--build]

# Parar e remover os containers (NÃO remove volumes nomeados)
docker compose -f docker-compose.<nome>.yml down

# Ver logs
docker compose -f docker-compose.<nome>.yml logs -f

# Reiniciar
docker compose -f docker-compose.<nome>.yml restart

# Validar o arquivo (resolve o .env)
docker compose -f docker-compose.<nome>.yml config
```

> ⚠️ **Nunca** use `down -v` em serviços com dados (postgres) — o `-v` apaga os volumes nomeados.

---

## Detalhe de cada arquivo

### `docker-compose.traefik.yml` — Reverse proxy

- **Imagem:** `traefik:v2.11`. Roteia por `Host(...)` lendo as `labels` dos outros containers.
- **Rede:** `traefik` (definida aqui com `name: traefik`, driver bridge).
- **Portas:** `80` (web), `443` (websecure), `8080` (dashboard — `api.insecure=true`).
- **Monta** `/var/run/docker.sock` (read-only) para descobrir os containers.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.traefik.yml up -d
  docker compose -f docker-compose.traefik.yml logs -f   # ver roteamento/TLS
  ```

### `docker-compose.postgres.yml` — Banco de dados

- **Imagem:** `postgres:16-alpine`. Database `jonepiece`, schemas `public`, `users`, `bolao`.
- **Rede:** `jonepiece_net` (privada). **Porta:** `5433:5432` no host.
- **Volume nomeado:** `jonepiece_pgdata` → **onde vivem os dados** (persiste a `down`, recriação e `--build`).
- **Comandos:**
  ```bash
  docker compose -f docker-compose.postgres.yml up -d
  # acessar o psql:
  docker exec -it jonepiece-db psql -U jonepiece -d jonepiece
  # conectar de fora (porta 5433):
  psql -h localhost -p 5433 -U jonepiece -d jonepiece
  ```
- ⚠️ As mudanças de schema **não** são feitas pelo Postgres e sim pelas migrations do backend no startup. `--build` aqui é inócuo (imagem pronta).

### `docker-compose.backend.yml` — API (`jone-api`)

- **Build:** `./backend`. Fastify + JWT. **Redes:** `traefik` + `jonepiece_net`.
- **Porta:** `127.0.0.1:4000:4000` (só local; o acesso público é via Traefik em `DOMAIN_NAME_JONE_API`).
- **Env:** `DATABASE_URL`, `JWT_SECRET`, `ALLOWED_ORIGIN` (CORS de Jone + Bolão + localhost).
- **Migrations rodam automaticamente** ao subir (inclui `refresh_tokens`).
- **Comandos:**
  ```bash
  docker compose -f docker-compose.backend.yml up -d --build   # aplica novas migrations
  docker compose -f docker-compose.backend.yml logs -f         # acompanhar [migrate] no startup
  ```

### `docker-compose.backup.yml` — Backup do Postgres

- **Imagem:** `postgres:16-alpine` (mesmo `pg_dump` da versão do banco). **Rede:** `jonepiece_net`.
- Roda `scripts/pg_backup.sh` em loop: **dump comprimido a cada 4h**, mantendo os **últimos 4 dias** (`RETENTION_DAYS=4`).
- **Destino:** `${JONE_PIECE_MEDIA_DIR}/backups` (ao lado de `caps_en/`, sem misturar com os capítulos).
- **Comandos:**
  ```bash
  docker compose -f docker-compose.backup.yml up -d
  docker logs -f jonepiece-backup                     # acompanhar os ciclos
  ls -lh "$JONE_PIECE_MEDIA_DIR"/backups              # listar dumps
  # restaurar um dump:
  gunzip -c "$JONE_PIECE_MEDIA_DIR"/backups/jonepiece_AAAAMMDD_HHMMSS.sql.gz \
    | docker exec -i jonepiece-db psql -U jonepiece -d jonepiece
  ```
- ℹ️ Backup fica no mesmo disco do banco — protege contra erro lógico/migration, não contra perda física do disco.

### `docker-compose.nextjs.yml` — Front Jone Piece (`nextjs-app`)

- **Build:** `./jone-piece/jone-piece`. **Rede:** `traefik`. **Domínio:** `DOMAIN_NAME_JONE`.
- **Build arg** `NEXT_PUBLIC_API_URL` é resolvido em **build time** → mudou a URL da API? **precisa `--build`**.
- **Volumes:** monta `caps_en` e `One_Piece_Colored` do `JONE_PIECE_MEDIA_DIR` em `/app/public`.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.nextjs.yml up -d --build
  ```

### `docker-compose.bolao.yml` — Front Bolão (`bolao-app`)

- **Build:** `./bolao` (Vite). **Rede:** `traefik`. **Domínio:** `DOMAIN_NAME_BOLAO`.
- **Build arg** `VITE_API_URL` é resolvido em **build time** → qualquer mudança exige **`--build`**.
- **PWA instalável:** o app é um PWA (manifest + service worker manual, sem deps novas).
  Pegadinhas de infra:
  - O `Dockerfile` faz `COPY public/ ./public/` — sem isso o `manifest.webmanifest`,
    o `sw.js` e os ícones **não vão pra imagem**.
  - O `nginx.conf` serve `sw.js` e `manifest.webmanifest` com `Cache-Control: no-cache`
    (antes da regra de cache imutável de `*.js`), senão o browser fica preso numa versão
    velha do service worker e nunca atualiza.
  - O SW só intercepta **GET same-origin** (app shell/assets); chamadas à API (`/bolao`,
    cross-origin) e os PUT/POST passam direto pela rede — não cacheia dado dinâmico.
  - Ícones gerados de `public/icons/icon.svg` via `./scripts/gen-icons.sh` (requer `inkscape`).
- **Comandos:**
  ```bash
  docker compose -f docker-compose.bolao.yml up -d --build
  ```

### `docker-compose.smash.yml` — Smash Night Manager

- **Build:** `./smash-night-manager`. **Rede:** `traefik`. **Domínio:** `SUBDOMAIN_SMASH.DOMAIN_NAME_SMASH`. Porta interna 80.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.smash.yml up -d --build
  ```

### `docker-compose.3d.yml` — Jone 3D

- **Build:** `./jone-3d` (serviço nomeado `smash` no arquivo). **Rede:** `traefik`. **Domínio:** `SUBDOMAIN_3D.DOMAIN_NAME_3D`. Porta interna 80.
- ⚠️ O serviço chama-se `smash` (igual ao do smash.yml). Suba em arquivos/projetos separados para não colidir nome de container.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.3d.yml up -d --build
  ```

### `docker-compose.n8n.yml` — Automações (`n8n`)

- **Build:** `./n8n-compose`. **Rede:** `traefik`. **Domínio:** `SUBDOMAIN_N8N.DOMAIN_NAME_N8N` (porta 5678).
- **Volume:** `/home/aojo/.n8n:/home/node/.n8n` (workflows/credenciais — **dados persistentes**).
- **Comandos:**
  ```bash
  docker compose -f docker-compose.n8n.yml up -d --build
  ```

### `docker-compose.filebrowser.yml` — Gerenciador de arquivos

- **Imagem:** `filebrowser/filebrowser`. **Rede:** `traefik`. **Domínio:** `SUBDOMAIN_FILE.DOMAIN_NAME_FILE`. **Porta:** `8081:8080`.
- **Volumes:** `~/Documentos` → `/srv`, `Media` → `/srv/LivrosAna`, e o banco `filebrowser.db`.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.filebrowser.yml up -d
  ```

### `docker-compose.cloudflared.yml` — Túnel Cloudflare

- **Imagem:** `cloudflare/cloudflared:latest`. **Rede:** `traefik`. Roda `tunnel --no-autoupdate run` com `TUNNEL_TOKEN`.
- Expõe os serviços para a internet sem abrir portas no roteador.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.cloudflared.yml up -d
  docker compose -f docker-compose.cloudflared.yml logs -f   # status do túnel
  ```

### `docker-compose.plex.yml` — Plex Media Server

- **Imagem:** `plexinc/pms-docker:latest`. **`network_mode: host`** → **não passa pelo Traefik** (porta 32400 direto no host).
- Usa `/dev/dri` (transcode por GPU Intel) e reserva GPU Nvidia via `deploy.resources`.
- **Volumes:** `./plexmediaserver` (config) e `./media/{tv,movies,music,transcode}`.
- **Comandos:**
  ```bash
  docker compose -f docker-compose.plex.yml up -d
  # acesso: http://<ip-do-host>:32400/web
  ```

---

## Armadilhas comuns (pegadinhas)

- **`--build` é obrigatório** ao mudar código ou build args de qualquer serviço com `build:` (backend, nextjs, bolao, smash, 3d, n8n). Sem isso a imagem antiga continua rodando.
- **Front (Vite/Next):** `VITE_*` e `NEXT_PUBLIC_*` entram na imagem em **build time** — mudou a URL da API → **rebuild**.
- **Redes externas primeiro:** `jonepiece_net` precisa ser criada manualmente; a `traefik` nasce com o compose do Traefik.
- **Dados persistentes:** `jonepiece_pgdata` (Postgres), `~/.n8n` (n8n), `plexmediaserver/` (Plex), `filebrowser.db`. **Nunca** rode `down -v` neles.
- **Backups ≠ banco:** subir/derrubar `docker-compose.backup.yml` não afeta o Postgres nem as APIs.
- **Conflito de nome `smash`:** `smash.yml` e `3d.yml` definem um serviço chamado `smash`; mantenha-os em arquivos/projetos separados.
