#!/bin/bash
# ==========================================================================
#  fimOS Официальный Сетевой Установщик (Artix + Runit + CachyOS + Hyprland)
# ==========================================================================

# Проверка на статус суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root (sudo ./installer.sh)"
  exit 1
fi

# Очистка экрана и приветствие
clear
dialog --backtitle "fimOS Installer v1.0" \
       --title " Добро пожаловать в fimOS! " \
       --msgbox "Привет! Этот скрипт поможет тебе установить ультра-легкую fimOS на базе Artix Linux, с оптимизированным ядром CachyOS и окружением Hyprland.\n\nУбедись, что твой ноутбук подключен к интернету (через кабель или утилиту iwctl)." 12 70

# ==========================================
# ЭТАП 1: ОПРОС ПОЛЬЗОВАТЕЛЯ (СБОР ПЕРЕМЕННЫХ)
# ==========================================

# 1. Выбор локали / раскладки
LOCALE=$(dialog --stdout --menu "Выберите языковую локаль системы:" 12 55 2 \
    1 "ru_RU.UTF-8 (Русский)" \
    2 "en_US.UTF-8 (English)")

# 2. Опрос по кастомным компонентам
CHOICES=$(dialog --stdout --checklist "Выберите компоненты для установки:" 15 65 4 \
    1 "Пакетные менеджеры (Yay + Flatpak)" ON \
    2 "Окружение Hyprland (Конфиг imperative-dots)" ON \
    3 "Настройка Proton для запуска EXE-файлов" OFF)

# Проверяем, что выбрал пользователь
[[ "$CHOICES" == *"1"* ]] && INSTALL_MANAGERS="YES" || INSTALL_MANAGERS="NO"
[[ "$CHOICES" == *"2"* ]] && INSTALL_HYPRLAND="YES" || INSTALL_HYPRLAND="NO"
[[ "$CHOICES" == *"3"* ]] && INSTALL_PROTON="YES" || INSTALL_PROTON="NO"

# ==========================================
# ЭТАП 2: РАЗМЕТКА И МОНТИРОВАНИЕ ДИСКОВ
# ==========================================

# Проверяем, установлена ли утилита dialog
if ! command -v dialog &> /dev/null; then
    echo "Ошибка: утилита dialog не найдена. Установите её в Live-ISO."
    exit 1
fi

# 1. ВЫБОР ДИСКА ДЛЯ УСТАНОВКИ
# Получаем список доступных дисков (например, sda, nvme0n1)
DISK_LIST=$(lsblk -dno NAME,SIZE | awk '{print $1 " [" $2 "]" " off"}')

TARGET_DISK=$(dialog --stdout --radiolist "Выберите диск для установки fimOS:" 15 60 5 $DISK_LIST)
[ -z "$TARGET_DISK" ] && exit 1
DISK_PATH="/dev/$TARGET_DISK"

# 2. ВЫБОР РЕЖИМА: СТЕРЕТЬ ВСЁ ИЛИ ДУАЛБУТ
MODE=$(dialog --stdout --menu "Выберите тип установки на $DISK_PATH:" 15 65 3 \
    1 "Стереть весь диск (Автоматическая разметка + 2GB EFI)" \
    2 "Дуалбут / Кастомная разметка (Использовать существующий EFI)")

# Переменная для контроля бэкапа ядер CachyOS
EFI_BACKUP_SUPPORT="NO"

