#!/bin/sh
# Rotina de backup do Postgres `jonepiece`.
# Roda em loop dentro do container: faz um pg_dump comprimido a cada
# BACKUP_INTERVAL_SECONDS e remove dumps mais antigos que RETENTION_DAYS.
#
# Restauração:
#   gunzip -c jonepiece_AAAAMMDD_HHMMSS.sql.gz | \
#     psql -h jonepiece-db -U jonepiece -d jonepiece
#
# Não usamos `set -e`: uma falha transitória (banco reiniciando) não deve
# derrubar o loop — o ciclo seguinte tenta de novo.
set -u

BACKUP_DIR="${BACKUP_DIR:-/backups}"
INTERVAL="${BACKUP_INTERVAL_SECONDS:-14400}"   # 4 horas
RETENTION_DAYS="${RETENTION_DAYS:-4}"

export PGHOST="${PGHOST:-jonepiece-db}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${POSTGRES_USER:-jonepiece}"
export PGDATABASE="${POSTGRES_DB:-jonepiece}"
# PGPASSWORD vem do environment do container.

log() { echo "[pg_backup] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

backup_once() {
  # Espera o banco ficar acessível antes de tentar o dump.
  until pg_isready -q; do
    log "aguardando ${PGHOST}:${PGPORT}..."
    sleep 5
  done

  ts=$(date -u '+%Y%m%d_%H%M%S')
  tmp="${BACKUP_DIR}/.${PGDATABASE}_${ts}.sql.gz.tmp"
  final="${BACKUP_DIR}/${PGDATABASE}_${ts}.sql.gz"

  # Escreve em arquivo temporário e só renomeia no sucesso — assim nunca
  # fica um dump truncado parecendo válido na pasta.
  if pg_dump --no-owner --no-privileges "$PGDATABASE" | gzip -c > "$tmp"; then
    mv "$tmp" "$final"
    log "backup criado: ${final} ($(du -h "$final" | cut -f1))"
  else
    log "ERRO: pg_dump falhou, descartando dump parcial"
    rm -f "$tmp"
    return 1
  fi

  # Retenção: remove dumps com mais de RETENTION_DAYS dias.
  # A cada 4h são ~6 dumps/dia → mantém ~24 backups (4 dias).
  deleted=$(find "$BACKUP_DIR" -name "${PGDATABASE}_*.sql.gz" -type f \
              -mtime "+${RETENTION_DAYS}" -print -delete | wc -l)
  if [ "$deleted" -gt 0 ]; then
    log "retenção: ${deleted} backup(s) antigo(s) removido(s)"
  fi
}

mkdir -p "$BACKUP_DIR"
log "iniciando rotina (intervalo=${INTERVAL}s, retenção=${RETENTION_DAYS}d, destino=${BACKUP_DIR})"

while true; do
  backup_once || log "ciclo falhou; nova tentativa no próximo intervalo"
  sleep "$INTERVAL"
done
