#!/usr/bin/env python3
"""
Telemt Web Dashboard — управление MTProto прокси через браузер

Установка:
    pip install flask requests

Запуск:
    DASHBOARD_PASSWORD=мойпароль python3 telemt-web.py

Переменные окружения:
    DASHBOARD_PASSWORD  — пароль для входа (обязательно поменяйте)
    DASHBOARD_PORT      — порт дашборда (по умолчанию 8080)
    DASHBOARD_HOST      — адрес (по умолчанию 0.0.0.0)
    TELEMT_API          — адрес API telemt (по умолчанию http://127.0.0.1:9091)
    CONFIG_FILE         — путь к конфигу (по умолчанию /etc/telemt/telemt.toml)
    SECRET_KEY          — ключ сессии (генерируется автоматически если не задан)
"""

import os, re, json, subprocess, secrets
from functools import wraps
from flask import (Flask, render_template_string, request,
                   redirect, url_for, session, jsonify)
import requests as req

# ──────────────────────────────────────────────────────────────────────────────
# НАСТРОЙКИ
# ──────────────────────────────────────────────────────────────────────────────
TELEMT_API     = os.environ.get('TELEMT_API',           'http://127.0.0.1:9091')
CONFIG_FILE    = os.environ.get('CONFIG_FILE',          '/etc/telemt/telemt.toml')
DASH_PASSWORD  = os.environ.get('DASHBOARD_PASSWORD',   'changeme')
DASH_PORT      = int(os.environ.get('DASHBOARD_PORT',   8080))
DASH_HOST      = os.environ.get('DASHBOARD_HOST',       '0.0.0.0')
SECRET_KEY     = os.environ.get('SECRET_KEY',           secrets.token_hex(32))

app = Flask(__name__)
app.secret_key = SECRET_KEY

# ──────────────────────────────────────────────────────────────────────────────
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ──────────────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated

def telemt_get(path):
    try:
        r = req.get(f'{TELEMT_API}{path}', timeout=5)
        return r.json()
    except Exception as e:
        return {'ok': False, 'error': str(e)}

def format_bytes(b):
    b = b or 0
    if b < 1024:       return f'{b} Б'
    elif b < 1024**2:  return f'{b/1024:.1f} КБ'
    elif b < 1024**3:  return f'{b/1024**2:.1f} МБ'
    else:              return f'{b/1024**3:.2f} ГБ'

def read_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            return f.read()
    except Exception as e:
        return None

def write_config(content):
    try:
        with open(CONFIG_FILE, 'w') as f:
            f.write(content)
        return True, ''
    except Exception as e:
        return False, str(e)

def gen_secret():
    return secrets.token_hex(16)

def is_hex32(s):
    return bool(re.match(r'^[0-9a-fA-F]{32}$', s))

def service_action(action):
    try:
        r = subprocess.run(['systemctl', action, 'telemt'],
                           capture_output=True, text=True, timeout=15)
        return r.returncode == 0, (r.stdout + r.stderr).strip()
    except Exception as e:
        return False, str(e)

