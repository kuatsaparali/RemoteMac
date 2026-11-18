import { spawn } from 'node:child_process';
import { Resolver, resolve4 } from 'node:dns';
import { once } from 'node:events';
import { request } from 'node:https';
import { fileURLToPath } from 'node:url';

const fallbackDNS = new Resolver({ timeout: 1500, tries: 1 });
fallbackDNS.setServers(['1.1.1.1', '1.0.0.1']);

// This supervisor owns both services. Closing the app closes stdin and tears them down.
let relay;
let tunnel;
let stopped = false;
let startupTimeout;
let probeTimer;
let probing = false;
let address;
let registered = false;
let ready = false;
let logBuffer = '';

const emit = event => process.stdout.write(JSON.stringify(event) + '\n');

function shutdown(code = 0) {
  if (stopped) return;
  stopped = true;
  clearTimeout(startupTimeout);
  clearTimeout(probeTimer);
  relay?.closeAllConnections();
  relay?.close();
  if (!tunnel || tunnel.exitCode !== null || tunnel.signalCode !== null) {
    process.exit(code);
    return;
  }
  tunnel.once('exit', () => process.exit(code));
  tunnel.kill('SIGTERM');
  setTimeout(() => {
    tunnel.kill('SIGKILL');
    process.exit(code);
  }, 2000);
}

function fail(message) {
  if (stopped) return;
  emit({ type: 'error', message });
  shutdown(1);
}

function probe() {
  if (stopped || ready || probing || !address || !registered) return;
  probing = true;
  let settled = false;
  // Resolve the fresh DNS record without retaining a negative macOS resolver entry.
  const check = request(address, {
    family: 4,
    autoSelectFamily: false,
    lookup(hostname, options, callback) {
      resolve4(hostname, (error, addresses) => {
        if (!error && addresses.length) {
          callback(null, addresses[0], 4);
          return;
        }
        // Some routers cache NXDOMAIN before the new tunnel record exists.
        fallbackDNS.resolve4(hostname, (fallbackError, resolved) => {
          if (fallbackError) callback(fallbackError);
          else if (resolved.length) callback(null, resolved[0], 4);
          else callback(new Error('No DNS address'));
        });
      });
    },
  }, response => {
    response.resume();
    finish(response.statusCode === 200);
  });
  const timeout = setTimeout(() => check.destroy(new Error('Timed out')), 4000);
  check.on('error', () => finish(false));
  check.end();

  function finish(available) {
    if (settled) return;
    settled = true;
    probing = false;
    clearTimeout(timeout);
    if (stopped) return;
    if (available) {
      ready = true;
      clearTimeout(startupTimeout);
      emit({ type: 'ready', address, localAddress: 'http://127.0.0.1:' + relay.address().port });
    } else {
      probeTimer = setTimeout(probe, 1000);
    }
  }
}

function consume(chunk) {
  logBuffer += chunk.toString('utf8');
  const lines = logBuffer.split('\n');
  logBuffer = lines.pop().slice(-16_384);
  for (const line of lines) {
    const match = line.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
    if (match) address = match[0];
    if (line.includes('Registered tunnel connection')) registered = true;
  }
  probe();
}

process.stdin.resume();
process.stdin.on('end', () => shutdown());
process.on('SIGTERM', () => shutdown());
process.on('SIGINT', () => shutdown());
process.on('uncaughtException', () => fail('Не удалось запустить подключение. Повторите попытку.'));
process.on('unhandledRejection', () => fail('Не удалось запустить подключение. Повторите попытку.'));

try {
  if (!process.env.MACREMOTE_HOST_KEY || !process.env.MACREMOTE_CLOUDFLARED) {
    throw new Error('Missing desktop configuration');
  }
  process.env.PORT = '0';
  process.env.BIND_HOST = '127.0.0.1';
  ({ server: relay } = await import('./server.mjs'));
  if (!relay.listening) await once(relay, 'listening');
  if (!stopped) {
    tunnel = spawn(process.env.MACREMOTE_CLOUDFLARED, [
      'tunnel', '--config', fileURLToPath(new URL('./cloudflared.yml', import.meta.url)),
      '--no-autoupdate', '--protocol', 'http2',
      '--url', 'http://127.0.0.1:' + relay.address().port,
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    tunnel.stdout.on('data', consume);
    tunnel.stderr.on('data', consume);
    tunnel.on('error', () => fail('Не удалось запустить интернет-подключение. Переустановите MacRemote.'));
    tunnel.on('exit', () => {
      if (!stopped) fail('Интернет-подключение прервалось. Создайте новую ссылку.');
    });
    startupTimeout = setTimeout(() => fail('Сервис подключения не ответил. Проверьте интернет и повторите попытку.'), 90_000);
  }
} catch {
  fail('Не удалось запустить подключение. Переустановите MacRemote.');
}
