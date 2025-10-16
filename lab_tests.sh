#!/usr/bin/env bash

set -euo pipefail
SCRIPT_TO_TEST="./lab_main.sh"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

tests_passed=0
tests_failed=0

# виртуальный диск
DISK_IMAGE_PATH="/tmp/lab_test_vdisk.dmg"
MOUNT_POINT="/Volumes/LAB_VDISK"
DISK_SIZE="2g" # размер вд

setup_virtual_disk() {
    echo "--- Инициализация Виртуального Диска ---"
    
    hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
    rm -f "$DISK_IMAGE_PATH"

    echo "Создание образа диска ($DISK_SIZE) в $DISK_IMAGE_PATH..."
    hdiutil create -size "$DISK_SIZE" -fs HFS+ -volname "LAB_VDISK" "$DISK_IMAGE_PATH" &>/dev/null
    
    echo "Монтирование образа диска в $MOUNT_POINT..."
    hdiutil attach "$DISK_IMAGE_PATH" -mountpoint "$MOUNT_POINT" &>/dev/null
    
    if [ ! -d "$MOUNT_POINT" ]; then
        echo -e "${RED}Ошибка: Не удалось смонтировать образ диска в $MOUNT_POINT. Проверьте hdiutil.${NC}"
        cleanup_virtual_disk
        exit 1
    fi
    echo -e "${GREEN}Виртуальный диск успешно смонтирован в $MOUNT_POINT.${NC}"
}

cleanup_virtual_disk() {
    echo "--- Размонтирование и Очистка ---"
    if hdiutil info | grep -q "$MOUNT_POINT"; then
        echo "Размонтирование $MOUNT_POINT..."
        hdiutil detach "$MOUNT_POINT" &>/dev/null
    fi
    rm -f "$DISK_IMAGE_PATH"
    echo "Очистка завершена."
}

# если все плохо
check_script_exists() {
    if [[ ! -x "$SCRIPT_TO_TEST" ]]; then
        echo -e "${RED}Ошибка: Скрипт '$SCRIPT_TO_TEST' не найден или не является исполняемым.${NC}"
        cleanup_virtual_disk
        exit 1
    fi
}

create_file() {
    dd if=/dev/zero of="$1" bs=1M count="$2" &>/dev/null
}

assert() {
    local description="$1"
    local condition="$2"

    if eval "$condition"; then
        echo -e "  [${GREEN}PASS${NC}] $description"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "  [${RED}FAIL${NC}] $description"
        tests_failed=$((tests_failed + 1))
    fi
}

run_test_scenario() {
    local test_name="$1"; shift
    local initial_mb="$1"; shift
    local threshold_size="$1"; shift
    local should_archive="$1"; shift
    
    echo "============================================================"
    echo "Тест: $test_name"
    
    local LOGDIR="$MOUNT_POINT/log"
    local BACKUPDIR="$MOUNT_POINT/backup"

    rm -rf "$LOGDIR" "$BACKUPDIR"
    mkdir -p "$LOGDIR" "$BACKUPDIR"
    
    echo "  - Создание ~$initial_mb MB тестовых данных в $LOGDIR..."
    local part_size=$((initial_mb / 10))
    [[ "$part_size" -eq 0 ]] && part_size=1
    
    for i in $(seq 10); do
        local file_path="$LOGDIR/file_$(printf "%02d" $i).log"
        create_file "$file_path" "$part_size"
        touch -mt "$(date -v -${i}M +%Y%m%d%H%M.%S 2>/dev/null || date -d "${i} minutes ago" +%Y%m%d%H%M.%S)" "$file_path"
        sleep 0.1
    done
    
    local initial_size_kb
    initial_size_kb=$(du -sk "$LOGDIR" | awk '{print $1}')
    echo "  - Начальный размер папки: ${initial_size_kb} KB"
    
    echo "  - Запуск cleanup_lab.sh с порогом '$threshold_size'..."
    "$SCRIPT_TO_TEST" -d "$LOGDIR" -t "$threshold_size" -b "$BACKUPDIR"

    local final_size_kb
    final_size_kb=$(du -sk "$LOGDIR" | awk '{print $1}')
    local archive_count
    archive_count=$(find "$BACKUPDIR" -name 'archive-*.tar.*' -print 2>/dev/null | wc -l)
    
    echo "  - Финальный размер папки: ${final_size_kb} KB"
    echo "  - Найдено архивов: $archive_count"
    
    if [[ "$should_archive" == "yes" ]]; then
        assert "Архивы были созданы" "[ $archive_count -gt 0 ]"
        assert "Размер папки уменьшился" "[ $final_size_kb -lt $initial_size_kb ]"
    else
        assert "Архивы не создавались" "[ $archive_count -eq 0 ]"
        assert "Размер папки не изменился" "[ $final_size_kb -eq $initial_size_kb ]"
    fi
}

# основная часть
trap cleanup_virtual_disk EXIT

check_script_exists
setup_virtual_disk

# T1: Должен архивировать файлы со стандартным gzip сжатием (размер превышает порог)
run_test_scenario "T1_Архивация_при_превышении" 1500 "1G" "yes"

# T2: Не должен ничего делать (размер меньше порога)
run_test_scenario "T2_Пропуск_при_нормальном_размере" 400 "1G" "no"

# T3: Должен архивировать с xz сжатием (тест на максимальное сжатие)
LAB1_MAX_COMPRESSION=1 run_test_scenario "T3_Максимальное_сжатие_XZ" 1800 "1.5G" "yes"

echo "============================================================"
# T4: Тест обработки ошибок - недоступная для записи папка бэкапов
echo "Тест: T4_Ошибка_доступа_к_бэкапам"
LOGDIR="$MOUNT_POINT/log_ro"
BACKUPDIR="$MOUNT_POINT/readonly_backup"
mkdir -p "$LOGDIR"
mkdir "$BACKUPDIR" && chmod 555 "$BACKUPDIR"
create_file "$LOGDIR/file.log" 100
echo "  - Запуск скрипта с недоступной для записи папкой бэкапов..."

if ! "$SCRIPT_TO_TEST" -d "$LOGDIR" -t "50M" -b "$BACKUPDIR" &>/dev/null; then
    assert "Скрипт завершился с ошибкой, как и ожидалось" "true"
else
    assert "Скрипт должен был завершиться с ошибкой, но этого не произошло" "false"
fi
rm -rf "$LOGDIR" "$BACKUPDIR"

echo "============================================================"
echo -e "Тестирование завершено."
echo -e "РЕЗУЛЬТАТ: ${GREEN}Пройдено: $tests_passed${NC}, ${RED}Провалено: $tests_failed${NC}."
if [ "$tests_failed" -gt 0 ]; then
    exit 1
fi