def get_service_status():
    try:
        r = subprocess.run(['systemctl', 'is-active', 'telemt'],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except:
        return 'unknown'

def add_user_to_config(username, secret):
    content = read_config()
    if content is None:
        return False, 'Не удалось прочитать конфиг'
    if re.search(rf'^\s*{re.escape(username)}\s*=', content, re.MULTILINE):
        return False, f'Пользователь "{username}" уже существует'
    if '[access.users]' not in content:
        content += f'\n[access.users]\n{username} = "{secret}"\n'
    else:
        # Добавляем после последней строки секции [access.users]
        lines = content.split('\n')
        insert_idx = len(lines)
        in_access = False
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped == '[access.users]':
                in_access = True
            elif in_access and stripped.startswith('[') and stripped != '[access.users]':
                insert_idx = i
                break
        lines.insert(insert_idx, f'{username} = "{secret}"')
        content = '\n'.join(lines)
    ok, err = write_config(content)
    return ok, err

def remove_user_from_config(username):
    content = read_config()
    if content is None:
        return False, 'Не удалось прочитать конфиг'
    new_content = re.sub(
        rf'^\s*{re.escape(username)}\s*=.*\n?', '',
        content, flags=re.MULTILINE
    )
    if new_content == content:
        return False, f'Пользователь "{username}" не найден в конфиге'
    ok, err = write_config(new_content)
    return ok, err

def get_stats():
    data = telemt_get('/v1/users')
    users = data.get('data', []) if data.get('ok') else []
    for u in users:
        u['traffic_fmt'] = format_bytes(u.get('total_octets', 0))
    total_conn    = sum(u.get('current_connections', 0) for u in users)
    total_ips     = sum(u.get('active_unique_ips', 0) for u in users)
    total_traffic = sum(u.get('total_octets', 0) for u in users)
    return users, total_conn, total_ips, format_bytes(total_traffic)

# ──────────────────────────────────────────────────────────────────────────────
# МАРШРУТЫ
# ──────────────────────────────────────────────────────────────────────────────
@app.route('/login', methods=['GET', 'POST'])
def login():
    error = None
    if request.method == 'POST':
        if request.form.get('password') == DASH_PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('index'))
        error = 'Неверный пароль'
    return render_template_string(LOGIN_HTML, error=error)

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def index():
    users, total_conn, total_ips, total_traffic = get_stats()
    status = get_service_status()
    return render_template_string(
        DASHBOARD_HTML,
        users=users,
        total_conn=total_conn,
        total_ips=total_ips,
        total_traffic=total_traffic,
        status=status,
    )

@app.route('/config')
@login_required
def config_page():
    content = read_config() or '# Файл не найден'
    status = get_service_status()
    return render_template_string(CONFIG_HTML, content=content, status=status)

# ──────────────────────────────────────────────────────────────────────────────
# API ENDPOINTS
# ──────────────────────────────────────────────────────────────────────────────
@app.route('/api/stats')
@login_required
def api_stats():
    users, total_conn, total_ips, total_traffic = get_stats()
    return jsonify({
        'users': users,
        'total_conn': total_conn,
        'total_ips': total_ips,
        'total_traffic': total_traffic,
        'status': get_service_status(),
    })

@app.route('/api/user/add', methods=['POST'])
@login_required
def api_user_add():
    data = request.get_json() or {}
    username = data.get('username', '').strip()
    secret   = data.get('secret', '').strip()

    if not username:
        return jsonify({'ok': False, 'error': 'Укажите имя пользователя'})
    if not re.match(r'^[a-zA-Z0-9_-]{1,32}$', username):
        return jsonify({'ok': False, 'error': 'Имя: только латиница, цифры, _ и - (до 32 символов)'})

    if not secret:
        secret = gen_secret()
    if not is_hex32(secret):
        return jsonify({'ok': False, 'error': 'Секрет: ровно 32 hex-символа'})

    ok, err = add_user_to_config(username, secret)
    if not ok:
        return jsonify({'ok': False, 'error': err})

    ok2, _ = service_action('restart')
    return jsonify({'ok': True, 'secret': secret, 'restarted': ok2})

@app.route('/api/user/delete', methods=['POST'])
@login_required
def api_user_delete():
    data = request.get_json() or {}
    username = data.get('username', '').strip()
    if not username:
        return jsonify({'ok': False, 'error': 'Укажите имя пользователя'})

    ok, err = remove_user_from_config(username)
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
    return jsonify({'ok': ok, 'output': out, 'status': get_service_status()})

@app.route('/api/config/save', methods=['POST'])
@login_required
def api_config_save():
    data = request.get_json() or {}
    content = data.get('content', '')
    if not content.strip():
        return jsonify({'ok': False, 'error': 'Пустой конфиг'})
    ok, err = write_config(content)
    if not ok:
        return jsonify({'ok': False, 'error': err})
    ok2, _ = service_action('restart')
    return jsonify({'ok': True, 'restarted': ok2})

