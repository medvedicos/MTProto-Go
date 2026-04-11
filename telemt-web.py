#!/usr/bin/env python3
"""
Telemt Web Dashboard

Установка:  pip install flask requests
Запуск:     DASHBOARD_PASSWORD=пароль python3 telemt-web.py

Переменные окружения:
  DASHBOARD_PASSWORD  — пароль для входа (обязательно задайте!)
  DASHBOARD_PORT      — порт (по умолчанию 8080)
  DASHBOARD_HOST      — адрес (по умолчанию 0.0.0.0)
  TELEMT_API          — адрес API telemt (по умолчанию http://127.0.0.1:9091)
  CONFIG_FILE         — путь к конфигу (по умолчанию /etc/telemt/telemt.toml)
"""

import os, re, json, subprocess, secrets
from functools import wraps
from datetime import datetime, timezone
from flask import Flask, render_template_string, request, redirect, url_for, session, jsonify
import requests as req

# ──────────────────────────────────────────────────────────────────────────────
TELEMT_API    = os.environ.get('TELEMT_API',          'http://127.0.0.1:9091')
CONFIG_FILE   = os.environ.get('CONFIG_FILE',         '/etc/telemt/telemt.toml')
STATS_FILE    = os.environ.get('STATS_FILE',          '/etc/telemt/telemt-traffic.json')
DASH_PASSWORD = os.environ.get('DASHBOARD_PASSWORD',  'changeme')
DASH_PORT     = int(os.environ.get('DASHBOARD_PORT',  8080))
DASH_HOST     = os.environ.get('DASHBOARD_HOST',      '0.0.0.0')
SECRET_KEY    = os.environ.get('SECRET_KEY',          secrets.token_hex(32))

app = Flask(__name__)
app.secret_key = SECRET_KEY

# ──────────────────────────────────────────────────────────────────────────────
# AUTH
# ──────────────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def deco(*a, **kw):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*a, **kw)
    return deco

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS — КОНФИГ
# ──────────────────────────────────────────────────────────────────────────────
def read_config():
    try:
        with open(CONFIG_FILE) as f:
            return f.read()
    except:
        return None

def write_config(content):
    try:
        with open(CONFIG_FILE, 'w') as f:
            f.write(content)
        return True, ''
    except Exception as e:
        return False, str(e)

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS — НАКОПЛЕННАЯ СТАТИСТИКА ТРАФИКА
# Telemt хранит счётчики в памяти и сбрасывает их при рестарте.
# Перед каждым рестартом снимаем снапшот и накапливаем в JSON-файл.
# ──────────────────────────────────────────────────────────────────────────────
def _read_stats():
    try:
        with open(STATS_FILE) as f:
            return json.load(f)
    except:
        return {}

def _write_stats(data):
    try:
        os.makedirs(os.path.dirname(STATS_FILE), exist_ok=True)
        with open(STATS_FILE, 'w') as f:
            json.dump(data, f, indent=2)
    except:
        pass

def snapshot_traffic():
    """
    Считывает текущую статистику из API и добавляет байты к накопленному
    историческому счётчику в STATS_FILE.
    Вызывается перед каждым рестартом службы.
    """
    try:
        data = req.get(f'{TELEMT_API}/v1/users', timeout=4).json()
    except:
        return
    if not data.get('ok'):
        return
    hist = _read_stats()
    for u in data.get('data', []):
        name  = u.get('username', '')
        octets = u.get('total_octets', 0) or 0
        if name and octets > 0:
            hist[name] = hist.get(name, 0) + octets
    _write_stats(hist)

def get_historical_traffic():
    """Возвращает dict {username: accumulated_bytes}."""
    return _read_stats()

# ──────────────────────────────────────────────────────────────────────────────
# Маппинг поля лимита → секция TOML
LIMIT_SECTIONS = {
    'max_tcp_conns':    'access.user_max_tcp_conns',
    'max_unique_ips':   'access.user_max_unique_ips',
    'data_quota_bytes': 'access.user_data_quota',
    'expiration_rfc3339': 'access.user_expirations',
}

def _set_section_entry(content, section, key, value):
    """
    Добавить/обновить/удалить запись key=value в секции [section].
    value=None — удаляет запись.
    Создаёт секцию, если её нет.
    """
    # Форматируем значение
    if value is None:
        val_str = None
    elif isinstance(value, str):
        val_str = f'"{value}"'
    else:
        val_str = str(int(value))

    # Ищем начало секции
    sec_match = re.search(
        rf'^\[{re.escape(section)}\][ \t]*\n', content, re.MULTILINE
    )

    if val_str is None:
        # Удаление: если секции нет — ничего не делаем
        if not sec_match:
            return content
        sec_start = sec_match.end()
        nxt = re.search(r'^\[', content[sec_start:], re.MULTILINE)
        sec_end = sec_start + nxt.start() if nxt else len(content)
        body = content[sec_start:sec_end]
        body = re.sub(rf'^{re.escape(key)}\s*=.*\n?', '', body, flags=re.MULTILINE)
        return content[:sec_start] + body + content[sec_end:]

    if not sec_match:
        # Секции нет — добавляем в конец
        return content.rstrip('\n') + f'\n\n[{section}]\n{key} = {val_str}\n'

    sec_start = sec_match.end()
    nxt = re.search(r'^\[', content[sec_start:], re.MULTILINE)
    sec_end = sec_start + nxt.start() if nxt else len(content)
    body = content[sec_start:sec_end]

    if re.search(rf'^{re.escape(key)}\s*=', body, re.MULTILINE):
        # Обновляем существующую запись
        body = re.sub(
            rf'^{re.escape(key)}\s*=.*$',
            f'{key} = {val_str}',
            body, flags=re.MULTILINE
        )
    else:
        # Добавляем новую запись в конец секции
        body = body.rstrip('\n') + f'\n{key} = {val_str}\n'

    return content[:sec_start] + body + content[sec_end:]