case $MODE in
    1)
        # --- РЕЖИМ: СТЕРЕТЬ ВСЁ ---
        dialog --infobox "Форматирование диска $DISK_PATH..." 3 50
        
        # Создаем таблицу GPT, 2GB под EFI, остальное под систему
        parted -s "$DISK_PATH" mklabel gpt
        parted -s "$DISK_PATH" mkpart primary fat32 1MiB 2048MiB
        parted -s "$DISK_PATH" set 1 esp on
        parted -s "$DISK_PATH" mkpart primary ext4 2048MiB 100%
        
        # Определяем имена созданных разделов
        if [[ "$DISK_PATH" == *"nvme"* ]]; then
            EFI_DEV="${DISK_PATH}p1"
            ROOT_DEV="${DISK_PATH}p2"
        else
            EFI_DEV="${DISK_PATH}1"
            ROOT_DEV="${DISK_PATH}2"
        fi
        
        # Форматируем
        mkfs.vfat -F 32 "$EFI_DEV"
        mkfs.ext4 -F "$ROOT_DEV"
        
        # Раздел гарантированно 2 ГБ, фича CachyOS доступна
        EFI_BACKUP_SUPPORT="YES"
        ;;
        
    2)
        # --- РЕЖИМ: ДУАЛБУТ / КАСТОМ ---
        # Показываем пользователю cfdisk для ручного выделения места (расширить/сжать/удалить)
        dialog --msgbox "Сейчас откроется утилита cfdisk.\nВыделите свободное место под fimOS (ext4), но НЕ ТРОГАЙТЕ раздел с Windows и существующий EFI!" 10 60
        cfdisk "$DISK_PATH"
        
        # Просим пользователя пальцем ткнуть в EFI и ROOT разделы
        PART_LIST=$(lsblk -no NAME,SIZE "$DISK_PATH" | awk '{print "/dev/"$1 " ["$2"]" " off"}')
        
        EFI_DEV=$(dialog --stdout --radiolist "Выберите СУЩЕСТВУЮЩИЙ раздел EFI (обычно fat32, ~100-500MB):" 15 65 6 $PART_LIST)
        ROOT_DEV=$(dialog --stdout --radiolist "Выберите созданный раздел под систему fimOS (ext4):" 15 65 6 $PART_LIST)
        
        # Форматируем только корень! EFI не трогаем, чтобы не снести загрузчик Windows
        mkfs.ext4 -F "$ROOT_DEV"
        
        # ПРОВЕРКА РАЗМЕРА EFI
        mkdir -p /tmp/efi_mnt
        mount "$EFI_DEV" /tmp/efi_mnt
        
        # Получаем размер в Мегабайтах
        EFI_SIZE=$(df -m /tmp/efi_mnt | awk 'NR==2 {print $2}')
        umount /tmp/efi_mnt
        
        if [ "$EFI_SIZE" -ge 2000 ]; then
            EFI_BACKUP_SUPPORT="YES"
            dialog --msgbox "Размер EFI: ${EFI_SIZE}MB. Места достаточно.\nФишка бэкапа ядер CachyOS будет включена." 8 55
        else
            EFI_BACKUP_SUPPORT="NO"
            dialog --msgbox "Размер EFI: ${EFI_SIZE}MB.\nРаздел слишком мал для хранения запасных ядер CachyOS.\nСистема установит только одно основное ядро, чтобы не сломать дуалбут." 10 55
        fi
        ;;
    *)
        exit 1
        ;;
esac

# 3. МОНТИРОВАНИЕ ДЛЯ УСТАНОВКИ
mkdir -p /mnt
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_DEV" /mnt/boot/efi

# Сохраняем статус поддержки бэкапа для следующего модуля установщика
echo "$EFI_BACKUP_SUPPORT" > /tmp/fimos_efi_backup_status
dialog --msgbox "Диски успешно подготовлены и примонтированы в /mnt!" 6 50

# ==========================================
# ДОПОЛНЕНИЕ: ПОДКЛЮЧЕНИЕ РЕПОЗИТОРИЕВ CACHYOS
# ==========================================
dialog --infobox "Подключение репозиториев CachyOS..." 3 50

# 1. Скачиваем и добавляем ключи CachyOS в Live-систему
curl -s https://mirror.cachyos.org/cachyos-repo.tar.xz | tar xJ -C /tmp
# Запускаем скрипт добавления репозиториев от CachyOS (он сам пропишет их в /etc/pacman.conf)
cd /tmp/cachyos-repo && ./cachyos-repo.sh

# 2. Чтобы репозитории появились и в УСТАНАВЛИВАЕМОЙ системе, 
# сначала создадим для неё папку /etc и скопируем туда готовый pacman.conf
mkdir -p /mnt/etc
cp /etc/pacman.conf /mnt/etc/pacman.conf