# ──────────────────────────────────────────────────────────────────────────────
# HTML ШАБЛОНЫ
# ──────────────────────────────────────────────────────────────────────────────
BASE_HEAD = """
<!DOCTYPE html>
<html lang="ru" data-bs-theme="dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Telemt Dashboard</title>
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.css">
  <style>
    body { background: #0d1117; }
    .navbar { background: #161b22 !important; border-bottom: 1px solid #30363d; }
    .card  { background: #161b22; border: 1px solid #30363d; }
    .stat-card .display-6 { font-weight: 700; }
    .badge-active   { background: #238636; }
    .badge-inactive { background: #6e7681; }
    .link-box { font-size: .78rem; word-break: break-all;
                background: #0d1117; border: 1px solid #30363d;
                border-radius: 6px; padding: 6px 10px; }
    .copy-btn { cursor: pointer; }
    #toast-container { position: fixed; bottom: 1.5rem; right: 1.5rem; z-index: 9999; }
    .qr-popup canvas { border: 8px solid #fff; border-radius: 8px; }
  </style>
</head>
<body>
"""

NAVBAR = """
<nav class="navbar navbar-expand-lg mb-4">
  <div class="container-fluid">
    <a class="navbar-brand fw-bold text-info" href="/">
      <i class="bi bi-shield-lock-fill me-2"></i>Telemt Dashboard
    </a>
    <div class="ms-auto d-flex align-items-center gap-3">
      <a href="/" class="btn btn-sm btn-outline-secondary {% if active=='dashboard' %}active{% endif %}">
        <i class="bi bi-speedometer2"></i> Дашборд
      </a>
      <a href="/config" class="btn btn-sm btn-outline-secondary {% if active=='config' %}active{% endif %}">
        <i class="bi bi-file-code"></i> Конфиг
      </a>
      <a href="/logout" class="btn btn-sm btn-outline-danger">
        <i class="bi bi-box-arrow-right"></i> Выйти
      </a>
    </div>
  </div>
</nav>
"""

TOAST = """
<div id="toast-container"></div>
<script>
function showToast(msg, type='success') {
  const t = document.createElement('div');
  t.className = `alert alert-${type} shadow py-2 px-3 mb-2`;
  t.style.minWidth = '250px';
  t.innerHTML = msg;
  document.getElementById('toast-container').appendChild(t);
  setTimeout(() => t.remove(), 3500);
}
function copyText(text) {
  navigator.clipboard.writeText(text).then(() => showToast('<i class="bi bi-check2"></i> Скопировано'));
}
</script>
"""

LOGIN_HTML = BASE_HEAD + """
<div class="container" style="max-width:400px;margin-top:15vh">
  <div class="card p-4 shadow">
    <h4 class="text-center mb-4 text-info">
      <i class="bi bi-shield-lock-fill me-2"></i>Telemt Dashboard
    </h4>
    {% if error %}
    <div class="alert alert-danger py-2">{{ error }}</div>
    {% endif %}
    <form method="post">
      <div class="mb-3">
        <label class="form-label text-secondary small">Пароль</label>
        <input type="password" name="password" class="form-control"
               autofocus autocomplete="current-password">
      </div>
      <button class="btn btn-info w-100 fw-bold">Войти</button>
    </form>
  </div>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
</body></html>
"""