def add_user_to_config(username, secret, limits=None):
    """
    Добавляет пользователя:
      - секрет → [access.users]  username = "hex"
      - лимиты → [access.user_max_tcp_conns], [access.user_max_unique_ips] и т.д.
    """
    content = read_config()
    if content is None:
        return False, 'Не удалось прочитать конфиг'

    # Проверка дубликата в [access.users]
    sec_match = re.search(r'^\[access\.users\][ \t]*\n', content, re.MULTILINE)
    if sec_match:
        sec_start = sec_match.end()
        nxt = re.search(r'^\[', content[sec_start:], re.MULTILINE)
        sec_end = sec_start + nxt.start() if nxt else len(content)
        body = content[sec_start:sec_end]
        if re.search(rf'^{re.escape(username)}\s*=', body, re.MULTILINE):
            return False, f'Пользователь "{username}" уже существует'

    # Добавляем секрет в [access.users]
    content = _set_section_entry(content, 'access.users', username, secret)

    # Добавляем лимиты в соответствующие секции
    if limits:
        for field, section in LIMIT_SECTIONS.items():
            if limits.get(field):
                content = _set_section_entry(content, section, username, limits[field])

    return write_config(content)

def remove_user_from_config(username):
    """Удаляет пользователя из [access.users] и всех секций лимитов."""
    content = read_config()
    if content is None:
        return False, 'Не удалось прочитать конфиг'
    original = content

    # Удаляем из [access.users]
    content = _set_section_entry(content, 'access.users', username, None)
    # Удаляем из всех секций лимитов
    for section in LIMIT_SECTIONS.values():
        content = _set_section_entry(content, section, username, None)

    if content == original:
        return False, f'Пользователь "{username}" не найден в конфиге'
    return write_config(content)

def set_user_limits(username, limits):
    """
    Устанавливает или сбрасывает лимиты для существующего пользователя.
    limits — dict с ключами из LIMIT_SECTIONS; значение None — сброс лимита.
    """
    content = read_config()
    if content is None:
        return False, 'Не удалось прочитать конфиг'
    for field, section in LIMIT_SECTIONS.items():
        if field in limits:
            content = _set_section_entry(content, section, username, limits[field])
    return write_config(content)

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS — СЛУЖБА И API
# ──────────────────────────────────────────────────────────────────────────────
def service_action(action):
    # Перед рестартом/остановкой снимаем снапшот трафика
    if action in ('restart', 'stop'):
        snapshot_traffic()
    try:
        r = subprocess.run(['systemctl', action, 'telemt'],
                           capture_output=True, text=True, timeout=15)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except Exception as e:
        return False, str(e)

def service_status():
    try:
        r = subprocess.run(['systemctl', 'is-active', 'telemt'],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except:
        return 'unknown'

def telemt_get(path):
    try:
        r = req.get(f'{TELEMT_API}{path}', timeout=5)
        return r.json()
    except Exception as e:
        return {'ok': False, 'error': str(e)}

def fmt_bytes(b):
    b = b or 0
    if b < 1024:       return f'{b} Б'
    if b < 1024**2:    return f'{b/1024:.1f} КБ'
    if b < 1024**3:    return f'{b/1024**2:.1f} МБ'
    return f'{b/1024**3:.2f} ГБ'

def parse_quota(value_str, unit):
    """Перевод значения + единица в байты"""
    try:
        v = float(value_str)
        mult = {'mb': 1024**2, 'gb': 1024**3, 'tb': 1024**4}
        return int(v * mult.get(unit, 1024**3))
    except:
        return None

def fmt_quota(b):
    if not b:
        return None
    if b >= 1024**4:   return f'{b/1024**4:.2f} ТБ'
    if b >= 1024**3:   return f'{b/1024**3:.2f} ГБ'
    return f'{b/1024**2:.1f} МБ'

def is_hex32(s):
    return bool(re.match(r'^[0-9a-fA-F]{32}$', s))

def get_users_enriched():
    """Пользователи из API.
    Трафик = текущая сессия + накопленный исторический (сохраняется при рестартах).
    """
    data = telemt_get('/v1/users')
    users = data.get('data', []) if data.get('ok') else []
    hist  = get_historical_traffic()
    for u in users:
        name    = u.get('username', '')
        current = u.get('total_octets', 0) or 0
        # Суммируем с историческим (исторический уже включён в снапшот до рестарта)
        total   = hist.get(name, 0) + current
        u['total_octets_all'] = total
        u['traffic_fmt'] = fmt_bytes(total)
        # Лимиты нативно поддерживаются telemt и уже есть в API-ответе
        u['lim_conns']   = u.get('max_tcp_conns')
        u['lim_ips']     = u.get('max_unique_ips')
        u['lim_quota']   = fmt_quota(u.get('data_quota_bytes'))
        u['lim_expire']  = u.get('expiration_rfc3339')
        if u['lim_expire']:
            try:
                dt = datetime.fromisoformat(u['lim_expire'].replace('Z', '+00:00'))
                u['lim_expire_fmt']     = dt.strftime('%d.%m.%Y %H:%M UTC')
                u['lim_expire_expired'] = dt < datetime.now(timezone.utc)
            except:
                u['lim_expire_fmt']     = u['lim_expire']
                u['lim_expire_expired'] = False
        else:
            u['lim_expire_fmt']     = None
            u['lim_expire_expired'] = False
    total_conn    = sum(u.get('current_connections', 0) for u in users)
    total_ips     = sum(u.get('active_unique_ips', 0) for u in users)
    total_traffic = sum(u.get('total_octets_all', 0) for u in users)
    return users, total_conn, total_ips, fmt_bytes(total_traffic)

# ──────────────────────────────────────────────────────────────────────────────
# МАРШРУТЫ
# ──────────────────────────────────────────────────────────────────────────────
@app.route('/login', methods=['GET', 'POST'])
def login():
    err = None
    if request.method == 'POST':
        if request.form.get('password') == DASH_PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('index'))
        err = 'Неверный пароль'
    return render_template_string(LOGIN_HTML, err=err)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def index():
    users, tc, ti, tt = get_users_enriched()
    return render_template_string(DASH_HTML,
        users=users, total_conn=tc, total_ips=ti,
        total_traffic=tt, svc=service_status(), page='dash')

