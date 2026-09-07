#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_SOURCE="$ROOT/Сканировать SCX-4200.app"
DRIVER_SOURCE="$ROOT/Samsung SCX-4200 driver"
QUEUE_NAME="Samsung_SCX_4200_Series"
PPD_PATH="/Library/Printers/PPDs/Contents/Resources/Samsung SCX-4200 Series.gz"

if [[ ! -d "$APP_SOURCE" || ! -d "$DRIVER_SOURCE" ]]; then
  echo "Комплект установки повреждён: не найдены приложение или драйвер."
  read -k 1 '?Нажмите любую клавишу для выхода.'
  exit 1
fi

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
  echo "Этот готовый комплект собран для Mac с Apple Silicon (M1/M2/M3/M4)."
  echo "На Intel-Mac программу нужно собрать из исходников из репозитория GitHub."
  read -k 1 '?Нажмите любую клавишу для выхода.'
  exit 1
fi

echo "Установка Samsung SCX-4200"
echo ""
echo "1 из 4. Устанавливаю приложение..."
sudo /usr/bin/ditto "$APP_SOURCE" "/Applications/Сканировать SCX-4200.app"

echo "2 из 4. Устанавливаю компоненты печати Samsung..."
if [[ "$(/usr/bin/uname -m)" == "arm64" ]]; then
  # Samsung's legacy print filter is Intel-only and needs Rosetta on Apple Silicon.
  /usr/sbin/softwareupdate --install-rosetta --agree-to-license 2>/dev/null || true
fi
sudo /usr/bin/install -d -m 755 "/Library/Printers/Samsung/Filters" "/Library/Printers/Samsung/SCX-4200" "/Library/Printers/PPDs/Contents/Resources"
sudo /usr/bin/install -m 755 "$DRIVER_SOURCE/rastertosec" "/Library/Printers/Samsung/Filters/rastertosec"
sudo /usr/bin/install -m 644 "$DRIVER_SOURCE/GrayHT_600" "/Library/Printers/Samsung/SCX-4200/GrayHT_600"
sudo /usr/bin/install -m 644 "$DRIVER_SOURCE/Gray1D_600" "/Library/Printers/Samsung/SCX-4200/Gray1D_600"
sudo /usr/bin/install -m 644 "$DRIVER_SOURCE/Samsung SCX-4200 Series.gz" "$PPD_PATH"

echo "3 из 4. Устанавливаю компонент сканирования..."
if [[ -x /opt/homebrew/bin/brew ]]; then
  BREW=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
  BREW=/usr/local/bin/brew
else
  echo "Homebrew не найден. Будет запущена его официальная установка; может потребоваться пароль администратора."
  /bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    BREW=/usr/local/bin/brew
  else
    echo "Homebrew не установился, поэтому сканирование пока не настроено. Запустите этот файл ещё раз."
    exit 1
  fi
fi
"$BREW" install sane-backends

echo "4 из 4. Ищу подключённый SCX-4200..."
DEVICE_URI="$(/usr/sbin/lpinfo -v 2>/dev/null | /usr/bin/awk '/usb:\/\/Samsung\/SCX-4200/ { print $2; exit }')"
if [[ -n "$DEVICE_URI" ]]; then
  sudo /usr/sbin/lpadmin -p "$QUEUE_NAME" -E -v "$DEVICE_URI" -P "$PPD_PATH"
  sudo /usr/sbin/cupsenable "$QUEUE_NAME"
  echo "Готово. Принтер добавлен, сканирование доступно в приложении «Сканировать SCX-4200»."
else
  echo "Приложение и драйверы установлены, но принтер сейчас не найден по USB."
  echo "Подключите и включите SCX-4200, затем запустите этот файл ещё раз: он добавит очередь печати."
fi

open "/Applications/Сканировать SCX-4200.app"
read -k 1 '?Нажмите любую клавишу, чтобы закрыть это окно.'