DASHBOARD_HTML = BASE_HEAD + """
<div class="container-fluid px-4">
""" + NAVBAR + """

  <!-- Статистика -->
  <div class="row g-3 mb-4">
    <div class="col-6 col-md-3">
      <div class="card stat-card p-3 text-center">
        <div class="text-secondary small mb-1"><i class="bi bi-activity"></i> Статус</div>
        <div id="svc-badge" class="fw-bold fs-5">
          {% if status == 'active' %}
            <span class="badge badge-active px-3 py-2">Активен</span>
          {% else %}
            <span class="badge badge-inactive px-3 py-2">{{ status }}</span>
          {% endif %}
        </div>
      </div>
    </div>
    <div class="col-6 col-md-3">
      <div class="card stat-card p-3 text-center">
        <div class="text-secondary small mb-1"><i class="bi bi-people-fill"></i> Подключений</div>
        <div class="display-6 text-info" id="stat-conn">{{ total_conn }}</div>
      </div>
    </div>
    <div class="col-6 col-md-3">
      <div class="card stat-card p-3 text-center">
        <div class="text-secondary small mb-1"><i class="bi bi-globe"></i> Активных IP</div>
        <div class="display-6 text-warning" id="stat-ips">{{ total_ips }}</div>
      </div>
    </div>
    <div class="col-6 col-md-3">
      <div class="card stat-card p-3 text-center">
        <div class="text-secondary small mb-1"><i class="bi bi-arrow-left-right"></i> Трафик</div>
        <div class="display-6 text-success" id="stat-traffic">{{ total_traffic }}</div>
      </div>
    </div>
  </div>

  <!-- Управление службой -->
  <div class="card mb-4 p-3">
    <div class="d-flex align-items-center gap-2 flex-wrap">
      <span class="text-secondary me-2"><i class="bi bi-gear-fill"></i> Служба:</span>
      <button class="btn btn-sm btn-success" onclick="svcAction('start')">
        <i class="bi bi-play-fill"></i> Запустить
      </button>
      <button class="btn btn-sm btn-warning" onclick="svcAction('restart')">
        <i class="bi bi-arrow-repeat"></i> Перезапустить
      </button>
      <button class="btn btn-sm btn-danger" onclick="svcAction('stop')">
        <i class="bi bi-stop-fill"></i> Остановить
      </button>
    </div>
  </div>

  <!-- Добавить пользователя -->
  <div class="card mb-4 p-3">
    <h6 class="text-secondary mb-3"><i class="bi bi-person-plus-fill me-2"></i>Добавить пользователя</h6>
    <div class="row g-2 align-items-end">
      <div class="col-md-4">
        <label class="form-label small text-secondary">Имя пользователя</label>
        <input type="text" id="new-username" class="form-control form-control-sm"
               placeholder="username" pattern="[a-zA-Z0-9_-]+">
      </div>
      <div class="col-md-5">
        <label class="form-label small text-secondary">Секрет (оставьте пустым — сгенерируется)</label>
        <div class="input-group input-group-sm">
          <input type="text" id="new-secret" class="form-control form-control-sm font-monospace"
                 placeholder="32 hex символа или пусто">
          <button class="btn btn-outline-secondary" onclick="generateSecret()">
            <i class="bi bi-shuffle"></i>
          </button>
        </div>
      </div>
      <div class="col-md-3">
        <button class="btn btn-info btn-sm w-100" onclick="addUser()">
          <i class="bi bi-plus-lg"></i> Добавить
        </button>
      </div>
    </div>
  </div>

  <!-- Таблица пользователей -->
  <div id="users-container">
    {% for u in users %}
    <div class="card mb-3 p-3" id="user-{{ u.username }}">
      <div class="d-flex justify-content-between align-items-start flex-wrap gap-2 mb-3">
        <div>
          <span class="fw-bold text-info fs-5">{{ u.username }}</span>
          {% if u.current_connections > 0 %}
          <span class="badge bg-success ms-2">{{ u.current_connections }} подкл.</span>
          {% endif %}
        </div>
        <div class="d-flex gap-2 align-items-center">
          <span class="text-secondary small">{{ u.traffic_fmt }}</span>
          <span class="badge bg-secondary">{{ u.active_unique_ips }} IP</span>
          <button class="btn btn-sm btn-outline-danger" onclick="deleteUser('{{ u.username }}')">
            <i class="bi bi-trash"></i>
          </button>
        </div>
      </div>

      {% if u.active_unique_ips_list %}
      <div class="mb-2">
        <small class="text-secondary">Активные IP: </small>
        {% for ip in u.active_unique_ips_list %}
        <span class="badge bg-secondary me-1 font-monospace">{{ ip }}</span>
        {% endfor %}
      </div>
      {% endif %}

      <!-- Ссылки -->
      <div class="row g-2">
        {% if u.links.tls %}
        <div class="col-12">
          <div class="d-flex align-items-center gap-2">
            <span class="badge bg-info text-dark" style="min-width:60px">TLS</span>
            <div class="link-box flex-grow-1 font-monospace text-info">{{ u.links.tls[0] }}</div>
            <button class="btn btn-sm btn-outline-info copy-btn" onclick="copyText('{{ u.links.tls[0] }}')">
              <i class="bi bi-clipboard"></i>
            </button>
            <button class="btn btn-sm btn-outline-secondary" onclick="showQR('{{ u.links.tls[0] }}')">
              <i class="bi bi-qr-code"></i>
            </button>
          </div>
        </div>
        {% endif %}
        {% if u.links.secure %}
        <div class="col-12">
          <div class="d-flex align-items-center gap-2">
            <span class="badge bg-warning text-dark" style="min-width:60px">Secure</span>
            <div class="link-box flex-grow-1 font-monospace text-warning">{{ u.links.secure[0] }}</div>
            <button class="btn btn-sm btn-outline-warning copy-btn" onclick="copyText('{{ u.links.secure[0] }}')">
              <i class="bi bi-clipboard"></i>
            </button>
            <button class="btn btn-sm btn-outline-secondary" onclick="showQR('{{ u.links.secure[0] }}')">
              <i class="bi bi-qr-code"></i>
            </button>
          </div>
        </div>
        {% endif %}
        {% if u.links.classic %}
        <div class="col-12">
          <div class="d-flex align-items-center gap-2">
            <span class="badge bg-secondary" style="min-width:60px">Classic</span>
            <div class="link-box flex-grow-1 font-monospace text-secondary">{{ u.links.classic[0] }}</div>
            <button class="btn btn-sm btn-outline-secondary copy-btn" onclick="copyText('{{ u.links.classic[0] }}')">
              <i class="bi bi-clipboard"></i>
            </button>
            <button class="btn btn-sm btn-outline-secondary" onclick="showQR('{{ u.links.classic[0] }}')">
              <i class="bi bi-qr-code"></i>
            </button>
          </div>
        </div>
        {% endif %}
      </div>
    </div>
    {% endfor %}
  </div>

</div>

<!-- QR Modal -->
<div class="modal fade" id="qrModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content" style="background:#161b22;border:1px solid #30363d">
      <div class="modal-header border-secondary">
        <h5 class="modal-title text-info"><i class="bi bi-qr-code me-2"></i>QR-код</h5>
        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body text-center qr-popup">
        <div id="qr-container" class="d-inline-block"></div>
        <p class="text-secondary small mt-3" id="qr-link" style="word-break:break-all"></p>
      </div>
    </div>
  </div>
</div>

""" + TOAST + """
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"></script>
<script>
// ── Авто-обновление статистики ──────────────────────────────────────────────
setInterval(async () => {
  const r = await fetch('/api/stats');
  const d = await r.json();
  document.getElementById('stat-conn').textContent    = d.total_conn;
  document.getElementById('stat-ips').textContent     = d.total_ips;
  document.getElementById('stat-traffic').textContent = d.total_traffic;
}, 10000);

// ── Управление службой ───────────────────────────────────────────────────────
async function svcAction(action) {
  const labels = {start:'Запуск...', restart:'Перезапуск...', stop:'Остановка...'};
  showToast(`<i class="bi bi-arrow-repeat"></i> ${labels[action]}`, 'info');
  const r = await fetch(`/api/service/${action}`, {method:'POST'});
  const d = await r.json();
  const badge = document.getElementById('svc-badge');
  if (d.status === 'active') {
    badge.innerHTML = '<span class="badge badge-active px-3 py-2">Активен</span>';
    showToast('<i class="bi bi-check2-circle"></i> Готово', 'success');
  } else {
    badge.innerHTML = `<span class="badge badge-inactive px-3 py-2">${d.status}</span>`;
    showToast(`<i class="bi bi-exclamation-triangle"></i> ${d.status}`, 'warning');
  }
}

// ── Генерация секрета ────────────────────────────────────────────────────────
function generateSecret() {
  const arr = new Uint8Array(16);
  crypto.getRandomValues(arr);
  document.getElementById('new-secret').value =
    Array.from(arr).map(b => b.toString(16).padStart(2,'0')).join('');
}

// ── Добавить пользователя ────────────────────────────────────────────────────
async function addUser() {
  const username = document.getElementById('new-username').value.trim();
  const secret   = document.getElementById('new-secret').value.trim();
  if (!username) { showToast('Введите имя пользователя', 'warning'); return; }

  const r = await fetch('/api/user/add', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({username, secret})
  });
  const d = await r.json();
  if (d.ok) {
    showToast(`<i class="bi bi-check2"></i> Пользователь <b>${username}</b> добавлен. Секрет: <code>${d.secret}</code>`, 'success');
    document.getElementById('new-username').value = '';
    document.getElementById('new-secret').value   = '';
    setTimeout(() => location.reload(), 2500);
  } else {
    showToast(`<i class="bi bi-x-circle"></i> ${d.error}`, 'danger');
  }
}

// ── Удалить пользователя ─────────────────────────────────────────────────────
async function deleteUser(username) {
  if (!confirm(`Удалить пользователя "${username}"?`)) return;
  const r = await fetch('/api/user/delete', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({username})
  });
  const d = await r.json();
  if (d.ok) {
    document.getElementById(`user-${username}`)?.remove();
    showToast(`<i class="bi bi-check2"></i> Пользователь <b>${username}</b> удалён`, 'success');
  } else {
    showToast(`<i class="bi bi-x-circle"></i> ${d.error}`, 'danger');
  }
}

// ── QR-код ───────────────────────────────────────────────────────────────────
let qrInstance = null;
function showQR(link) {
  const container = document.getElementById('qr-container');
  container.innerHTML = '';
  document.getElementById('qr-link').textContent = link;
  qrInstance = new QRCode(container, {
    text: link, width: 256, height: 256,
    colorDark: '#000000', colorLight: '#ffffff',
    correctLevel: QRCode.CorrectLevel.M
  });
  new bootstrap.Modal(document.getElementById('qrModal')).show();
}
</script>
</body></html>
"""

