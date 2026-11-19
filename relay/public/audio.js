'use strict';

class SessionAudio {
  constructor(context) {
    this.context = context;
    this.gain = context.createGain();
    this.gain.connect(context.destination);
    this.muted = false;
    this.sources = new Set();
    this.anchor = null;
    this.audioEnd = 0;
    this.bufferLead = 0.10;
    this.decodeQueue = [];
    this.busy = false;
    this.sequence = 0n;
  }

  async toggle() {
    if (this.muted || this.context.state !== 'running') setPlaybackType('playback');
    if (this.context.state !== 'running') {
      try { await this.context.resume(); } catch { return; }
      this.muted = false;
    } else {
      this.muted = !this.muted;
    }
    this.gain.gain.setTargetAtTime(this.muted ? 0 : 1, this.context.currentTime, 0.01);
  }

  schedule(bytes) {
    if (this.context.state !== 'running' || bytes.byteLength <= 13) return false;
    const view = new DataView(bytes);
    const timestamp = Number(view.getBigUint64(0)) / 1e6;
    const rate = view.getUint32(8);
    const channels = view.getUint8(12);
    if (!Number.isFinite(timestamp) || rate < 8000 || rate > 96000 || channels < 1 || channels > 2) return false;
    const count = (bytes.byteLength - 13) / (channels * 2);
    if (!Number.isInteger(count) || count > 8192) return false;

    const now = this.context.currentTime;
    let start = this.timeFor(timestamp);
    if (!this.anchor || start < now + 0.01) {
      // Discard late audio while earlier samples are still playing. After an
      // underrun, restart from the freshest audio and build a short buffer.
      if (this.audioEnd > now + 0.01) return false;
      if (this.anchor) this.bufferLead = Math.min(0.18, this.bufferLead + 0.02);
      start = now + this.bufferLead;
      this.anchor = { timestamp, start };
    }
    if (start > now + 0.4) return false;
    const buffer = this.context.createBuffer(channels, count, rate);
    for (let channel = 0; channel < channels; channel++) {
      const output = buffer.getChannelData(channel);
      for (let index = 0; index < count; index++) {
        output[index] = view.getInt16(13 + (index * channels + channel) * 2, true) / 32768;
      }
    }

    const node = this.context.createBufferSource();
    node.buffer = buffer;
    node.connect(this.gain);
    const when = Math.max(start, this.audioEnd);
    node.start(when);
    this.audioEnd = when + buffer.duration;
    this.sources.add(node);
    node.onended = () => {
      this.sources.delete(node);
      node.disconnect();
    };
    return true;
  }

  timeFor(timestamp) {
    return this.anchor ? this.anchor.start + timestamp - this.anchor.timestamp : NaN;
  }

  playoutTime() {
    const timestamp = this.context.getOutputTimestamp?.();
    if (timestamp?.performanceTime > 0) {
      return Math.min(this.context.currentTime,
        timestamp.contextTime + (performance.now() - timestamp.performanceTime) / 1000);
    }
    return this.context.currentTime - (this.context.outputLatency ?? this.context.baseLatency ?? 0);
  }

  close() {
    for (const source of this.sources) source.stop();
    this.sources.clear();
    this.context.close().catch(() => {});
    setPlaybackType('auto');
  }
}

function setPlaybackType(type) {
  try {
    // WebKit can treat Web Audio as ambient audio, which follows the iPhone's silent switch.
    if (navigator.audioSession) navigator.audioSession.type = type;
  } catch {}
}

function openSessionAudio() {
  if (typeof AudioContext === 'undefined') return null;
  try {
    const context = new AudioContext({ latencyHint: 'interactive' });
    setPlaybackType('playback');
    context.resume().catch(() => {});
    return new SessionAudio(context);
  } catch {
    return null;
  }
}