@app.route('/config')
@login_required
def config_page():
    return render_template_string(CONFIG_HTML,
        content=read_config() or '# файл не найден',
        svc=service_status(), page='config')

# API
@app.route('/api/stats')
@login_required
def api_stats():
    users, tc, ti, tt = get_users_enriched()
    return jsonify(dict(users=users, total_conn=tc, total_ips=ti,
                        total_traffic=tt, svc=service_status()))

@app.route('/api/user/add', methods=['POST'])
@login_required
def api_user_add():
    d = request.get_json() or {}
    username = d.get('username', '').strip()
    secret   = d.get('secret', '').strip() or secrets.token_hex(16)

    if not username:
        return jsonify({'ok': False, 'error': 'Укажите имя пользователя'})
    if not re.match(r'^[a-zA-Z0-9_-]{1,32}$', username):
        return jsonify({'ok': False, 'error': 'Имя: латиница, цифры, _ и - (до 32 симв.)'})
    if not is_hex32(secret):
        return jsonify({'ok': False, 'error': 'Секрет: ровно 32 hex-символа'})

    # Парсим лимиты для записи в TOML секции лимитов
    limits = {}
    if d.get('max_tcp_conns'):
        try: limits['max_tcp_conns'] = int(d['max_tcp_conns'])
        except: pass
    if d.get('max_unique_ips'):
        try: limits['max_unique_ips'] = int(d['max_unique_ips'])
        except: pass
    if d.get('quota_value') and d.get('quota_unit'):
        q = parse_quota(d['quota_value'], d['quota_unit'])
        if q: limits['data_quota_bytes'] = q
    if d.get('expiration'):
        try:
            datetime.fromisoformat(d['expiration'])
            limits['expiration_rfc3339'] = (
                d['expiration'] + ':00+00:00' if len(d['expiration']) == 16
                else d['expiration']
            )
        except: pass

    ok, err = add_user_to_config(username, secret, limits or None)
    if not ok:
        return jsonify({'ok': False, 'error': err})

    ok2, _ = service_action('restart')
    return jsonify({'ok': True, 'secret': secret, 'restarted': ok2})

@app.route('/api/user/delete', methods=['POST'])
@login_required
def api_user_delete():
    d = request.get_json() or {}
    username = d.get('username', '').strip()
    if not username:
        return jsonify({'ok': False, 'error': 'Укажите имя'})

    ok, err = remove_user_from_config(username)
    if not ok:
        return jsonify({'ok': False, 'error': err})

    ok2, _ = service_action('restart')
    return jsonify({'ok': True, 'restarted': ok2})

@app.route('/api/user/limits', methods=['POST'])
@login_required
def api_user_limits():
    d = request.get_json() or {}
    username = d.get('username', '').strip()
    if not username:
        return jsonify({'ok': False, 'error': 'Укажите имя пользователя'})

    limits = {}
    # max_tcp_conns: int или None
    if 'max_tcp_conns' in d:
        try:
            v = d['max_tcp_conns']
            limits['max_tcp_conns'] = int(v) if v else None
        except:
            limits['max_tcp_conns'] = None

    # max_unique_ips: int или None
    if 'max_unique_ips' in d:
        try:
            v = d['max_unique_ips']
            limits['max_unique_ips'] = int(v) if v else None
        except:
            limits['max_unique_ips'] = None

    # data_quota_bytes: конвертируем из value+unit или принимаем напрямую
    if d.get('quota_value') and d.get('quota_unit'):
        q = parse_quota(d['quota_value'], d['quota_unit'])
        limits['data_quota_bytes'] = q  # None если ошибка
    elif 'data_quota_bytes' in d:
        try:
            v = d['data_quota_bytes']
            limits['data_quota_bytes'] = int(v) if v else None
        except:
            limits['data_quota_bytes'] = None

    # expiration_rfc3339: строка или None
    if 'expiration' in d:
        v = d['expiration']
        if v:
            try:
                datetime.fromisoformat(v)
                limits['expiration_rfc3339'] = (
                    v + ':00+00:00' if len(v) == 16 else v
                )
            except:
                return jsonify({'ok': False, 'error': 'Неверный формат даты'})
        else:
            limits['expiration_rfc3339'] = None

    ok, err = set_user_limits(username, limits)
    if not ok:
        return jsonify({'ok': False, 'error': err})

    ok2, _ = service_action('restart')
    return jsonify({'ok': True, 'restarted': ok2})

@app.route('/api/service/<action>', methods=['POST'])
@login_required
def api_service(action):
    if action not in ('start', 'stop', 'restart'):
        return jsonify({'ok': False, 'error': 'Неверное действие'})
    ok, out = service_action(action)
    return jsonify({'ok': ok, 'output': out, 'svc': service_status()})