CONFIG_HTML = BASE_HEAD + """
<div class="container-fluid px-4">
""" + NAVBAR.replace("active=='dashboard'", "active=='config'") + """

  <div class="card p-3">
    <div class="d-flex justify-content-between align-items-center mb-3">
      <h6 class="mb-0 text-secondary">
        <i class="bi bi-file-code me-2"></i>/etc/telemt/telemt.toml
      </h6>
      <button class="btn btn-sm btn-success" onclick="saveConfig()">
        <i class="bi bi-floppy-fill"></i> Сохранить и перезапустить
      </button>
    </div>
    <textarea id="config-editor" class="form-control font-monospace text-success"
              style="background:#0d1117;border:1px solid #30363d;min-height:70vh;font-size:.82rem"
              spellcheck="false">{{ content }}</textarea>
  </div>

</div>
""" + TOAST + """
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script>
async function saveConfig() {
  const content = document.getElementById('config-editor').value;
  showToast('<i class="bi bi-arrow-repeat"></i> Сохраняем...', 'info');
  const r = await fetch('/api/config/save', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({content})
  });
  const d = await r.json();
  if (d.ok) {
    showToast('<i class="bi bi-check2-circle"></i> Сохранено, служба перезапущена', 'success');
  } else {
    showToast(`<i class="bi bi-x-circle"></i> ${d.error}`, 'danger');
  }
}
</script>
</body></html>
"""

# ──────────────────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    if DASH_PASSWORD == 'changeme':
        print('\n⚠  ВНИМАНИЕ: используется пароль по умолчанию "changeme"!')
        print('   Установите переменную DASHBOARD_PASSWORD перед запуском.\n')
    print(f'🌐 Дашборд: http://{DASH_HOST}:{DASH_PORT}')
    app.run(host=DASH_HOST, port=DASH_PORT, debug=False)
