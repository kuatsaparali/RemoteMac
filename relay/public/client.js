'use strict';

const byId = id => document.getElementById(id);
const shell = byId('shell');
const form = byId('form');
const field = byId('link-field');
const invite = byId('invite');
const heading = byId('heading');
const description = byId('description');
const notice = byId('notice');
const connect = byId('connect');
const canvas = byId('screen');
const viewport = byId('viewport');
const keyboard = byId('keyboard');
const fullscreen = byId('fullscreen');
const resolution = byId('resolution');
const context = canvas.getContext('2d', { alpha: false });

const invitationPattern = /^#([A-Za-z0-9_-]{22})\.([A-Za-z0-9_-]{43})$/;
let initialLink = invitationPattern.exec(location.hash);
let current;
let pointerMove;
let moveScheduled = false;
const keys = new Set();
const buttons = new Set();
if (initialLink) {
  field.hidden = true;
  invite.required = false;
  description.textContent = 'Запрос нужно подтвердить на Mac, к которому вы подключаетесь.';
}
fullscreen.hidden = !document.fullscreenEnabled;

function reset(session, message) {
  if (current !== session) return;
  current = undefined;
  clearTimeout(session?.timer);
  session?.socket?.close();
  keys.clear();
  buttons.clear();
  pointerMove = undefined;
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  context.clearRect(0, 0, canvas.width, canvas.height);
  byId('tools').hidden = true;
  byId('workspace').hidden = true;
  byId('landing').hidden = false;
  shell.classList.remove('is-active');
  field.hidden = false;
  invite.required = true;
  heading.textContent = 'Подключение к Mac';
  description.textContent = 'Вставьте новую ссылку из MacRemote.';
  connect.disabled = false;
  connect.textContent = 'Подключиться';
  showNotice(message);
  invite.focus();
}

function showNotice(message) {
  notice.textContent = message ?? '';
  notice.hidden = !message;
}