@app.route('/api/config/save', methods=['POST'])
@login_required
def api_config_save():
    d = request.get_json() or {}
    content = d.get('content', '')
    if not content.strip():
        return jsonify({'ok': False, 'error': 'Пустой конфиг'})
    ok, err = write_config(content)
    if not ok:
        return jsonify({'ok': False, 'error': err})
    ok2, _ = service_action('restart')
    return jsonify({'ok': True, 'restarted': ok2})

# ──────────────────────────────────────────────────────────────────────────────
# ОБЩИЕ ЧАСТИ HTML
# ──────────────────────────────────────────────────────────────────────────────
_HEAD = """<!DOCTYPE html>
<html lang="ru" data-bs-theme="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Telemt Dashboard</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.css">
<style>
  body{background:#0d1117}
  .navbar{background:#161b22!important;border-bottom:1px solid #30363d}
  .card{background:#161b22;border:1px solid #30363d}
  .link-box{font-size:.78rem;word-break:break-all;background:#0d1117;
             border:1px solid #30363d;border-radius:6px;padding:5px 10px;
             font-family:monospace}
  .stat-num{font-size:2rem;font-weight:700;line-height:1}
  #toast-wrap{position:fixed;bottom:1.5rem;right:1.5rem;z-index:9999;min-width:260px}
  .limit-badge{font-size:.7rem;opacity:.85}
  .expired{color:#f85149!important}
</style>
</head><body>"""

_SCRIPTS = """
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
<script>
// ── Toast ──────────────────────────────────────────────────────────────────
function toast(msg, type='success'){
  const w=document.getElementById('toast-wrap');
  const el=document.createElement('div');
  el.className=`alert alert-${type} shadow py-2 px-3 mb-2`;
  el.innerHTML=msg;
  w.appendChild(el);
  setTimeout(()=>el.remove(), 3800);
}

// ── Copy (работает на HTTP без HTTPS) ──────────────────────────────────────
function copyText(text){
  if(navigator.clipboard && window.isSecureContext){
    navigator.clipboard.writeText(text)
      .then(()=>toast('<i class="bi bi-check2"></i> Скопировано'))
      .catch(()=>fallbackCopy(text));
    return;
  }
  fallbackCopy(text);
}
function fallbackCopy(text){
  const el=document.createElement('textarea');
  el.value=text;
  el.style.cssText='position:fixed;top:-9999px;left:-9999px;opacity:0';
  document.body.appendChild(el);
  el.focus(); el.select();
  try{
    document.execCommand('copy');
    toast('<i class="bi bi-check2"></i> Скопировано');
  } catch(e){
    toast('Скопируйте вручную: Ctrl+C', 'warning');
    prompt('Скопируйте ссылку:', text);
  }
  document.body.removeChild(el);
}

// ── QR-код ─────────────────────────────────────────────────────────────────
function showQR(link){
  const c=document.getElementById('qr-box');
  c.innerHTML='';
  document.getElementById('qr-text').textContent=link;
  new QRCode(c,{text:link,width:256,height:256,
    colorDark:'#000',colorLight:'#fff',correctLevel:QRCode.CorrectLevel.M});
  new bootstrap.Modal(document.getElementById('qrModal')).show();
}

// ── Генератор секрета ──────────────────────────────────────────────────────
function genSecret(targetId){
  const a=new Uint8Array(16);
  crypto.getRandomValues(a);
  document.getElementById(targetId).value=
    Array.from(a).map(b=>b.toString(16).padStart(2,'0')).join('');
}

// ── Управление службой ─────────────────────────────────────────────────────
async function svcAction(action){
  const names={start:'Запуск',restart:'Перезапуск',stop:'Остановка'};
  toast(`<i class="bi bi-arrow-repeat"></i> ${names[action]}...`,'info');
  const r=await fetch(`/api/service/${action}`,{method:'POST'});
  const d=await r.json();
  updateSvcBadge(d.svc);
  toast(d.ok?'<i class="bi bi-check2-circle"></i> Готово'
            :`<i class="bi bi-x-circle"></i> Ошибка: ${d.output}`,
        d.ok?'success':'danger');
}
function updateSvcBadge(s){
  const el=document.getElementById('svc-badge');
  if(!el)return;
  el.className='badge px-3 py-2 '+(s==='active'?'bg-success':'bg-secondary');
  el.textContent=s==='active'?'Активен':s;
}

// ── Добавить пользователя ──────────────────────────────────────────────────
async function addUser(){
  const username=document.getElementById('f-username').value.trim();
  const secret  =document.getElementById('f-secret').value.trim();
  const maxConn =document.getElementById('f-maxconn').value.trim();
  const maxIps  =document.getElementById('f-maxips').value.trim();
  const quotaVal=document.getElementById('f-quota').value.trim();
  const quotaUnit=document.getElementById('f-quota-unit').value;
  const expire  =document.getElementById('f-expire').value.trim();

  if(!username){toast('Введите имя пользователя','warning');return;}

  const btn=document.getElementById('btn-add');
  btn.disabled=true;
  btn.innerHTML='<span class="spinner-border spinner-border-sm"></span>';

  const r=await fetch('/api/user/add',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({
      username,secret,
      max_tcp_conns: maxConn||null,
      max_unique_ips: maxIps||null,
      quota_value: quotaVal||null,
      quota_unit: quotaUnit,
      expiration: expire||null
    })
  });
  const d=await r.json();
  btn.disabled=false;
  btn.innerHTML='<i class="bi bi-plus-lg"></i> Добавить';

  if(d.ok){
    toast(`<i class="bi bi-check2"></i> Пользователь <b>${username}</b> добавлен<br>
           Секрет: <code>${d.secret}</code>`,'success');
    // Очистить форму
    ['f-username','f-secret','f-maxconn','f-maxips','f-quota','f-expire']
      .forEach(id=>document.getElementById(id).value='');
    setTimeout(()=>location.reload(),2500);
  } else {
    toast(`<i class="bi bi-x-circle"></i> ${d.error}`,'danger');
  }
}

// ── Удалить пользователя ───────────────────────────────────────────────────
async function deleteUser(username){
  if(!confirm(`Удалить пользователя "${username}"?\nЭто действие необратимо.`))return;
  const r=await fetch('/api/user/delete',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({username})
  });
  const d=await r.json();
  if(d.ok){
    document.getElementById(`u-${username}`)?.remove();
    toast(`<i class="bi bi-check2"></i> Пользователь <b>${username}</b> удалён`,'success');
  } else {
    toast(`<i class="bi bi-x-circle"></i> ${d.error}`,'danger');
  }
}

// ── Авто-обновление статистики ─────────────────────────────────────────────
async function refreshStats(){
  try{
    const r=await fetch('/api/stats');
    const d=await r.json();
    document.getElementById('stat-conn')?.   setAttribute('data-val', d.total_conn);
    document.getElementById('stat-ips')?.    setAttribute('data-val', d.total_ips);
    document.getElementById('stat-traffic')?.setAttribute('data-val', d.total_traffic);
    document.getElementById('stat-conn').textContent    = d.total_conn;
    document.getElementById('stat-ips').textContent     = d.total_ips;
    document.getElementById('stat-traffic').textContent = d.total_traffic;
    updateSvcBadge(d.svc);
  }catch(e){}
}
setInterval(refreshStats, 10000);

// ── Редактирование лимитов ─────────────────────────────────────────────────
function bytesToQuota(bytes){
  if(!bytes) return {val:'', unit:'gb'};
  if(bytes >= 1024**4) return {val:(bytes/1024**4).toFixed(2), unit:'tb'};
  if(bytes >= 1024**3) return {val:(bytes/1024**3).toFixed(2), unit:'gb'};
  return {val:(bytes/1024**2).toFixed(1), unit:'mb'};
}
function openLimitsModal(username, maxConn, maxIps, quotaBytes, expire){
  document.getElementById('lm-username').value       = username;
  document.getElementById('lm-username-title').textContent = username;
  document.getElementById('lm-maxconn').value        = maxConn || '';
  document.getElementById('lm-maxips').value         = maxIps  || '';
  const q = bytesToQuota(quotaBytes);
  document.getElementById('lm-quota').value          = q.val;
  document.getElementById('lm-quota-unit').value     = q.unit;
  // Дата: конвертируем RFC3339 → datetime-local
  if(expire){
    try{
      const dt = new Date(expire);
      // datetime-local нужен формат YYYY-MM-DDTHH:MM
      const pad = n => String(n).padStart(2,'0');
      document.getElementById('lm-expire').value =
        `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth()+1)}-${pad(dt.getUTCDate())}` +
        `T${pad(dt.getUTCHours())}:${pad(dt.getUTCMinutes())}`;
    }catch(e){ document.getElementById('lm-expire').value=''; }
  } else {
    document.getElementById('lm-expire').value = '';
  }
  new bootstrap.Modal(document.getElementById('limitsModal')).show();
}
async function saveLimits(){
  const username  = document.getElementById('lm-username').value;
  const maxConn   = document.getElementById('lm-maxconn').value.trim();
  const maxIps    = document.getElementById('lm-maxips').value.trim();
  const quotaVal  = document.getElementById('lm-quota').value.trim();
  const quotaUnit = document.getElementById('lm-quota-unit').value;
  const expire    = document.getElementById('lm-expire').value.trim();

  const btn = document.getElementById('btn-limits-save');
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner-border spinner-border-sm"></span>';

  const r = await fetch('/api/user/limits', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({
      username,
      max_tcp_conns:  maxConn  || null,
      max_unique_ips: maxIps   || null,
      quota_value:    quotaVal || null,
      quota_unit:     quotaUnit,
      expiration:     expire   || null
    })
  });
  const d = await r.json();
  btn.disabled = false;
  btn.innerHTML = '<i class="bi bi-floppy-fill"></i> Сохранить';

  if(d.ok){
    bootstrap.Modal.getInstance(document.getElementById('limitsModal')).hide();
    toast(`<i class="bi bi-check2"></i> Лимиты пользователя <b>${username}</b> обновлены`,'success');
    setTimeout(()=>location.reload(), 2000);
  } else {
    toast(`<i class="bi bi-x-circle"></i> ${d.error}`, 'danger');
  }
}
</script>"""

_NAVBAR = """
<nav class="navbar navbar-expand-lg mb-4 px-3">
  <a class="navbar-brand fw-bold text-info" href="/">
    <i class="bi bi-shield-lock-fill me-2"></i>Telemt
  </a>
  <div class="ms-auto d-flex gap-2">
    <a href="/" class="btn btn-sm {% if page=='dash' %}btn-info{% else %}btn-outline-secondary{% endif %}">
      <i class="bi bi-speedometer2"></i> Дашборд
    </a>
    <a href="/config" class="btn btn-sm {% if page=='config' %}btn-info{% else %}btn-outline-secondary{% endif %}">
      <i class="bi bi-file-code"></i> Конфиг
    </a>
    <a href="/logout" class="btn btn-sm btn-outline-danger">
      <i class="bi bi-box-arrow-right"></i>
    </a>
  </div>
</nav>"""

_QR_MODAL = """
<div class="modal fade" id="qrModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content" style="background:#161b22;border:1px solid #30363d">
      <div class="modal-header border-secondary">
        <h5 class="modal-title text-info"><i class="bi bi-qr-code me-2"></i>QR-код</h5>
        <button class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body text-center">
        <div id="qr-box" class="d-inline-block" style="border:8px solid #fff;border-radius:8px"></div>
        <p class="text-secondary small mt-3 font-monospace" id="qr-text"
           style="word-break:break-all"></p>
      </div>
    </div>
  </div>
</div>"""

