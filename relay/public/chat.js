'use strict';

class ViewerChat {
  constructor(send) {
    this.send = send;
    this.workspace = document.getElementById('workspace');
    this.viewport = document.getElementById('viewport');
    this.panel = document.getElementById('chat-panel');
    this.toggle = document.getElementById('chat-toggle');
    this.count = document.getElementById('chat-count');
    this.close = document.getElementById('chat-close');
    this.feed = document.getElementById('chat-feed');
    this.log = document.getElementById('chat-log');
    this.empty = document.getElementById('chat-empty');
    this.input = document.getElementById('chat-input');
    this.submit = document.getElementById('chat-send');
    this.toggle.addEventListener('click', () => this.setOpen(this.panel.hidden));
    this.close.addEventListener('click', () => this.setOpen(false));
    this.panel.addEventListener('pointerdown', () => this.scheduleCollapse());
    this.feed.addEventListener('scroll', () => this.scheduleCollapse(), { passive: true });
    this.panel.addEventListener('keydown', event => {
      if (event.key === 'Escape' && !event.isComposing) this.setOpen(false);
      else this.scheduleCollapse();
    });
    document.getElementById('chat-form').addEventListener('submit', event => {
      event.preventDefault();
      this.post();
    });
    this.input.addEventListener('input', () => this.updateComposer());
    for (const event of ['focus', 'blur']) {
      this.input.addEventListener(event, () => {
        this.updateKeyboardInset();
        this.scheduleCollapse();
      });
    }
    for (const event of ['resize', 'scroll']) {
      window.visualViewport?.addEventListener(event, () => this.updateKeyboardInset());
    }
    this.input.addEventListener('keydown', event => {
      if (event.key !== 'Enter' || event.shiftKey || event.isComposing || event.keyCode === 229) return;
      event.preventDefault();
      this.post();
    });
    languagePicker.addEventListener('change', () => {
      for (const author of this.log.querySelectorAll('[data-author]')) {
        author.textContent = translate(author.dataset.author);
      }
    });
    this.reset();
  }

  connect(session) {
    this.session = session;
    this.send({ type: 'chatReady' });
  }

  reset() {
    this.session = null;
    this.enabled = false;
    this.generation = -1;
    this.received = 0n;
    this.queue = Promise.resolve();
    this.pending = 0;
    this.setOpen(false, false);
    this.toggle.hidden = true;
    this.setUnread(0);
    this.log.replaceChildren();
    this.empty.hidden = false;
    this.input.value = '';
    this.updateComposer();
  }

  setOpen(open, moveFocus = true) {
    open = open && this.enabled;
    this.panel.hidden = !open;
    this.workspace.classList.toggle('chat-open', open);
    this.toggle.setAttribute('aria-expanded', String(open));
    if (open) {
      this.setUnread(0);
      this.feed.scrollTop = this.feed.scrollHeight;
      if (moveFocus) this.close.focus();
    } else if (moveFocus) {
      this.toggle.focus();
    }
    this.updateKeyboardInset();
    this.scheduleCollapse();
  }

  scheduleCollapse() {
    clearTimeout(this.collapseTimer);
    if (!this.session || this.panel.hidden || document.activeElement === this.input) return;
    this.collapseTimer = setTimeout(() => {
      this.setOpen(false, this.panel.contains(document.activeElement));
    }, 10_000);
  }

  updateKeyboardInset() {
    const visible = window.visualViewport;
    const composing = this.session?.mobile && !this.panel.hidden && document.activeElement === this.input;
    const inset = composing && visible?.scale === 1
      ? Math.max(0, this.viewport.getBoundingClientRect().bottom - visible.offsetTop - visible.height)
      : 0;
    this.panel.style.setProperty('--keyboard-inset', Math.round(inset) + 'px');
  }

  setUnread(count) {
    this.unread = Math.min(60, count);
    this.count.textContent = String(this.unread);
    this.count.hidden = this.unread === 0;
  }

  post() {
    const text = this.input.value.trim();
    if (!this.enabled || !text || text.length > 250) return;
    this.send({ type: 'chat', generation: this.generation, text });
    this.input.value = '';
    this.updateComposer();
  }

  updateComposer() {
    this.submit.disabled = !this.enabled || !this.input.value.trim();
  }

  receive(session, packet) {
    if (this.session !== session || this.pending >= 32 || packet.byteLength > 2048) return;
    this.pending++;
    this.queue = this.queue.then(async () => {
      if (this.session !== session) return;
      const nonce = new DataView(packet, 0, 12);
      const sequence = nonce.getBigUint64(4);
      if (sequence <= this.received) return;
      const bytes = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, session.key, new Uint8Array(packet, 12));
      if (this.session !== session) return;
      this.received = sequence;
      this.apply(JSON.parse(new TextDecoder().decode(bytes)));
    }).catch(() => {
      // Invalid chat packets do not interrupt screen control.
    }).finally(() => {
      if (this.session === session) this.pending--;
    });
  }

  apply(event) {
    if (event.type === 'state' && Number.isSafeInteger(event.generation) && event.generation >= this.generation &&
        typeof event.enabled === 'boolean') {
      this.generation = event.generation;
      this.enabled = event.enabled;
      this.toggle.hidden = !this.enabled;
      if (!this.enabled) {
        const focused = this.panel.contains(document.activeElement) || document.activeElement === this.toggle;
        this.setOpen(false, false);
        if (focused) document.getElementById('disconnect').focus();
      }
      this.updateComposer();
    } else if (event.type === 'message' && this.enabled && event.generation === this.generation &&
        typeof event.fromHost === 'boolean' && typeof event.text === 'string' && event.text.trim() && event.text.length <= 250) {
      this.append(event);
    }
  }

  append(message) {
    const atBottom = this.feed.scrollHeight - this.feed.scrollTop - this.feed.clientHeight < 30;
    const bubble = document.createElement('div');
    bubble.className = 'chat-message' + (message.fromHost ? '' : ' is-own');
    const author = document.createElement('span');
    author.dataset.author = message.fromHost ? 'Ведущий' : 'Вы';
    author.textContent = translate(author.dataset.author);
    const text = document.createElement('div');
    text.dir = 'auto';
    text.textContent = message.text;
    bubble.append(author, text);
    if (this.log.childElementCount >= 60) this.log.firstElementChild.remove();
    this.log.append(bubble);
    this.empty.hidden = true;
    if (this.panel.hidden && message.fromHost) this.setUnread(this.unread + 1);
    if (atBottom || !message.fromHost) this.feed.scrollTop = this.feed.scrollHeight;
    this.scheduleCollapse();
  }
}
