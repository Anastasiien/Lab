#!/usr/bin/env bash

# архивируем старые файлы, если папка превышает заданный размер

set -euo pipefail

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"; }

usage() {
    echo "Использование: $0 -d <папка> -t <порог> [-b <бэкап>] [-p <процент_удержания>]"
    exit 1
}

size_to_kb() {
    local size_str num unit
    size_str=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    num=$(echo "$size_str" | sed 's/[^0-9.]//g')
    unit=$(echo "$size_str" | sed 's/[0-9.]//g')

    case "$unit" in
        g|gb) awk -v n="$num" 'BEGIN { printf "%.0f\n", n * 1024 * 1024 }' ;;
        m|mb) awk -v n="$num" 'BEGIN { printf "%.0f\n", n * 1024 }' ;;
        k|kb|'') awk -v n="$num" 'BEGIN { printf "%.0f\n", n }' ;;
        *) log "Ошибка: неизвестная единица измерения размера '$1'"; exit 1 ;;
    esac
}

format_kb() {
    local s=$1
    if (( s > 1024*1024 )); then
        printf "%.2fG" "$(awk -v s="$s" 'BEGIN{print s/1024/1024}')"
    elif (( s > 1024 )); then
        printf "%.2fM" "$(awk -v s="$s" 'BEGIN{print s/1024}')"
    else
        printf "%dK" "$s"
    fi
}

LOG_DIR=""; THRESHOLD_STR=""; BACKUP_DIR="/tmp/backups"; RETENTION_PERCENT=70 # По умолчанию 70%
while getopts ":d:t:b:p:h" opt; do
    case ${opt} in
        d) LOG_DIR=${OPTARG} ;;
        t) THRESHOLD_STR=${OPTARG} ;;
        b) BACKUP_DIR=${OPTARG} ;;
        p) RETENTION_PERCENT=${OPTARG} ;;
        *) usage ;;
    esac
done

if [ -z "$LOG_DIR" ] || [ -z "$THRESHOLD_STR" ]; then usage; fi
if [ ! -d "$LOG_DIR" ]; then log "Ошибка: папка '$LOG_DIR' не существует."; exit 1; fi

# главная часть
log "Проверка папки: $LOG_DIR"

CURRENT_SIZE_KB=$(du -sk "$LOG_DIR" | awk '{print $1}')
THRESHOLD_KB=$(size_to_kb "$THRESHOLD_STR")

log "Текущий размер: $(format_kb "$CURRENT_SIZE_KB")B. Порог: ${THRESHOLD_STR}B."

if (( CURRENT_SIZE_KB <= THRESHOLD_KB )); then
    log "Размер папки не превышает порог."
    exit 0
fi

mkdir -p "$BACKUP_DIR"

# Проверка процента
TARGET_SIZE_KB=$(awk -v t="$THRESHOLD_KB" -v p="$RETENTION_PERCENT" 'BEGIN { printf "%.0f", t * (p / 100) }')

log "Размер превышает порог. Целевой размер (${RETENTION_PERCENT}% от порога): $(format_kb "$TARGET_SIZE_KB")B."

KB_TO_FREE=$(( CURRENT_SIZE_KB - TARGET_SIZE_KB ))

if (( KB_TO_FREE <= 0 )); then
    log "Размер превышает порог, но находится в пределах удержания. Архивация не требуется."
    exit 0
fi

log "Нужно освободить как минимум $(format_kb "$KB_TO_FREE")B."

# форматирование
STAT_ARGS=()
if [[ "$(uname)" == "Darwin" ]]; then STAT_ARGS=(-f '%m %z %N'); else STAT_ARGS=(-c '%Y %s %n'); fi

files_to_archive=()
accumulated_size_kb=0
while read -r timestamp size_bytes file_path; do
    # накапливаем файлы, пока не достигнем объема, который нужно освободить
    if (( accumulated_size_kb < KB_TO_FREE )); then
        size_kb=$(( (size_bytes + 1023) / 1024 ))
        accumulated_size_kb=$(( accumulated_size_kb + size_kb ))
        files_to_archive+=("$file_path")
    else
        break
    fi
# используем sort -n для сортировки по timestamp (самые старые первыми)
done < <(find "$LOG_DIR" -maxdepth 1 -type f -exec stat "${STAT_ARGS[@]}" {} + | sort -n)

if [ ${#files_to_archive[@]} -eq 0 ]; then
    log "Не найдено файлов для архивации (или все файлы новые)."
    exit 0
fi

log "Будет заархивировано ${#files_to_archive[@]} файлов (~$(format_kb "$accumulated_size_kb")B) для освобождения места."

# архивация
ARCHIVE_FILE="$BACKUP_DIR/archive-$(date +'%Y%m%d-%H%M%S')"

if [ "${LAB1_MAX_COMPRESSION:-0}" == "1" ]; then
    log "Используется максимальное сжатие lzma (xz)."
    ARCHIVE_FILE+=".tar.xz"
    TAR_OPTS=(-cJf "$ARCHIVE_FILE")
else
    log "Используется стандартное сжатие gzip."
    ARCHIVE_FILE+=".tar.gz"
    TAR_OPTS=(-czf "$ARCHIVE_FILE")
fi

(
    tar -C "$LOG_DIR" "${TAR_OPTS[@]}" "${files_to_archive[@]##*/}"
)

# проверяем и удаляем
if [ -s "$ARCHIVE_FILE" ]; then
    log "Архив успешно создан. Удаление исходных файлов..."
    # проверяем, что удаляются только файлы, которые были включены в архив
    printf '%s\0' "${files_to_archive[@]}" | xargs -0 rm -f
else
    log "Ошибка: архив не был создан или пуст. Исходные файлы не удалены."
    exit 1
fi

log "Архивация завершена. Архив сохранен в: $ARCHIVE_FILE"

FINAL_SIZE_KB=$(du -sk "$LOG_DIR" | awk '{print $1}')
log "Новый размер папки: $(format_kb "$FINAL_SIZE_KB")B."