# ──────────────────────────────────────────────────────────────────────────────
# СТРАНИЦА ВХОДА
# ──────────────────────────────────────────────────────────────────────────────
LOGIN_HTML = _HEAD + """
<div class="container" style="max-width:380px;margin-top:14vh">
  <div class="card p-4 shadow">
    <h4 class="text-center mb-4 text-info">
      <i class="bi bi-shield-lock-fill me-2"></i>Telemt Dashboard
    </h4>
    {% if err %}
    <div class="alert alert-danger py-2 mb-3">{{ err }}</div>
    {% endif %}
    <form method="post">
      <div class="mb-3">
        <label class="form-label small text-secondary">Пароль</label>
        <input type="password" name="password" class="form-control" autofocus>
      </div>
      <button class="btn btn-info w-100 fw-bold">Войти</button>
    </form>
  </div>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
</body></html>"""

# ──────────────────────────────────────────────────────────────────────────────
# ДАШБОРД
# ──────────────────────────────────────────────────────────────────────────────
DASH_HTML = _HEAD + """
<div class="container-fluid px-3">
""" + _NAVBAR + """
<div id="toast-wrap"></div>

<!-- Статистика -->
<div class="row g-3 mb-4">
  <div class="col-6 col-md-3">
    <div class="card p-3 text-center">
      <div class="text-secondary small mb-1"><i class="bi bi-activity"></i> Статус службы</div>
      <div id="svc-badge" class="badge px-3 py-2 mx-auto
        {{ 'bg-success' if svc=='active' else 'bg-secondary' }}">
        {{ 'Активен' if svc=='active' else svc }}
      </div>
    </div>
  </div>
  <div class="col-6 col-md-3">
    <div class="card p-3 text-center">
      <div class="text-secondary small mb-1"><i class="bi bi-people-fill"></i> Подключений</div>
      <div class="stat-num text-info" id="stat-conn">{{ total_conn }}</div>
    </div>
  </div>
  <div class="col-6 col-md-3">
    <div class="card p-3 text-center">
      <div class="text-secondary small mb-1"><i class="bi bi-globe"></i> Активных IP</div>
      <div class="stat-num text-warning" id="stat-ips">{{ total_ips }}</div>
    </div>
  </div>
  <div class="col-6 col-md-3">
    <div class="card p-3 text-center">
      <div class="text-secondary small mb-1"><i class="bi bi-arrow-left-right"></i> Трафик</div>
      <div class="stat-num text-success" id="stat-traffic">{{ total_traffic }}</div>
    </div>
  </div>
</div>

<!-- Управление службой -->
<div class="card mb-4 p-3">
  <div class="d-flex align-items-center gap-2 flex-wrap">
    <span class="text-secondary me-1"><i class="bi bi-gear-fill"></i> Служба:</span>
    <button class="btn btn-sm btn-outline-success" onclick="svcAction('start')">
      <i class="bi bi-play-fill"></i> Старт
    </button>
    <button class="btn btn-sm btn-outline-warning" onclick="svcAction('restart')">
      <i class="bi bi-arrow-repeat"></i> Рестарт
    </button>
    <button class="btn btn-sm btn-outline-danger" onclick="svcAction('stop')">
      <i class="bi bi-stop-fill"></i> Стоп
    </button>
  </div>
</div>

<!-- Добавить пользователя -->
<div class="card mb-4 p-3">
  <h6 class="text-secondary mb-3">
    <i class="bi bi-person-plus-fill me-2"></i>Добавить пользователя
  </h6>
  <div class="row g-2 mb-2">
    <div class="col-md-4">
      <label class="form-label small text-secondary">Имя пользователя *</label>
      <input id="f-username" type="text" class="form-control form-control-sm"
             placeholder="myuser" pattern="[a-zA-Z0-9_-]+">
    </div>
    <div class="col-md-5">
      <label class="form-label small text-secondary">Секрет (пусто = авто)</label>
      <div class="input-group input-group-sm">
        <input id="f-secret" type="text" class="form-control font-monospace"
               placeholder="32 hex символа или оставьте пустым">
        <button class="btn btn-outline-secondary" onclick="genSecret('f-secret')"
                title="Сгенерировать">
          <i class="bi bi-shuffle"></i>
        </button>
      </div>
    </div>
    <div class="col-md-3 d-flex align-items-end">
      <button id="btn-add" class="btn btn-info btn-sm w-100" onclick="addUser()">
        <i class="bi bi-plus-lg"></i> Добавить
      </button>
    </div>
  </div>

  <!-- Ограничения (скрытые по умолчанию) -->
  <div>
    <button class="btn btn-sm btn-outline-secondary py-1 px-2 mb-2"
            type="button" data-bs-toggle="collapse" data-bs-target="#limits-form">
      <i class="bi bi-sliders me-1"></i>Ограничения <i class="bi bi-chevron-down"></i>
    </button>
    <div class="collapse" id="limits-form">
      <div class="row g-2 mt-1 p-2 border border-secondary rounded"
           style="background:#0d1117">
        <div class="col-sm-6 col-md-3">
          <label class="form-label small text-secondary">
            <i class="bi bi-link-45deg"></i> Макс. подключений
          </label>
          <input id="f-maxconn" type="number" min="1" class="form-control form-control-sm"
                 placeholder="без лимита">
        </div>
        <div class="col-sm-6 col-md-3">
          <label class="form-label small text-secondary">
            <i class="bi bi-geo-alt"></i> Макс. уникальных IP
          </label>
          <input id="f-maxips" type="number" min="1" class="form-control form-control-sm"
                 placeholder="без лимита">
        </div>
        <div class="col-sm-6 col-md-3">
          <label class="form-label small text-secondary">
            <i class="bi bi-database"></i> Квота трафика
          </label>
          <div class="input-group input-group-sm">
            <input id="f-quota" type="number" min="0.1" step="0.1"
                   class="form-control" placeholder="без лимита">
            <select id="f-quota-unit" class="form-select" style="max-width:70px">
              <option value="mb">МБ</option>
              <option value="gb" selected>ГБ</option>
              <option value="tb">ТБ</option>
            </select>
          </div>
        </div>
        <div class="col-sm-6 col-md-3">
          <label class="form-label small text-secondary">
            <i class="bi bi-calendar-x"></i> Срок действия
          </label>
          <input id="f-expire" type="datetime-local" class="form-control form-control-sm">
        </div>
        <div class="col-12">
          <p class="text-secondary small mb-0">
            <i class="bi bi-info-circle"></i>
            Ограничения записываются в нативные секции конфига telemt и применяются после перезапуска.
          </p>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- Карточки пользователей -->
<div id="users-list">
{% for u in users %}
<div class="card mb-3 p-3" id="u-{{ u.username }}">

  <!-- Заголовок -->
  <div class="d-flex justify-content-between align-items-start flex-wrap gap-2 mb-2">
    <div class="d-flex align-items-center gap-2 flex-wrap">
      <span class="fw-bold text-info fs-5">{{ u.username }}</span>
      {% if u.current_connections > 0 %}
      <span class="badge bg-success">{{ u.current_connections }} подкл.</span>
      {% endif %}
      <!-- Лимиты -->
      {% if u.lim_conns %}
      <span class="badge bg-secondary limit-badge" title="Макс. подключений">
        <i class="bi bi-link-45deg"></i> {{ u.lim_conns }}
      </span>
      {% endif %}
      {% if u.lim_ips %}
      <span class="badge bg-secondary limit-badge" title="Макс. IP">
        <i class="bi bi-geo-alt"></i> {{ u.lim_ips }} IP
      </span>
      {% endif %}
      {% if u.lim_quota %}
      <span class="badge bg-secondary limit-badge" title="Квота трафика">
        <i class="bi bi-database"></i> {{ u.lim_quota }}
      </span>
      {% endif %}
      {% if u.lim_expire_fmt %}
      <span class="badge {{ 'bg-danger' if u.lim_expire_expired else 'bg-secondary' }} limit-badge"
            title="Срок действия">
        <i class="bi bi-calendar-x"></i> {{ u.lim_expire_fmt }}
        {% if u.lim_expire_expired %} &#x26A0; Истёк{% endif %}
      </span>
      {% endif %}
    </div>
    <div class="d-flex gap-2 align-items-center">
      <span class="text-secondary small">{{ u.traffic_fmt }}</span>
      {% if u.active_unique_ips > 0 %}
      <span class="badge bg-secondary">{{ u.active_unique_ips }} IP</span>
      {% endif %}
      <button class="btn btn-sm btn-outline-secondary"
              onclick="openLimitsModal('{{ u.username }}',
                {{ u.lim_conns|tojson }},
                {{ u.lim_ips|tojson }},
                {{ u.get('data_quota_bytes')|tojson }},
                {{ u.lim_expire|tojson }})"
              title="Изменить лимиты">
        <i class="bi bi-sliders"></i>
      </button>
      <button class="btn btn-sm btn-outline-danger" onclick="deleteUser('{{ u.username }}')"
              title="Удалить пользователя">
        <i class="bi bi-trash"></i>
      </button>
    </div>
  </div>

  <!-- Активные IP -->
  {% if u.active_unique_ips_list %}
  <div class="mb-2">
    <small class="text-secondary">Сейчас онлайн: </small>
    {% for ip in u.active_unique_ips_list %}
    <span class="badge bg-dark border border-secondary font-monospace me-1">{{ ip }}</span>
    {% endfor %}
  </div>
  {% endif %}

  <!-- Ссылки -->
  <div class="row g-1 mt-1">
    {% if u.links.tls %}
    <div class="col-12">
      <div class="d-flex align-items-center gap-1">
        <span class="badge bg-info text-dark fw-bold" style="min-width:58px;font-size:.7rem">TLS</span>
        <div class="link-box flex-grow-1 text-info">{{ u.links.tls[0] }}</div>
        <button class="btn btn-sm btn-outline-info px-2" onclick="copyText('{{ u.links.tls[0] }}')"
                title="Копировать"><i class="bi bi-clipboard"></i></button>
        <button class="btn btn-sm btn-outline-secondary px-2" onclick="showQR('{{ u.links.tls[0] }}')"
                title="QR-код"><i class="bi bi-qr-code"></i></button>
      </div>
    </div>
    {% endif %}
    {% if u.links.secure %}
    <div class="col-12">
      <div class="d-flex align-items-center gap-1">
        <span class="badge bg-warning text-dark fw-bold" style="min-width:58px;font-size:.7rem">Secure</span>
        <div class="link-box flex-grow-1 text-warning">{{ u.links.secure[0] }}</div>
        <button class="btn btn-sm btn-outline-warning px-2" onclick="copyText('{{ u.links.secure[0] }}')"
                title="Копировать"><i class="bi bi-clipboard"></i></button>
        <button class="btn btn-sm btn-outline-secondary px-2" onclick="showQR('{{ u.links.secure[0] }}')"
                title="QR-код"><i class="bi bi-qr-code"></i></button>
      </div>
    </div>
    {% endif %}
    {% if u.links.classic %}
    <div class="col-12">
      <div class="d-flex align-items-center gap-1">
        <span class="badge bg-secondary fw-bold" style="min-width:58px;font-size:.7rem">Classic</span>
        <div class="link-box flex-grow-1 text-secondary">{{ u.links.classic[0] }}</div>
        <button class="btn btn-sm btn-outline-secondary px-2" onclick="copyText('{{ u.links.classic[0] }}')"
                title="Копировать"><i class="bi bi-clipboard"></i></button>
        <button class="btn btn-sm btn-outline-secondary px-2" onclick="showQR('{{ u.links.classic[0] }}')"
                title="QR-код"><i class="bi bi-qr-code"></i></button>
      </div>
    </div>
    {% endif %}
  </div>
</div>
{% else %}
<div class="text-center text-secondary py-5">
  <i class="bi bi-person-x display-4"></i>
  <p class="mt-2">Пользователей нет. Добавьте первого выше.</p>
</div>
{% endfor %}
</div>

<!-- Модальное окно редактирования лимитов -->
<div class="modal fade" id="limitsModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content" style="background:#161b22;border:1px solid #30363d">
      <div class="modal-header border-secondary">
        <h5 class="modal-title text-info">
          <i class="bi bi-sliders me-2"></i>Лимиты: <span id="lm-username-title"></span>
        </h5>
        <button class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body">
        <input type="hidden" id="lm-username">
        <div class="row g-3">
          <div class="col-sm-6">
            <label class="form-label small text-secondary">
              <i class="bi bi-link-45deg"></i> Макс. подключений
            </label>
            <input id="lm-maxconn" type="number" min="1" class="form-control form-control-sm"
                   placeholder="без лимита">
          </div>
          <div class="col-sm-6">
            <label class="form-label small text-secondary">
              <i class="bi bi-geo-alt"></i> Макс. уникальных IP
            </label>
            <input id="lm-maxips" type="number" min="1" class="form-control form-control-sm"
                   placeholder="без лимита">
          </div>
          <div class="col-sm-6">
            <label class="form-label small text-secondary">
              <i class="bi bi-database"></i> Квота трафика
            </label>
            <div class="input-group input-group-sm">
              <input id="lm-quota" type="number" min="0.1" step="0.1"
                     class="form-control" placeholder="без лимита">
              <select id="lm-quota-unit" class="form-select" style="max-width:70px">
                <option value="mb">МБ</option>
                <option value="gb" selected>ГБ</option>
                <option value="tb">ТБ</option>
              </select>
            </div>
          </div>
          <div class="col-sm-6">
            <label class="form-label small text-secondary">
              <i class="bi bi-calendar-x"></i> Срок действия (UTC)
            </label>
            <input id="lm-expire" type="datetime-local" class="form-control form-control-sm">
          </div>
        </div>
        <div class="mt-3 text-secondary small">
          <i class="bi bi-info-circle"></i>
          Оставьте поле пустым — лимит будет снят. Применится после перезапуска службы.
        </div>
      </div>
      <div class="modal-footer border-secondary">
        <button class="btn btn-secondary btn-sm" data-bs-dismiss="modal">Отмена</button>
        <button class="btn btn-info btn-sm" id="btn-limits-save" onclick="saveLimits()">
          <i class="bi bi-floppy-fill"></i> Сохранить
        </button>
      </div>
    </div>
  </div>
</div>

""" + _QR_MODAL + _SCRIPTS + """
</div></body></html>"""

