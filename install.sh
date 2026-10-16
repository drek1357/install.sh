#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[-] Будь ласка, запустіть цей скрипт через sudo: sudo ./install.sh"
    exit 1
fi

echo "[+] Збереження поточної конфігурації та останніх GPS-координат (якщо існують)..."
if [ -f /opt/buddy/config.json ]; then
    cp /opt/buddy/config.json /tmp/buddy_config_backup.json
fi
if [ -f /opt/buddy/gps_last.json ]; then
    cp /opt/buddy/gps_last.json /tmp/buddy_gps_backup.json
fi

echo "[+] Зупинка старих служб та завислих процесів..."
for srv in wifi-failover.service buddy.service nrk-buddy.service; do
    systemctl stop "$srv" 2>/dev/null || true
    systemctl disable "$srv" 2>/dev/null || true
    rm -f "/etc/systemd/system/$srv"
done
systemctl daemon-reload

# Примусово завершуємо будь-які старі процеси Python, запущені з /opt/buddy
pkill -f "/opt/buddy/app.py" 2>/dev/null || true
pkill -f "/opt/buddy/" 2>/dev/null || true

echo "[+] Очищення старих та неправильних скриптів на Raspberry Pi..."
rm -rf /opt/buddy
rm -f ./install.sh /root/install.sh /tmp/install.sh /home/*/install.sh 2>/dev/null || true
rm -f ./*failover*.sh /root/*failover*.sh /home/*/*failover*.sh 2>/dev/null || true

echo "[+] Старі файли очищено. Встановлення системних залежностей..."
apt update
apt install -y python3 python3-flask python3-waitress network-manager iw curl iptables iproute2

if ! command -v zerotier-cli &> /dev/null; then
    echo "[+] Встановлення ZeroTier..."
    curl -s https://install.zerotier.com | bash
fi

echo "[+] Налаштування ZeroTier та NetworkManager (щоб NM не скидав інтерфейси zt*)..."
mkdir -p /etc/NetworkManager/conf.d
cat << 'NM_EOF' > /etc/NetworkManager/conf.d/99-unmanaged-zerotier.conf
[keyfile]
unmanaged-devices=interface-name:zt*
NM_EOF
systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true

systemctl enable zerotier-one 2>/dev/null || true
systemctl start zerotier-one 2>/dev/null || true

echo "[+] Увімкнення Wi-Fi модуля wlan0..."
nmcli radio wifi on 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true

echo "[+] Створення робочої директорії /opt/buddy..."
mkdir -p /opt/buddy
chmod 700 /opt/buddy
cd /opt/buddy

if [ -f /tmp/buddy_config_backup.json ]; then
    mv /tmp/buddy_config_backup.json /opt/buddy/config.json
    chmod 600 /opt/buddy/config.json
    echo "[+] Попередній config.json успішно відновлено!"
fi
if [ -f /tmp/buddy_gps_backup.json ]; then
    mv /tmp/buddy_gps_backup.json /opt/buddy/gps_last.json
    chmod 600 /opt/buddy/gps_last.json
    echo "[+] Попередні координати gps_last.json успішно відновлено!"
fi

echo "[+] Створення файлу app.py..."
cat << 'EOF' > /opt/buddy/app.py
#!/usr/bin/env python3
import os
import re
import json
import math
import shlex
import socket
import struct
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import logging
from logging.handlers import RotatingFileHandler
from functools import wraps
from flask import Flask, Response, jsonify, render_template_string, request

CONFIG_FILE = "/opt/buddy/config.json"
GPS_CACHE_FILE = "/opt/buddy/gps_last.json"

def load_config():
    default_config = {
        "admin_user": os.getenv("BUDDY_USER", "admin"),
        "admin_pass": os.getenv("BUDDY_PASS", "admin"),
        "telegram_token": os.getenv("BUDDY_TG_TOKEN", ""),
        "telegram_chat_id": os.getenv("BUDDY_TG_CHAT_ID", ""),
        "zerotier_net": "",
        "mavlink_port": 14550,
        "mavlink_local_src": 14555,
        "qgc_target_ip": "",
        "allow_open_wifi": True,
        "offline_gps_alert_sec": 300,
        "gps_max_speed_mps": 35.0,
        "gps_jump_threshold_m": 150.0
    }
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                for k, v in default_config.items():
                    if k not in data:
                        data[k] = v
                return data
        except Exception as e:
            logging.error(f"Помилка читання конфігурації: {e}")
    return default_config

def save_config_file(cfg):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=4, ensure_ascii=False)
        os.chmod(CONFIG_FILE, 0o600)
    except Exception as e:
        logging.error(f"Помилка збереження конфігурації: {e}")

config = load_config()

log_formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
file_handler = RotatingFileHandler('/opt/buddy/buddy.log', maxBytes=2*1024*1024, backupCount=3, encoding='utf-8')
file_handler.setFormatter(log_formatter)
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_formatter)
logging.basicConfig(level=logging.INFO, handlers=[file_handler, console_handler])

app = Flask(__name__)

LAN_IFACE = "eth0"
WLAN_IFACE = "wlan0"
MAX_TELEGRAM_QUEUE_SIZE = 100

# Глобальні змінні стану
state_lock = threading.Lock()
current_mode = "LAN"           # "LAN" або "WIFI"
lan_has_internet = False
wlan_has_internet = False
lan_recovery_waiting = False   # True, коли ми на Wi-Fi, а на LAN з'явився інтернет
wifi_signal_strength = "Не підключено"
active_wifi_ssid = ""
failover_in_progress = False
mavlink_status_text = "Перевірка..."
mavlink_packets_count = 0

# Відстеження втрати інтернету (> 5 хвилин)
all_internet_lost_since = None
all_internet_alert_sent = False
lan_internet_lost_since = None
lan_internet_alert_sent = False
last_gps_disk_save = 0.0

# Стан GPS та анти-спуфінгу
gps_state = {
    "has_fix": False,
    "fix_type": 0,
    "satellites": 0,
    # Остання відома достовірна координата (без спуфінгу)
    "valid_lat": None,
    "valid_lon": None,
    "valid_alt_m": None,
    "valid_speed_mps": 0.0,
    "valid_eph": None,
    "valid_timestamp": None,
    # Поточна (сира) координата
    "raw_lat": None,
    "raw_lon": None,
    "raw_alt_m": None,
    "raw_timestamp": None,
    # Дані про виявлений спуфінг
    "spoofing_detected": False,
    "spoof_lat": None,
    "spoof_lon": None,
    "spoof_alt_m": None,
    "spoof_reason": "",
    "spoof_jump_m": 0.0,
    "spoof_speed_mps": 0.0,
    "spoof_timestamp": None,
    "spoof_alert_sent": False,
    "consistent_recovery_hits": 0
}

def load_gps_cache():
    """Завантажує останні відомі координати GPS із диска після перезапуску."""
    if os.path.exists(GPS_CACHE_FILE):
        try:
            with open(GPS_CACHE_FILE, "r", encoding="utf-8") as f:
                saved = json.load(f)
            with state_lock:
