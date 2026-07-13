#!/bin/bash
# ==========================================================================
#  fimOS Официальный Сетевой Установщик (Artix + Runit + CachyOS + Hyprland)
# ==========================================================================

# 1. Проверка на статус суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запустите скрипт от имени root (sudo ./install.sh)"
  exit 1
fi

echo "=========================================="
echo " Инициализация установщика fimOS..."
echo "=========================================="

# 2. Проверка интернета (пингуем сервера Google и Arch)
echo "[1/2] Проверка подключения к интернету..."
if ! ping -c 1 8.8.8.8 &> /dev/null && ! ping -c 1 archlinux.org &> /dev/null; then
    echo "❌ Ошибка: Нет подключения к интернету!"
    echo "Пожалуйста, подключите кабель или настройте Wi-Fi (команда: iwctl или nmtui) и запустите скрипт заново."
    exit 1
fi
echo "✅ Интернет подключен."

# 3. Установка нужных утилит для работы самого скрипта
# Флаг --needed пропустит пакеты, если они уже есть в Live-ISO
echo "[2/2] Установка зависимостей (dialog, git, parted)..."
pacman -Sy --noconfirm --needed dialog git parted dosfstools e2fsprogs &> /dev/null

# Еще одна проверка на случай, если репозитории Artix лежат и pacman ничего не скачал
if ! command -v dialog &> /dev/null; then
    echo "❌ Ошибка: Не удалось установить утилиту 'dialog'. Проверьте зеркала pacman."
    exit 1
fi

# Очистка экрана и запуск графического интерфейса
clear
dialog --backtitle "fimOS Installer v1.0" \
       --title " Добро пожаловать в fimOS! " \
       --msgbox "Привет! Этот скрипт поможет тебе установить ультра-легкую fimOS на базе Artix Linux, с оптимизированным ядром CachyOS и окружением Hyprland.\n\nУбедись, что твой ноутбук подключен к питанию." 10 70

# ==========================================
# ЭТАП 1: ОПРОС ПОЛЬЗОВАТЕЛЯ (СБОР ДАННЫХ)
# ==========================================

USERNAME=$(dialog --stdout --inputbox "Придумайте имя пользователя (только строчные буквы, например: dima):" 10 50)
[ -z "$USERNAME" ] && exit 1

USER_PASS=$(dialog --stdout --insecure --passwordbox "Введите пароль для пользователя $USERNAME:" 10 50)
ROOT_PASS=$(dialog --stdout --insecure --passwordbox "Введите пароль для суперпользователя (root):" 10 50)

LOCALE=$(dialog --stdout --menu "Выберите языковую локаль системы:" 12 55 2 \
    1 "ru_RU.UTF-8 (Русский)" \
    2 "en_US.UTF-8 (English)")

CHOICES=$(dialog --stdout --checklist "Выберите компоненты для установки:" 15 65 4 \
    1 "Пакетные менеджеры (Yay + Flatpak)" ON \
    2 "Окружение Hyprland (Запуск hypr-install.sh)" ON \
    3 "Настройка Proton для запуска EXE-файлов" OFF)

[[ "$CHOICES" == *"1"* ]] && INSTALL_MANAGERS="YES" || INSTALL_MANAGERS="NO"
[[ "$CHOICES" == *"2"* ]] && INSTALL_HYPRLAND="YES" || INSTALL_HYPRLAND="NO"
[[ "$CHOICES" == *"3"* ]] && INSTALL_PROTON="YES" || INSTALL_PROTON="NO"

# ==========================================
# ЭТАП 2: РАЗМЕТКА И МОНТИРОВАНИЕ ДИСКОВ
# ==========================================

DISK_LIST=$(lsblk -dno NAME,SIZE | grep -v "loop" | awk '{print $1 " [" $2 "]" " off"}')
TARGET_DISK=$(dialog --stdout --radiolist "Выберите диск для установки fimOS:" 15 60 5 $DISK_LIST)
[ -z "$TARGET_DISK" ] && exit 1
DISK_PATH="/dev/$TARGET_DISK"

MODE=$(dialog --stdout --menu "Выберите тип установки на $DISK_PATH:" 15 65 3 \
    1 "Стереть весь диск (Автоматическая разметка + 2GB EFI)" \
    2 "Дуалбут / Кастомная разметка (cfdisk + Использовать существующий EFI)")

EFI_BACKUP_SUPPORT="NO"