# ──────────────────────────────────────────────────────────────────────────────
# СТРАНИЦА КОНФИГА
# ──────────────────────────────────────────────────────────────────────────────
CONFIG_HTML = _HEAD + """
<div class="container-fluid px-3">
""" + _NAVBAR + """
<div id="toast-wrap"></div>

<div class="card p-3">
  <div class="d-flex justify-content-between align-items-center mb-3 flex-wrap gap-2">
    <span class="text-secondary small">
      <i class="bi bi-file-earmark-code me-1"></i>{{ config_path }}
    </span>
    <div class="d-flex gap-2">
      <button class="btn btn-sm btn-outline-secondary" onclick="svcAction('restart')">
        <i class="bi bi-arrow-repeat"></i> Рестарт
      </button>
      <button class="btn btn-sm btn-success" onclick="saveConfig()">
        <i class="bi bi-floppy-fill"></i> Сохранить и перезапустить
      </button>
    </div>
  </div>
  <textarea id="cfg" class="form-control font-monospace text-success"
    style="background:#0d1117;border:1px solid #30363d;min-height:72vh;font-size:.82rem;resize:vertical"
    spellcheck="false">{{ content }}</textarea>
</div>

""" + _SCRIPTS + """
<script>
async function saveConfig(){
  const content=document.getElementById('cfg').value;
  toast('<i class="bi bi-arrow-repeat"></i> Сохраняем...','info');
  const r=await fetch('/api/config/save',{
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({content})
  });
  const d=await r.json();
  toast(d.ok?'<i class="bi bi-check2-circle"></i> Сохранено, служба перезапущена'
            :`<i class="bi bi-x-circle"></i> ${d.error}`,
        d.ok?'success':'danger');
  if(d.ok) updateSvcBadge('active');
}
</script>
</div></body></html>""".replace('{{ config_path }}', CONFIG_FILE)

# ──────────────────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    if DASH_PASSWORD == 'changeme':
        print('\n⚠  Пароль по умолчанию "changeme" — задайте DASHBOARD_PASSWORD!\n')
    print(f'🌐 Дашборд: http://{DASH_HOST}:{DASH_PORT}')
    app.run(host=DASH_HOST, port=DASH_PORT, debug=False)