# ==========================================
# ЭТАП 3: БАЗОВАЯ УСТАНОВКА (BOOTSTRAP)
# ==========================================
dialog --infobox "Шаг 1/4: Установка базовой системы Artix и ядра CachyOS...\nЭто займет некоторое время." 5 60

# Подключаем репозитории CachyOS в Live-системе перед установкой (чтобы basestrap их видел)
# Скачиваем ключи и добавляем репы...
# ...

# Ставим базу, runit и ядро CachyOS
basestrap /mnt base base-devel runit initloop-runit linux-cachyos linux-cachyos-headers

# Генерируем таблицу разделов (fstab)
fstabgen -U /mnt >> /mnt/etc/fstab

# ==========================================
# ЭТАП 4: НАСТРОЙКА INITCPIO И ЗАГРУЗЧИКА
# ==========================================
dialog --infobox "Шаг 2/4: Настройка драйверов (Initcpio) и загрузчика..." 4 60

# Запускаем генерацию initramfs внутри новой системы
artix-chroot /mnt /bin/bash -c "mkinitcpio -p linux-cachyos"

# Логика загрузчика в зависимости от размера EFI
if [ "$EFI_BACKUP_SUPPORT" == "YES" ]; then
    # Ставим systemd-boot-nosystemd для бэкапа ядер
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm systemd-boot-nosystemd"
    # Настройка записи в EFI...
else
    # Ставим классический надежный GRUB для мелких EFI и дуалбута
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm grub os-prober"
    artix-chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fimOS"
    artix-chroot /mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg"
fi

# ==========================================
# ЭТАП 5: КОПИРОВАНИЕ КОНФИГОВ И БРЕНДИНГ
# ==========================================
dialog --infobox "Шаг 3/4: Клонирование конфигов fimOS..." 4 60

# 1. Записываем /etc/os-release
cat <<EOF > /mnt/etc/os-release
NAME="fimOS"
PRETTY_NAME="fimOS Linux"
ID=fimos
LIKE=artix
EOF

# 2. Скачиваем твои файлы (Fastfetch, Proton-скрипт) с твоего GitHub
git clone "https://github.com/dimonchik235/fimOS-installer.git" /tmp/fimos-resources
mkdir -p /mnt/etc/xdg/fastfetch
cp /tmp/fimos-resources/configs/fastfetch_config.jsonc /mnt/etc/xdg/fastfetch/
cp /tmp/fimos-resources/configs/fimos_logo.txt /mnt/etc/xdg/fastfetch/

# 3. Если выбран Hyprland — интегрируем установщик от ilyamiro
if [ "$INSTALL_HYPRLAND" == "YES" ]; then
    git clone https://github.com/ilyamiro/imperative-dots.git /mnt/etc/skel/imperative-dots
    # Запускаем его скрипт внутри chroot
    artix-chroot /mnt /bin/bash -c "cd /etc/skel/imperative-dots && chmod +x install.sh && ./install.sh"
    # Раскладываем по местам и чистим
    cp -r /mnt/etc/skel/imperative-dots/.config/* /mnt/etc/skel/.config/
    rm -rf /mnt/etc/skel/imperative-dots
fi

# 4. Если выбран Proton
if [ "$INSTALL_PROTON" == "YES" ]; then
    cp /tmp/fimos-resources/scripts/proton-launcher /mnt/usr/bin/fim-proton
    chmod +x /mnt/usr/bin/fim-proton
    # (Дополнительно дописываем ассоциацию .exe файлов)
fi

# 5. Установка Flatpak и Yay
if [ "$INSTALL_MANAGERS" == "YES" ]; then
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm flatpak"
    # Ставим yay из исходников или репозитория cachyos
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm yay"
fi

# ==========================================
# ЭТАП 6: ФИНАЛ И ПЕРЕЗАГРУЗКА
# ==========================================
clear
dialog --title " Установка завершена! " \
       --yesno "Поздравляем! fimOS успешно установлена на твой компьютер.\n\nПерезагрузить систему сейчас?" 10 60

if [ $? -eq 0 ]; then
    echo "Перезагрузка..."
    umount -R /mnt
    reboot
else
    echo "Выход в консоль Live-ISO. Не забудьте размонтировать /mnt перед перезагрузкой вручную."
fi

