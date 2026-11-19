'use strict';

const translations = {
  'Язык': 'Language',
  'Клавиатура': 'Keyboard',
  'На весь экран': 'Full screen',
  'Выйти из полного экрана': 'Exit full screen',
  'Отключиться': 'Disconnect',
  'Чат': 'Chat',
  'Чат сеанса': 'Session chat',
  'Свернуть': 'Hide',
  'Здесь появятся сообщения.': 'Messages will appear here.',
  'Сообщение': 'Message',
  'Сообщение…': 'Message…',
  'Отправить': 'Send',
  'Вы': 'You',
  'Ведущий': 'Host',
  'Звук вкл': 'Sound on',
  'Звук выкл': 'Sound off',
  'Подключение к Mac': 'Connect to a Mac',
  'Откройте приглашение из MacRemote или вставьте ссылку ниже.': 'Open an invitation from MacRemote or paste the link below.',
  'Ссылка-приглашение': 'Invitation link',
  'Подключиться': 'Connect',
  'Удалённый экран Mac': 'Remote Mac display',
  'Сеанс открыт': 'Session active',
  'Щёлкните по экрану для управления. Shift + Esc освобождает клавиатуру.': 'Click the screen to take control. Press Shift + Esc to release the keyboard.',
  'Касание — щелчок. Для ввода нужна физическая клавиатура.': 'Tap to click. Typing requires a physical keyboard.',
  'Запрос нужно подтвердить на Mac, к которому вы подключаетесь.': 'Someone must approve the request on the Mac you’re connecting to.',
  'Вставьте новую ссылку из MacRemote.': 'Paste a new invitation from MacRemote.',
  'Подключаемся…': 'Connecting…',
  'Соединяемся с сервером.': 'Connecting to the server.',
  'Сервер не ответил. Проверьте интернет и запросите новую ссылку.': 'The server did not respond. Check your connection and ask for a new link.',
  'Ждём подтверждения': 'Waiting for approval',
  'Запрос отправлен': 'Request sent',
  'На удалённом Mac нужно нажать «Разрешить доступ».': 'Click “Allow access” on the remote Mac.',
  'Время ожидания истекло.': 'The request timed out.',
  'Получаем экран': 'Receiving the screen',
  'Подключение одобрено. Загружаем первый кадр.': 'Connection approved. Waiting for the first frame.',
  'Экран не поступил. Проверьте разрешения на удалённом Mac.': 'No screen image received. Check the permissions on the remote Mac.',
  'Ссылка недействительна или уже используется.': 'This link is invalid or already in use.',
  'Запрос отклонён на удалённом Mac.': 'The request was declined on the remote Mac.',
  'Время на подтверждение истекло.': 'The approval request expired.',
  'Сеанс завершён.': 'The session has ended.',
  'Соединение прервалось.': 'The connection was interrupted.',
  'Не удалось подключиться к серверу.': 'Could not connect to the server.',
  'Не удалось открыть сеанс. Используйте HTTPS или локальный адрес localhost.': 'Could not open the session. Use HTTPS or the local address localhost.',
  'Откройте эту ссылку напрямую в адресной строке браузера.': 'Open this link directly in the browser’s address bar.',
  'Вставьте ссылку целиком, включая часть после знака #.': 'Paste the entire link, including the part after #.',
  'Не удалось прочитать защищённый кадр. Запросите новую ссылку.': 'Could not read the encrypted frame. Ask for a new link.',
  'Вы отключились.': 'You disconnected.',
  'Соединение слишком медленное. Запросите новую ссылку.': 'The connection is too slow. Ask for a new link.',
  'Не удалось передать команды.': 'Could not send your input.',
};

const languagePicker = document.getElementById('language');
const textKeys = new Map();
let viewerLanguage = 'ru';
try {
  if (localStorage.getItem('macremote-language') === 'en') viewerLanguage = 'en';
} catch {}

function translate(message) {
  return viewerLanguage === 'en' ? translations[message] ?? message : message;
}

function setText(element, message) {
  textKeys.set(element, message);
  element.textContent = translate(message);
}

function updateLanguage() {
  document.documentElement.lang = viewerLanguage;
  for (const [element, message] of textKeys) element.textContent = translate(message);
  for (const element of document.querySelectorAll('[data-i18n-label]')) {
    element.setAttribute('aria-label', translate(element.dataset.i18nLabel));
  }
  for (const element of document.querySelectorAll('[data-i18n-placeholder]')) {
    element.placeholder = translate(element.dataset.i18nPlaceholder);
  }
}

for (const element of document.querySelectorAll('[data-i18n]')) {
  textKeys.set(element, element.textContent);
}
languagePicker.value = viewerLanguage;
languagePicker.addEventListener('change', () => {
  viewerLanguage = languagePicker.value;
  try { localStorage.setItem('macremote-language', viewerLanguage); } catch {}
  updateLanguage();
});
updateLanguage();