function wait(session, message, milliseconds, failure) {
  clearTimeout(session.timer);
  description.textContent = message;
  session.timer = setTimeout(() => reset(session, failure), milliseconds);
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

async function start(match) {
  const session = { commands: Promise.resolve(), queued: 0, sent: 0n, received: 0n };
  current = session;
  invite.value = '';
  initialLink = undefined;
  history.replaceState(null, '', location.pathname);
  field.hidden = true;
  invite.required = false;
  showNotice();
  connect.disabled = true;
  connect.textContent = 'Подключаемся…';
  wait(session, 'Соединяемся с сервером.', 12_000, 'Сервер не ответил. Проверьте интернет и запросите новую ссылку.');
  try {
    const secret = Uint8Array.from(atob(match[2].replaceAll('-', '+').replaceAll('_', '/') + '='), char => char.charCodeAt(0));
    session.key = await crypto.subtle.importKey('raw', secret, 'AES-GCM', false, ['encrypt', 'decrypt']);
    const ticket = base64url(await crypto.subtle.digest('SHA-256', secret));
    secret.fill(0);
    if (current !== session) return;

    const socket = new WebSocket(new URL('/ws', location.origin.replace(/^http/, 'ws')));
    socket.binaryType = 'arraybuffer';
    session.socket = socket;
    socket.addEventListener('open', () => socket.send(JSON.stringify({ type: 'join', room: match[1], ticket })));
    socket.addEventListener('message', event => {
      if (current !== session) return;
      if (typeof event.data !== 'string') {
        if (session.approved) postFrame(session, event.data);
        return;
      }
      const message = JSON.parse(event.data);
      switch (message.type) {
        case 'waiting':
          heading.textContent = 'Ждём подтверждения';
          connect.textContent = 'Запрос отправлен';
          wait(session, 'На удалённом Mac нужно нажать «Разрешить доступ».', 65_000, 'Время ожидания истекло.');
          showNotice();
          break;
        case 'active':
          session.approved = true;
          heading.textContent = 'Получаем экран';
          wait(session, 'Подключение одобрено. Загружаем первый кадр.', 15_000, 'Экран не поступил. Проверьте разрешения на удалённом Mac.');
          break;
        case 'denied':
          reset(session, 'Ссылка недействительна или уже используется.');
          break;
        case 'rejected':
          reset(session, 'Запрос отклонён на удалённом Mac.');
          break;
        case 'expired':
          reset(session, 'Время на подтверждение истекло.');
          break;
        case 'ended':
          reset(session, 'Сеанс завершён.');
          break;
      }
    });
    socket.addEventListener('close', () => reset(session, 'Соединение прервалось.'));
    socket.addEventListener('error', () => reset(session, 'Не удалось подключиться к серверу.'));
  } catch {
    reset(session, 'Не удалось открыть сеанс. Используйте HTTPS или локальный адрес localhost.');
  }
}

form.addEventListener('submit', event => {
  event.preventDefault();
  if (current) return;
  if (initialLink) {
    start(initialLink);
    return;
  }
  try {
    const address = new URL(invite.value.trim());
    const match = invitationPattern.exec(address.hash);
    if (!match) throw new Error();
    if (address.origin !== location.origin) {
      showNotice('Откройте эту ссылку напрямую в адресной строке браузера.');
      return;
    }
    start(match);
  } catch {
    showNotice('Вставьте ссылку целиком, включая часть после знака #.');
  }
});

async function postFrame(session, packet) {
  session.pendingFrame = packet;
  if (session.rendering) return;
  session.rendering = true;
  try {
    while (session.pendingFrame && current === session) {
      const next = session.pendingFrame;
      session.pendingFrame = undefined;
      if (next.byteLength < 29) continue;
      const nonce = new DataView(next, 0, 12);
      const sequence = nonce.getBigUint64(4);
      if (nonce.getUint32(0) !== 1 || sequence <= session.received) continue;
      const jpeg = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, session.key, next.slice(12));
      session.received = sequence;
      const bitmap = await createImageBitmap(new Blob([jpeg], { type: 'image/jpeg' }));
      try {
        if (current !== session) return;
        const dimensionsChanged = canvas.width !== bitmap.width || canvas.height !== bitmap.height;
        if (dimensionsChanged) {
          canvas.width = bitmap.width;
          canvas.height = bitmap.height;
        }
        if (!session.visible) {
          clearTimeout(session.timer);
          session.visible = true;
          shell.classList.add('is-active');
          byId('landing').hidden = true;
          byId('tools').hidden = false;
          byId('workspace').hidden = false;
          byId('disconnect').focus();
        }
        if (dimensionsChanged || !resolution.textContent) {
          resolution.textContent = bitmap.width + ' × ' + bitmap.height;
        }
        context.drawImage(bitmap, 0, 0);
        fit();
      } finally {
        bitmap.close();
      }
    }
  } catch {
    reset(session, 'Не удалось прочитать защищённый кадр. Запросите новую ссылку.');
  } finally {
    session.rendering = false;
  }
}

function fit() {
  if (!current?.visible) return;
  const padding = getComputedStyle(viewport);
  const w = viewport.clientWidth - parseFloat(padding.paddingLeft) - parseFloat(padding.paddingRight);
  const h = viewport.clientHeight - parseFloat(padding.paddingTop) - parseFloat(padding.paddingBottom);
  const scale = Math.min(w / canvas.width, h / canvas.height);
  const width = Math.max(1, Math.floor(canvas.width * scale));
  const height = Math.max(1, Math.floor(canvas.height * scale));
  if (canvas.style.width !== width + 'px') canvas.style.width = width + 'px';
  if (canvas.style.height !== height + 'px') canvas.style.height = height + 'px';
}

new ResizeObserver(fit).observe(viewport);
byId('disconnect').addEventListener('click', () => reset(current, 'Вы отключились.'));
fullscreen.addEventListener('click', async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await shell.requestFullscreen();
  } catch {
    fullscreen.hidden = true;
  }
});
document.addEventListener('fullscreenchange', () => {
  const expanded = Boolean(document.fullscreenElement);
  fullscreen.textContent = expanded ? 'Выйти из полного экрана' : 'На весь экран';
  fullscreen.setAttribute('aria-pressed', String(expanded));
});