case $MODE in
    1)
        dialog --infobox "Форматирование диска $DISK_PATH..." 3 50
        parted -s "$DISK_PATH" mklabel gpt
        parted -s "$DISK_PATH" mkpart primary fat32 1MiB 2048MiB
        parted -s "$DISK_PATH" set 1 esp on
        parted -s "$DISK_PATH" mkpart primary ext4 2048MiB 100%
        
        if [[ "$DISK_PATH" == *"nvme"* ]]; then
            EFI_DEV="${DISK_PATH}p1"
            ROOT_DEV="${DISK_PATH}p2"
        else
            EFI_DEV="${DISK_PATH}1"
            ROOT_DEV="${DISK_PATH}2"
        fi
        
        mkfs.vfat -F 32 "$EFI_DEV"
        mkfs.ext4 -F "$ROOT_DEV"
        EFI_BACKUP_SUPPORT="YES"
        ;;
    2)
        dialog --msgbox "Сейчас откроется утилита cfdisk.\nВыделите свободное место под fimOS (ext4), но НЕ ТРОГАЙТЕ раздел с Windows и существующий EFI!" 10 60
        cfdisk "$DISK_PATH"
        
        PART_LIST=$(lsblk -no NAME,SIZE "$DISK_PATH" | grep -v "loop" | awk '{print "/dev/"$1 " ["$2"]" " off"}')
        EFI_DEV=$(dialog --stdout --radiolist "Выберите СУЩЕСТВУЮЩИЙ раздел EFI (fat32):" 15 65 6 $PART_LIST)
        ROOT_DEV=$(dialog --stdout --radiolist "Выберите созданный раздел под систему fimOS (ext4):" 15 65 6 $PART_LIST)
        
        mkfs.ext4 -F "$ROOT_DEV"
        
        mkdir -p /tmp/efi_mnt
        mount "$EFI_DEV" /tmp/efi_mnt
        EFI_SIZE=$(df -m /tmp/efi_mnt | awk 'NR==2 {print $2}')
        umount /tmp/efi_mnt
        
        if [ "$EFI_SIZE" -ge 2000 ]; then
            EFI_BACKUP_SUPPORT="YES"
            dialog --msgbox "Размер EFI: ${EFI_SIZE}MB.\nФишка бэкапа ядер CachyOS будет включена." 8 55
        else
            dialog --msgbox "Размер EFI: ${EFI_SIZE}MB.\nСлишком мало места для бэкапа ядер CachyOS. Установится только базовое ядро." 10 55
        fi
        ;;
    *)
        exit 1
        ;;
esac

mkdir -p /mnt
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_DEV" /mnt/boot/efi

# ==========================================
# ЭТАП 3: БАЗОВАЯ УСТАНОВКА И СИСТЕМА
# ==========================================
dialog --infobox "Шаг 1/5: Установка базовой системы Artix, Runit и ядра CachyOS..." 5 60

basestrap /mnt base base-devel runit initloop-runit linux-cachyos linux-cachyos-headers sudo nano zsh networkmanager networkmanager-runit
fstabgen -U /mnt >> /mnt/etc/fstab

# ==========================================
# ЭТАП 4: НАСТРОЙКА СИСТЕМЫ (ПОЛЬЗОВАТЕЛИ И ЛОКАЛИ)
# ==========================================
dialog --infobox "Шаг 2/5: Настройка пользователей, паролей и локализации..." 5 60

if [ "$LOCALE" == "1" ]; then
    echo "ru_RU.UTF-8 UTF-8" > /mnt/etc/locale.gen
    echo "LANG=ru_RU.UTF-8" > /mnt/etc/locale.conf
else
    echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
    echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
fi
artix-chroot /mnt locale-gen

artix-chroot /mnt /bin/bash -c "echo 'root:${ROOT_PASS}' | chpasswd"

artix-chroot /mnt /bin/bash -c "useradd -m -G wheel,audio,video,optical,storage -s /bin/zsh ${USERNAME}"
artix-chroot /mnt /bin/bash -c "echo '${USERNAME}:${USER_PASS}' | chpasswd"
artix-chroot /mnt /bin/bash -c "sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers"

artix-chroot /mnt /bin/bash -c "ln -s /etc/runit/sv/NetworkManager /etc/runit/runsvdir/default/"

# ==========================================
# ЭТАП 5: RUNIT АВТОЛОГИН И АВТОЗАПУСК HYPRLAND
# ==========================================

mkdir -p /mnt/etc/runit/sv/agetty-tty1
cat << EOF > /mnt/etc/runit/sv/agetty-tty1/conf
BAUD_RATE=38400
TERM_NAME=linux
GETTY_ARGS="--autologin ${USERNAME} --noclear"
EOF

cat << 'EOF' > "/mnt/home/${USERNAME}/.zprofile"
if [ -z "${DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec start-hyprland
fi
EOF
artix-chroot /mnt chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.zprofile"

# ==========================================
# ЭТАП 6: ЗАГРУЗЧИК И УСТАНОВКА МОДУЛЕЙ
# ==========================================
dialog --infobox "Шаг 3/5: Настройка Initcpio и загрузчика..." 4 60

artix-chroot /mnt /bin/bash -c "mkinitcpio -p linux-cachyos"

if [ "$EFI_BACKUP_SUPPORT" == "YES" ]; then
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm systemd-boot-nosystemd"
else
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm grub os-prober"
    artix-chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fimOS"
    artix-chroot /mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg"
fi

# ==========================================
# ЭТАП 7: ФИНАЛЬНЫЕ КОНФИГИ И HYPRLAND
# ==========================================
dialog --infobox "Шаг 4/5: Установка графики и дополнительных компонентов..." 4 60

cat <<EOF > /mnt/etc/os-release
NAME="fimOS"
PRETTY_NAME="fimOS Linux"
ID=fimos
LIKE=artix
EOF

if [ "$INSTALL_HYPRLAND" == "YES" ]; then
    git clone "https://github.com/dimonchik235/fimos-hyprland.git" /mnt/opt/fimos-hyprland
    artix-chroot /mnt /bin/bash -c "cd /opt/fimos-hyprland && chmod +x hypr-install.sh && ./hypr-install.sh ${USERNAME}"
fi

# ==========================================
# ЭТАП 8: ФИНАЛ И ПЕРЕЗАГРУЗКА
# ==========================================
clear
dialog --title " Установка завершена! " \
       --yesno "Поздравляем! fimOS успешно установлена.\n\nПерезагрузить систему сейчас?" 10 60

if [ $? -eq 0 ]; then
    echo "Перезагрузка..."
    umount -R /mnt
    reboot
else
    echo "Выход в консоль Live-ISO. Не забудьте размонтировать /mnt перед перезагрузкой вручную."
fi
