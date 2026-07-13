#!/bin/bash
# ==========================================================================
#  fimOS Официальный Сетевой Установщик (Artix + Runit + CachyOS + Hyprland)
# ==========================================================================

# 1. Проверка на статус суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запустите скрипт от имени root (sudo bash installer.sh)"
  exit 1
fi

echo "=========================================="
echo " Инициализация установщика fimOS..."
echo "=========================================="

# 2. Проверка интернета
echo "[1/3] Проверка подключения к интернету..."
if ! ping -c 1 8.8.8.8 &> /dev/null && ! ping -c 1 archlinux.org &> /dev/null; then
    echo "❌ Ошибка: Нет подключения к интернету!"
    echo "Настройте сеть (iwctl или nmtui) и запустите скрипт заново."
    exit 1
fi
echo "✅ Интернет подключен."

# 3. Установка утилит и РУССКОГО ШРИФТА
echo "[2/3] Настройка русского языка в консоли..."
pacman -Sy --noconfirm --needed dialog git parted dosfstools e2fsprogs terminus-font curl wget tar xz &> /dev/null

# Применяем кириллический шрифт (Terminus)
setfont ter-v16b || setfont cyr-sun16

# 4. Подключение репозиториев CachyOS в Live-ISO (чтобы basestrap нашел ядро)
echo "[3/3] Добавление репозиториев CachyOS..."
if ! grep -q "cachyos" /etc/pacman.conf; then
    curl -sL https://mirror.cachyos.org/cachyos-repo.tar.xz | tar xJ
    cd cachyos-repo && bash cachyos-repo.sh &> /dev/null
    cd .. && rm -rf cachyos-repo
fi

# Очистка экрана и запуск графического интерфейса
clear
dialog --backtitle "fimOS Installer v1.1" \
       --title " Добро пожаловать в fimOS! " \
       --msgbox "Привет! Этот скрипт установит fimOS на базе Artix Linux с ядром CachyOS.\n\nУбедись, что ноутбук подключен к питанию." 10 70

# ==========================================
# ЭТАП 1: ОПРОС ПОЛЬЗОВАТЕЛЯ
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
# ЭТАП 2: РАЗМЕТКА И МОНТИРОВАНИЕ
# ==========================================

DISK_LIST=$(lsblk -dno NAME,SIZE | grep -v "loop" | awk '{print $1 " [" $2 "]" " off"}')
TARGET_DISK=$(dialog --stdout --radiolist "Выберите диск для установки:" 15 60 5 $DISK_LIST)
[ -z "$TARGET_DISK" ] && exit 1
DISK_PATH="/dev/$TARGET_DISK"

MODE=$(dialog --stdout --menu "Выберите тип установки на $DISK_PATH:" 15 65 3 \
    1 "Стереть весь диск (Авторазметка + 2GB EFI)" \
    2 "Дуалбут (cfdisk + выбрать существующий EFI)")

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
        dialog --msgbox "Откроется cfdisk. Выделите место под fimOS (ext4), НЕ ТРОГАЙТЕ Windows и EFI!" 10 60
        cfdisk "$DISK_PATH"
        
        PART_LIST=$(lsblk -no NAME,SIZE "$DISK_PATH" | grep -v "loop" | awk '{print "/dev/"$1 " ["$2"]" " off"}')
        EFI_DEV=$(dialog --stdout --radiolist "Выберите СУЩЕСТВУЮЩИЙ раздел EFI (fat32):" 15 65 6 $PART_LIST)
        ROOT_DEV=$(dialog --stdout --radiolist "Выберите раздел под систему fimOS (ext4):" 15 65 6 $PART_LIST)
        
        mkfs.ext4 -F "$ROOT_DEV"
        
        mkdir -p /tmp/efi_mnt
        mount "$EFI_DEV" /tmp/efi_mnt
        EFI_SIZE=$(df -m /tmp/efi_mnt | awk 'NR==2 {print $2}')
        umount /tmp/efi_mnt
        
        if [ "$EFI_SIZE" -ge 2000 ]; then
            EFI_BACKUP_SUPPORT="YES"
        fi
        ;;
    *) exit 1 ;;
esac

mkdir -p /mnt
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_DEV" /mnt/boot/efi

# ==========================================
# ЭТАП 3: УСТАНОВКА БАЗЫ (ПРОВЕРКА НА ОШИБКИ)
# ==========================================
dialog --infobox "Шаг 1/5: Установка Artix, Runit и ядра CachyOS...\nЭто займет время, ждите." 5 60

# Добавил linux-firmware и elogind-runit (вместо несуществующего initloop)
if ! basestrap /mnt base base-devel runit elogind-runit linux-cachyos linux-cachyos-headers linux-firmware sudo nano zsh networkmanager networkmanager-runit; then
    clear
    echo "❌ ОШИБКА: Установка базовой системы (basestrap) прервалась!"
    echo "Проверьте подключение к интернету или доступность зеркал."
    umount -R /mnt
    exit 1
fi

fstabgen -U /mnt >> /mnt/etc/fstab

# Пробрасываем репозитории CachyOS внутрь установленной системы, чтобы она могла обновляться
artix-chroot /mnt /bin/bash -c "curl -sL https://mirror.cachyos.org/cachyos-repo.tar.xz | tar xJ && cd cachyos-repo && bash cachyos-repo.sh && cd .. && rm -rf cachyos-repo"

# ==========================================
# ЭТАП 4: ПОЛЬЗОВАТЕЛИ И ЛОКАЛИ
# ==========================================
dialog --infobox "Шаг 2/5: Настройка пользователей и языка..." 5 60

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
# ЭТАП 5: АВТОЛОГИН TTY1 И HYPRLAND
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
# ЭТАП 6: ЗАГРУЗЧИК
# ==========================================
dialog --infobox "Шаг 3/5: Настройка Initcpio и загрузчика..." 4 60

artix-chroot /mnt /bin/bash -c "mkinitcpio -p linux-cachyos"

if [ "$EFI_BACKUP_SUPPORT" == "YES" ]; then
    # Тут используем GRUB, так как systemd-boot конфликтует с runit
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm grub os-prober"
    artix-chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fimOS"
    artix-chroot /mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg"
else
    artix-chroot /mnt /bin/bash -c "pacman -S --noconfirm grub os-prober"
    artix-chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=fimOS"
    artix-chroot /mnt /bin/bash -c "grub-mkconfig -o /boot/grub/grub.cfg"
fi

# ==========================================
# ЭТАП 7: ФИНАЛЬНЫЕ КОНФИГИ
# ==========================================
dialog --infobox "Шаг 4/5: Установка графики..." 4 60

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
# ЭТАП 8: ФИНАЛ
# ==========================================
clear
dialog --title " Установка завершена! " \
       --yesno "Поздравляем! fimOS успешно установлена.\n\nПерезагрузить систему сейчас?" 10 60

if [ $? -eq 0 ]; then
    echo "Перезагрузка..."
    umount -R /mnt
    reboot
else
    echo "Выход в консоль. Размонтируйте /mnt перед перезагрузкой."
fi