function send(command) {
  const session = current;
  if (!session?.visible || session.socket.readyState !== WebSocket.OPEN) return;
  if (command.type === 'move' && session.queued > 3) return;
  if (session.queued > 100 || session.socket.bufferedAmount > 64 * 1024) {
    reset(session, 'Соединение слишком медленное. Запросите новую ссылку.');
    return;
  }
  session.queued++;
  session.commands = session.commands.then(async () => {
    if (current !== session || session.socket.readyState !== WebSocket.OPEN) return;
    const nonce = new DataView(new ArrayBuffer(12));
    nonce.setUint32(0, 2);
    nonce.setBigUint64(4, ++session.sent);
    const data = new TextEncoder().encode(JSON.stringify(command));
    const encrypted = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, session.key, data);
    if (current !== session || session.socket.readyState !== WebSocket.OPEN) return;
    const packet = new Uint8Array(12 + encrypted.byteLength);
    packet.set(new Uint8Array(nonce.buffer));
    packet.set(new Uint8Array(encrypted), 12);
    session.socket.send(packet);
  }).catch(() => reset(session, 'Не удалось передать команды.')).finally(() => { session.queued--; });
}

const modifiers = event => Number(event.shiftKey) | (Number(event.ctrlKey) << 1)
  | (Number(event.altKey) << 2) | (Number(event.metaKey) << 3);
const clamp = value => Math.max(0, Math.min(1, value));

function pointer(type, event) {
  const rect = canvas.getBoundingClientRect();
  return {
    type,
    x: clamp((event.clientX - rect.left) / rect.width),
    y: clamp((event.clientY - rect.top) / rect.height),
    button: event.button,
    modifiers: modifiers(event),
  };
}

function clearInput() {
  pointerMove = undefined;
  if (keys.size || buttons.size) send({ type: 'release' });
  keys.clear();
  buttons.clear();
}

canvas.addEventListener('pointermove', event => {
  if (!event.isPrimary) return;
  pointerMove = pointer('move', event);
  if (moveScheduled) return;
  moveScheduled = true;
  requestAnimationFrame(() => {
    if (pointerMove) send(pointerMove);
    pointerMove = undefined;
    moveScheduled = false;
  });
});
canvas.addEventListener('pointerdown', event => {
  if (!event.isPrimary || event.button < 0 || event.button > 2) return;
  event.preventDefault();
  canvas.focus({ preventScroll: true });
  canvas.setPointerCapture(event.pointerId);
  pointerMove = undefined;
  buttons.add(event.button);
  send(pointer('down', event));
});
canvas.addEventListener('pointerup', event => {
  if (!event.isPrimary || !buttons.delete(event.button)) return;
  pointerMove = undefined;
  send(pointer('up', event));
});
canvas.addEventListener('lostpointercapture', () => { if (buttons.size) clearInput(); });
canvas.addEventListener('pointercancel', clearInput);
canvas.addEventListener('contextmenu', event => event.preventDefault());
canvas.addEventListener('wheel', event => {
  event.preventDefault();
  const factor = [1, 16, 120][event.deltaMode] ?? 1;
  const { x, y } = pointer('move', event);
  send({ type: 'move', x, y, modifiers: modifiers(event) });
  send({ type: 'scroll', dx: event.deltaX * factor, dy: event.deltaY * factor, modifiers: modifiers(event) });
}, { passive: false });

keyboard.addEventListener('click', () => canvas.focus({ preventScroll: true }));
canvas.addEventListener('focus', () => keyboard.setAttribute('aria-pressed', 'true'));
canvas.addEventListener('blur', () => {
  keyboard.setAttribute('aria-pressed', 'false');
  clearInput();
});
window.addEventListener('blur', clearInput);
window.addEventListener('pagehide', () => current?.socket?.close());
document.addEventListener('visibilitychange', () => { if (document.hidden) clearInput(); });

canvas.addEventListener('keydown', event => {
  event.preventDefault();
  if (event.code === 'Escape' && event.shiftKey) {
    keyboard.focus();
    return;
  }
  if (!event.code) return;
  keys.add(event.code);
  send({ type: 'keyDown', code: event.code, modifiers: modifiers(event) });
});
canvas.addEventListener('keyup', event => {
  event.preventDefault();
  if (keys.delete(event.code)) send({ type: 'keyUp', code: event.code, modifiers: modifiers(event) });
});
