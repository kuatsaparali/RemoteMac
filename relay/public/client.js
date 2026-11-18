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
const context = canvas.getContext('2d', { alpha: false, desynchronized: true });

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
  clearTimeout(session?.videoTimer);
  if (session?.decoder && session.decoder.state !== 'closed') session.decoder.close();
  resolution.textContent = '';
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
  const session = { commands: Promise.resolve(), queued: 0, sent: 0n, received: 0n, packets: [] };
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
    socket.addEventListener('open', () => socket.send(JSON.stringify({ type: 'join', room: match[1], ticket, paced: true })));
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
          negotiateVideo(session);
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

async function negotiateVideo(session) {
  let video = false;
  if (typeof VideoDecoder !== 'undefined' && typeof EncodedVideoChunk !== 'undefined') {
    try {
      video = (await VideoDecoder.isConfigSupported({ codec: 'avc1.42e01f', optimizeForLatency: true })).supported;
    } catch {}
  }
  if (current !== session) return;
  send({ type: 'stream', codec: video ? 'h264' : 'jpeg' });
}

function fallbackToImages(session) {
  if (current !== session || session.videoDisabled) return;
  session.videoDisabled = true;
  clearTimeout(session.videoTimer);
  if (session.decoder && session.decoder.state !== 'closed') session.decoder.close();
  session.decoder = undefined;
  session.videoFrames?.clear();
  send({ type: 'stream', codec: 'jpeg' });
}

function drawFrame(session, source, width, height) {
  if (current !== session) return;
  const resized = canvas.width !== width || canvas.height !== height;
  if (resized) {
    canvas.width = width;
    canvas.height = height;
  }
  const first = !session.visible;
  if (first) {
    clearTimeout(session.timer);
    session.visible = true;
    shell.classList.add('is-active');
    byId('landing').hidden = true;
    byId('tools').hidden = false;
    byId('workspace').hidden = false;
    byId('disconnect').focus();
  }
  if (resized || !resolution.textContent) resolution.textContent = width + ' × ' + height;
  context.drawImage(source, 0, 0, width, height);
  // Layout is measured on resize, rather than on every decoded video frame.
  if (first || resized) fit();
}

function decodeVideo(session, bytes, sequence, skipped) {
  if (session.videoDisabled) return;
  const header = new DataView(bytes);
  const keyframe = header.getUint8(4) === 1;
  if (skipped && !keyframe) { fallbackToImages(session); return; }
  const codec = 'avc1.' + [...new Uint8Array(bytes, 5, 3)].map(value => value.toString(16).padStart(2, '0')).join('');
  const width = header.getUint16(8);
  const height = header.getUint16(10);
  const timestamp = Number(header.getBigUint64(12));
  if (!width || !height || !Number.isSafeInteger(timestamp)) { fallbackToImages(session); return; }
  if (!session.decoder || session.videoCodec !== codec) {
    if (!keyframe) { fallbackToImages(session); return; }
    if (session.decoder && session.decoder.state !== 'closed') session.decoder.close();
    session.videoFrames = new Map();
    session.videoCodec = codec;
    session.decoder = new VideoDecoder({
      output(frame) {
        try {
          if (current !== session || session.videoDisabled) return;
          const acknowledged = session.videoFrames.get(frame.timestamp);
          for (const timestamp of session.videoFrames.keys()) {
            if (timestamp <= frame.timestamp) session.videoFrames.delete(timestamp);
          }
          clearTimeout(session.videoTimer);
          drawFrame(session, frame, frame.displayWidth, frame.displayHeight);
          if (acknowledged !== undefined) send({ type: 'frameAck', frame: Number(acknowledged) });
        } finally {
          frame.close();
        }
      },
      error() { fallbackToImages(session); },
    });
    // Avoid hardware decoder buffering when desktop updates are sparse.
    session.decoder.configure({ codec, codedWidth: width, codedHeight: height, optimizeForLatency: true, hardwareAcceleration: 'prefer-software' });
  }
  if (session.decoder.decodeQueueSize >= 4) { fallbackToImages(session); return; }
  session.videoFrames.set(timestamp, sequence);
  clearTimeout(session.videoTimer);
  session.videoTimer = setTimeout(() => fallbackToImages(session), 1000);
  session.decoder.decode(new EncodedVideoChunk({ type: keyframe ? 'key' : 'delta', timestamp, data: bytes.slice(20) }));
}

async function postFrame(session, packet) {
  // New hosts send at most four unacknowledged frames. Bound legacy JPEG senders too.
  if (session.packets.length >= 4) session.packets.shift();
  session.packets.push(packet);
  if (session.rendering) return;
  session.rendering = true;
  try {
    while (session.packets.length && current === session) {
      const next = session.packets.shift();
      if (next.byteLength < 29) continue;
      const nonce = new DataView(next, 0, 12);
      const sequence = nonce.getBigUint64(4);
      if (nonce.getUint32(0) !== 1 || sequence <= session.received) continue;
      const bytes = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, session.key, next.slice(12));
      const skipped = sequence !== session.received + 1n;
      session.received = sequence;
      if (bytes.byteLength > 20 && new DataView(bytes).getUint32(0) === 0x4d525601) {
        try { decodeVideo(session, bytes, sequence, skipped); }
        catch { fallbackToImages(session); }
        continue;
      }
      const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/jpeg' }));
      try {
        if (current !== session) return;
        drawFrame(session, bitmap, bitmap.width, bitmap.height);
        send({ type: 'frameAck', frame: Number(sequence) });
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
  if (!session?.approved || session.socket.readyState !== WebSocket.OPEN) return;
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
