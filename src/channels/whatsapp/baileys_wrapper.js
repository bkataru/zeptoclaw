#!/usr/bin/env node

/**
 * Baileys Wrapper for ZeptoClaw
 * Provides a JSON-RPC interface to Baileys WhatsApp library
 */

const { default: makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, makeCacheableSignalKeyStore, downloadMediaMessage } = require('@whiskeysockets/baileys');
const pino = require('pino');
const qrcode = require('qrcode-terminal');
const fs = require('fs');
const path = require('path');

// Global state
let socket = null;
let authDir = null;
let messageHandlers = [];
let connectionHandlers = [];
let qrHandlers = [];
let isConnected = false;
let selfJid = null;
let selfE164 = null;
let allowedFrom = new Set(); // E.164 strings from channels.whatsapp.allowFrom for symmetric DM wake
let lastInitOptions = {};
let sockGen = 0;
let reconnectTimer = null;
let reconnectBackoffMs = 2000;
const RECONNECT_BACKOFF_MAX_MS = 60000;
let reconnectInFlight = false;
let shuttingDown = false;
const seenMessageIds = new Set();
const sentMessageIds = new Set();
const MAX_SEEN = 2000;
let connectedAtMs = 0;
let ledgerPath = null;
const fingerprints = new Map(); // key -> lastSeenMs
let decryptFails = 0;
let lastDecryptJid = '';
let lastDecryptLogMs = 0;
let lastHealMs = 0;
let healsInWindow = 0;
let windowStartMs = 0;
let emittedSinceHeal = false;
let sessionHealthy = false;
let nodeRestartSent = false;
let consecutiveCloseStorm = 0;
let closeStormStartMs = 0;
const recentMessages = new Map();
let lastWsMs = 0;
let stderrBlocked = false;
function origConsoleError(...args) {
    // A full Zig stderr pipe blocks Node's event loop and WhatsApp looks
    // connected while messages.upsert never reaches JSON-RPC stdout.
    if (stderrBlocked) return;
    const s = args.map((a) => (typeof a === 'string' ? a : (a && a.stack) || (a && a.message) || String(a))).join(' ');
    try {
        const ok = process.stderr.write(s + '\n');
        if (!ok) {
            stderrBlocked = true;
            process.stderr.once('drain', () => { stderrBlocked = false; });
        }
    } catch (_) {}
}
let lastSelfProbeMs = 0;

function selfChatJids() {
    const out = [];
    const seen = new Set();
    const add = (jid) => {
        const s = String(jid || '');
        if (!s || seen.has(s)) return;
        seen.add(s);
        out.push(s);
    };
    const lid = (socket && socket.user && socket.user.lid) || '';
    if (String(lid).includes('@lid')) {
        add(String(lid).split('@')[0].split(':')[0] + '@lid');
    }
    const pn = String(selfE164 || '').replace(/[^0-9:]/g, '').split(':')[0];
    if (pn) add(pn + '@s.whatsapp.net');
    // Notes/"Message yourself" LID seen in operator self-chat (distinct from me.lid).
    add('200008104202464@lid');
    return out;
}

async function probeSelfChat() {
    if (Date.now() - lastSelfProbeMs < 180000) return;
    lastSelfProbeMs = Date.now();
    const jids = selfChatJids();
    origConsoleError('[zepto] self-probe start ' + jids.join(','));
    for (const jid of jids) {
        try {
            if (socket && typeof socket.assertSessions === 'function') {
                await socket.assertSessions([jid], true);
            }
        } catch (err) {
            origConsoleError('[zepto] self-probe session fail ' + jid + ' ' + (err && err.message ? err.message : err));
        }
    }
    // Do not send a wake-word body: that starts an agent turn. Session assert is enough
    // to rebuild the self-chat ratchet so the next fromMe ping can decrypt.
}

function parseJidParts(jid) {
    const s = String(jid || '');
    const at = s.indexOf('@');
    if (at < 0) return null;
    const left = s.slice(0, at);
    const server = s.slice(at + 1);
    const colon = left.indexOf(':');
    const user = colon >= 0 ? left.slice(0, colon) : left;
    const device = colon >= 0 ? parseInt(left.slice(colon + 1), 10) || 0 : 0;
    if (!user || !server) return null;
    return { user, server, device };
}

function encodeJidParts(user, server, device) {
    return (device ? user + ':' + device : user) + '@' + server;
}

function sessionDevicesFromDir(dir) {
    const map = Object.create(null);
    if (!dir) return map;
    let names;
    try {
        names = fs.readdirSync(dir);
    } catch (_) {
        return map;
    }
    for (const name of names) {
        const m = /^session-([^.]+)\.(\d+)\.json$/.exec(name);
        if (!m) continue;
        const user = m[1];
        const device = parseInt(m[2], 10);
        if (!map[user]) map[user] = [];
        if (!map[user].includes(device)) map[user].push(device);
    }
    return map;
}

function altDecryptJids(jid, opts) {
    const parsed = parseJidParts(jid);
    if (!parsed) return [];
    const mePn = String((opts && opts.mePn) || '');
    const meLid = String((opts && opts.meLid) || '');
    const devicesByUser = (opts && opts.devicesByUser) || {};
    const seen = new Set([parsed.user + '|' + parsed.server + '|' + (parsed.device || 0)]);
    const alts = [];
    const add = (user, server, device) => {
        if (!user || !server) return;
        const d = device || 0;
        const key = user + '|' + server + '|' + d;
        if (seen.has(key)) return;
        seen.add(key);
        alts.push(encodeJidParts(user, server, d));
    };
    const addUserDevices = (user, server) => {
        add(user, server, 0);
        const extra = devicesByUser[user] || [];
        for (const d of extra) add(user, server, d);
    };
    addUserDevices(parsed.user, parsed.server);
    const isUs = (mePn && parsed.user === mePn) || (meLid && parsed.user === meLid);
    if (isUs) {
        if (meLid) addUserDevices(meLid, 'lid');
        if (mePn) addUserDevices(mePn, 's.whatsapp.net');
    }
    return alts;
}

function wrapSelfChatDecrypt(sock) {
    const repo = sock && sock.signalRepository;
    if (!repo || typeof repo.decryptMessage !== 'function' || repo.__zeptoWrapped) return;
    const orig = repo.decryptMessage.bind(repo);
    repo.__zeptoWrapped = true;
    repo.decryptMessage = async (opts) => {
        try {
            return await orig(opts);
        } catch (err) {
            const me = (sock && sock.user) || (sock && sock.authState && sock.authState.creds && sock.authState.creds.me) || {};
            const meLid = String(me.lid || '').split('@')[0].split(':')[0];
            const mePn = String(me.id || selfJid || '').split('@')[0].split(':')[0];
            const type = String((opts && opts.type) || '');
            const origParts = parseJidParts(opts && opts.jid);
            const alts = altDecryptJids(opts && opts.jid, {
                mePn,
                meLid,
                devicesByUser: sessionDevicesFromDir(authDir)
            });
            for (const alt of alts) {
                // pkmsg builds a session under the address we pass. Never attach
                // a pre-key payload to a different identity (PN vs LID) — that
                // consumes our one-time prekeys and poisons the PN session.
                if (type === 'pkmsg' && origParts) {
                    const p = parseJidParts(alt);
                    if (!p || p.user !== origParts.user || p.server !== origParts.server) continue;
                }
                try {
                    origConsoleError('[zepto] decrypt retry alt=' + alt + ' from=' + ((opts && opts.jid) || '') + ' type=' + type);
                    const out = await orig(Object.assign({}, opts, { jid: alt }));
                    origConsoleError('[zepto] decrypt retry ok alt=' + alt);
                    return out;
                } catch (_) {}
            }
            origConsoleError('[zepto] decrypt alts exhausted jid=' + ((opts && opts.jid) || '') + ' type=' + type + ' n=' + alts.length);
            throw err;
        }
    };
}

function isWipableSignalFile(name) {
    return name.startsWith('session-') || name.startsWith('sender-key-');
}

function wipeSignalSessions(dir, reason) {
    const out = { session: 0, senderKey: 0 };
    const reasonStr = String(reason || '');
    if (!dir) {
        origConsoleError('[zepto] heal wiped session=0 sender-key=0 creds_kept=true reason=' + reasonStr);
        return out;
    }
    let names;
    try {
        names = fs.readdirSync(dir);
    } catch (err) {
        if (err && err.code === 'ENOENT') {
            origConsoleError('[zepto] heal wiped session=0 sender-key=0 creds_kept=true reason=' + reasonStr);
            return out;
        }
        throw err;
    }
    for (const name of names) {
        if (!isWipableSignalFile(name)) continue;
        try {
            const p = path.join(dir, name);
            if (!fs.statSync(p).isFile()) continue;
            fs.unlinkSync(p);
            if (name.startsWith('session-')) out.session += 1;
            else out.senderKey += 1;
        } catch (_) {}
    }
    origConsoleError('[zepto] heal wiped session=' + out.session + ' sender-key=' + out.senderKey + ' creds_kept=true reason=' + reasonStr);
    return out;
}

function rememberRecentMessage(id, message) {
    if (!id || !message) return;
    recentMessages.set(id, message);
    if (recentMessages.size > 200) {
        const first = recentMessages.keys().next().value;
        recentMessages.delete(first);
    }
}

function noteDecryptFail(jidHint) {
    decryptFails += 1;
    if (jidHint) {
        const m = String(jidHint).match(/(\d{6,})/);
        if (m) lastDecryptJid = m[1];
    }
    const now = Date.now();
    if (now - lastDecryptLogMs >= 10000) {
        lastDecryptLogMs = now;
        origConsoleError('[zepto] decrypt fail n=' + decryptFails + ' jid=' + (lastDecryptJid || ''));
    }
}

function shouldCountDecryptFail(upsertType) {
    return upsertType === 'notify';
}

function shouldMarkSessionHealthy(opts) {
    return !!(opts && opts.fromMe && !opts.isGroup && opts.hasBody);
}

function shouldAutoHeal(opts) {
    const decryptN = (opts && opts.decryptFails) || 0;
    const connected = (opts && opts.connectedAtMs) || 0;
    const nowMs = (opts && opts.nowMs) || 0;
    const healthy = !!(opts && opts.sessionHealthy);
    const minFails = (opts && opts.minFails) || 8;
    const minConnectedMs = (opts && opts.minConnectedMs) || 60000;
    if (healthy) return false;
    if (decryptN < minFails) return false;
    if (!connected) return false;
    if (nowMs - connected < minConnectedMs) return false;
    return true;
}

function shouldRequestNodeRestart(opts) {
    if (opts && opts.nodeRestartSent) return false;
    if (opts && opts.sessionHealthy) return false;
    if (opts && opts.reason === 'close-storm') return false;
    return ((opts && opts.healsInWindow) || 0) >= 2;
}

function maybeHealDecrypt(reason) {
    const now = Date.now();
    if (!shouldAutoHeal({ decryptFails, connectedAtMs, nowMs: now, sessionHealthy })) {
        if (decryptFails >= 8 && sessionHealthy) {
            origConsoleError('[zepto] heal skip reason=' + reason + ' healthy=true fails=' + decryptFails);
        }
        return;
    }
    origConsoleError('[zepto] heal fire reason=' + reason + ' fails=' + decryptFails + ' healthy=' + sessionHealthy);
    healAndReinit(reason).catch((err) => {
        origConsoleError('[zepto] heal failed:', err && err.message ? err.message : err);
    });
}

async function healAndReinit(reason) {
    if (Date.now() - lastHealMs < 120000) return false;
    lastHealMs = Date.now();
    wipeSignalSessions(authDir, reason);
    if (Date.now() - windowStartMs > 15 * 60 * 1000) {
        windowStartMs = Date.now();
        healsInWindow = 0;
    }
    healsInWindow += 1;
    emittedSinceHeal = false;
    sessionHealthy = false;
    decryptFails = 0;
    // 408/428 close-storm is a transport timeout, not a bad Signal ratchet.
    // Wiping then init() here skipped scheduleReconnect and reset backoff to 2s,
    // which looped ~28 minutes of 408s. Wipe only; caller reconnects.
    if (reason !== 'close-storm') {
        reconnectBackoffMs = 2000;
        await init(lastInitOptions);
    }
    return true;
}

function ledgerFile(dir) {
    return path.join(dir, 'inbound-ledger.json');
}

function loadLedger(dir) {
    ledgerPath = ledgerFile(dir);
    try {
        const raw = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
        for (const id of raw.seen || []) seenMessageIds.add(id);
        for (const id of raw.sent || []) {
            sentMessageIds.add(id);
            seenMessageIds.add(id);
        }
        for (const [k, ts] of Object.entries(raw.fingerprints || {})) {
            fingerprints.set(k, ts);
        }
    } catch (_) {}
}

function saveLedger() {
    if (!ledgerPath) return;
    try {
        const seen = Array.from(seenMessageIds).slice(-MAX_SEEN);
        const sent = Array.from(sentMessageIds).slice(-MAX_SEEN);
        const fps = {};
        const cutoff = Date.now() - 24 * 3600 * 1000;
        for (const [k, ts] of fingerprints.entries()) {
            if (ts >= cutoff) fps[k] = ts;
        }
        fs.writeFileSync(ledgerPath, JSON.stringify({ seen, sent, fingerprints: fps }));
    } catch (err) {
        console.error('ledger save failed:', err.message);
    }
}

function rememberId(set, id) {
    if (!id) return;
    set.add(id);
    if (set.size > MAX_SEEN) {
        const first = set.values().next().value;
        set.delete(first);
    }
}

function fpKey(chatId, fromMe, body) {
    const b = String(body || '').trim().replace(/\s+/g, ' ').slice(0, 400);
    return `${chatId}|${fromMe ? '1' : '0'}|${b}`;
}

function isReplay(chatId, fromMe, body, id) {
    if (id && (sentMessageIds.has(id) || seenMessageIds.has(id))) return true;
    const k = fpKey(chatId, fromMe, body);
    const prev = fingerprints.get(k);
    // Same text+chat already handled recently = reconnect replay or echo.
    // A later identical ping (new id, after TTL) is allowed.
    if (prev && Date.now() - prev < 3 * 60 * 1000) return true;
    return false;
}

function markHandled(chatId, fromMe, body, id, sent) {
    if (id) {
        rememberId(seenMessageIds, id);
        if (sent) rememberId(sentMessageIds, id);
    }
    fingerprints.set(fpKey(chatId, fromMe, body), Date.now());
    saveLedger();
}

// Logger
const logger = pino({ level: 'silent' });

/**
 * Initialize WhatsApp connection
 */
function clearReconnectTimer() {
    if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
    }
}

function discardSocket(sock) {
    if (!sock) return;
    try { sock.ev.removeAllListeners(); } catch (_) {}
    try { sock.end(undefined); } catch (_) {}
    try { sock.ws && sock.ws.close(); } catch (_) {}
}

function scheduleReconnect(reason) {
    if (shuttingDown) return;
    if (reconnectTimer || reconnectInFlight) return;
    const delay = reconnectBackoffMs;
    console.error('[zepto] whatsapp closed (' + String(reason) + '); reconnect in ' + delay + 'ms');
    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        reconnectBackoffMs = Math.min(reconnectBackoffMs * 2, RECONNECT_BACKOFF_MAX_MS);
        reconnectInFlight = true;
        init(lastInitOptions).then(() => {
            reconnectInFlight = false;
        }).catch((err) => {
            reconnectInFlight = false;
            console.error('[zepto] reconnect failed:', err && err.message ? err.message : err);
            scheduleReconnect('init-failed');
        });
    }, delay);
}

function setAllowFrom(list) {
    allowedFrom = new Set((Array.isArray(list) ? list : []).map(v => String(v).replace(/[^0-9]/g, '').replace(/^0+/, '')));
    if (lastInitOptions && typeof lastInitOptions === 'object') {
        lastInitOptions.allow_from = Array.isArray(list) ? list : [];
    }
    console.error('[zepto] setAllowFrom n=' + allowedFrom.size);
    return { success: true, count: allowedFrom.size };
}

async function init(options = {}) {
    shuttingDown = false;
    lastInitOptions = options && typeof options === 'object' ? options : lastInitOptions;
    const { auth_dir, print_qr = true, browser = ['zeptoclaw', 'cli', '1.0.0'], allow_from = [] } = lastInitOptions;
    if (Array.isArray(allow_from)) {
        allowedFrom = new Set(allow_from.map(v => String(v).replace(/[^0-9]/g, '').replace(/^0+/, '')));
    }

    authDir = auth_dir || path.join(process.env.HOME, '.local', 'share', 'zeptoclaw', 'sessions', 'whatsapp');
    loadLedger(authDir);

    // Ensure auth directory exists
    if (!fs.existsSync(authDir)) {
        fs.mkdirSync(authDir, { recursive: true });
    }

    clearReconnectTimer();
    sockGen += 1;
    const gen = sockGen;
    const previous = socket;
    socket = null;
    discardSocket(previous);

    // Load auth state
    const { state, saveCreds } = await useMultiFileAuthState(authDir);

    // Fetch latest Baileys version
    const { version } = await fetchLatestBaileysVersion();

    // Create socket
    socket = makeWASocket({
        version,
        auth: {
            creds: state.creds,
            keys: makeCacheableSignalKeyStore(state.keys, logger),
        },
        printQRInTerminal: false,
        browser,
        logger,
        // false = do not request FULL dump. Must still set shouldSyncHistoryMessage
        // or Socket/index.js overrides it to () => false and live fromMe/self-chat
        // never arrives after a session wipe (history handshake never completes).
        syncFullHistory: false,
        shouldSyncHistoryMessage: () => true,
        markOnlineOnConnect: true,
        getMessage: async (key) => recentMessages.get(key?.id) || undefined,
    });
    wrapSelfChatDecrypt(socket);

    // Save credentials on update
    socket.ev.on('creds.update', saveCreds);

    // Handle connection updates
    socket.ev.on('connection.update', (update) => {
        if (gen !== sockGen) return;
        const { connection, lastDisconnect, qr, receivedPendingNotifications } = update;
        if (receivedPendingNotifications) {
            origConsoleError('[zepto] pending-notifs connection=' + String(connection || ''));
        }

        if (qr) {
            // Notify QR handlers
            qrHandlers.forEach(handler => handler(qr));

            // Print QR to terminal if requested
            if (print_qr) {
                console.error('\nScan this QR code in WhatsApp (Linked Devices):');
                qrcode.generate(qr, { small: true }, function (q) { console.error(q); });
            }
        }

        if (connection === 'open') {
            connectedAtMs = Date.now();
            isConnected = true;
            reconnectBackoffMs = 2000;
            reconnectInFlight = false;
            consecutiveCloseStorm = 0;
            closeStormStartMs = 0;
            // Keep decryptFails through handshake. Boot ciphertext used to be
            // zeroed here, then maybeHealDecrypt never ran again after the 60s gate.
            clearReconnectTimer();
            selfJid = socket.user?.id;
            selfE164 = selfJid ? jidToE164(selfJid) : null;

            // Notify connection handlers
            connectionHandlers.forEach(handler => handler({ type: 'connected', selfJid, selfE164 }));
            console.log(JSON.stringify({ jsonrpc: '2.0', method: 'stats', params: { type: 'connected', decryptFails, lastHealMs, healsInWindow } }));
            socket.sendPresenceUpdate('available').catch((err) => origConsoleError('[zepto] presence err ' + (err && err.message ? err.message : err)));
            origConsoleError('[zepto] presence available');
            const openGen = gen;
            setTimeout(() => {
                if (openGen !== sockGen) return;
                try { if (socket && socket.ev && typeof socket.ev.flush === 'function') socket.ev.flush(); } catch (_) {}
                origConsoleError('[zepto] flush-buffer emitted=' + emittedSinceHeal);
            }, 8000);
            // upsertMessage is createBufferedFunction: it calls ev.buffer() and
            // never flushes (Baileys defers that to the history state machine).
            // After the one-shot 8s flush, the next live stanza re-buffers and
            // the socket looks connected while messages.upsert never fires.
            let lastTickMs = 0;
            const flushIv = setInterval(() => {
                if (openGen !== sockGen || !isConnected) {
                    clearInterval(flushIv);
                    return;
                }
                try {
                    if (socket && socket.ev && typeof socket.ev.flush === 'function') {
                        const drained = socket.ev.flush();
                        if (drained) origConsoleError('[zepto] ev.flush drained');
                    }
                    const now = Date.now();
                    if (now - lastTickMs >= 15000) {
                        lastTickMs = now;
                        const age = lastWsMs ? (now - lastWsMs) : -1;
                        origConsoleError('[zepto] tick connected=true lastWsAge=' + age + ' decryptFails=' + decryptFails + ' emitted=' + emittedSinceHeal + ' healthy=' + sessionHealthy + ' heals=' + healsInWindow);
                    }
                } catch (_) {}
            }, 2000);
            probeSelfChat().catch((err) => origConsoleError('[zepto] self-probe err', err && err.message ? err.message : err));
            setTimeout(() => {
                if (openGen !== sockGen) return;
                probeSelfChat().catch((err) => origConsoleError('[zepto] self-probe err', err && err.message ? err.message : err));
            }, 5000);
            setTimeout(() => {
                if (openGen !== sockGen) return;
                origConsoleError('[zepto] 60s-check healthy=' + sessionHealthy + ' fails=' + decryptFails + ' heals=' + healsInWindow + ' emitted=' + emittedSinceHeal);
                if (shouldAutoHeal({ decryptFails, connectedAtMs, nowMs: Date.now(), sessionHealthy })) {
                    healAndReinit('decrypt-burst').catch((err) => {
                        origConsoleError('[zepto] heal failed:', err && err.message ? err.message : err);
                    });
                }
                if (shouldRequestNodeRestart({ sessionHealthy, healsInWindow, nodeRestartSent, reason: 'decrypt-after-heal' })) {
                    nodeRestartSent = true;
                    console.log(JSON.stringify({ jsonrpc: '2.0', method: 'needNodeRestart', params: { reason: 'decrypt-after-heal' } }));
                }
            }, 60000);
        }

        if (connection === 'close') {
            isConnected = false;
            const status = lastDisconnect?.error?.output?.statusCode;
            const loggedOut = status === DisconnectReason.loggedOut;

            // Notify connection handlers
            connectionHandlers.forEach(handler => handler({
                type: 'disconnected',
                status,
                isLoggedOut: loggedOut,
                error: lastDisconnect?.error
            }));

            if (shuttingDown) return;
            if (loggedOut) {
                console.error('[zepto] logged out; scan QR (no auto-reconnect)');
                return;
            }
            if (status === DisconnectReason.badSession) {
                healAndReinit('badSession').then((healed) => {
                    if (!healed) scheduleReconnect(500);
                }).catch((err) => {
                    origConsoleError('[zepto] heal failed:', err && err.message ? err.message : err);
                    scheduleReconnect(500);
                });
                return;
            }
            if (status === 408 || status === 428) {
                if (consecutiveCloseStorm === 0) closeStormStartMs = Date.now();
                consecutiveCloseStorm += 1;
                if (consecutiveCloseStorm >= 8 && Date.now() - closeStormStartMs >= 180000) {
                    consecutiveCloseStorm = 0;
                    closeStormStartMs = 0;
                    healAndReinit('close-storm').then(() => {
                        origConsoleError('[zepto] close-storm after-heal reconnect healthy=' + sessionHealthy);
                        scheduleReconnect(status);
                    }).catch((err) => {
                        origConsoleError('[zepto] heal failed:', err && err.message ? err.message : err);
                        scheduleReconnect(status);
                    });
                    return;
                }
            }
            scheduleReconnect(status == null ? 'close' : status);
        }
    });

    try {
        const ws = socket.ws;
        if (ws && typeof ws.on === 'function') {
            const fillSelfChatRecipient = (node) => {
                if (gen !== sockGen) return;
                const attrs = (node && node.attrs) || {};
                if (attrs.recipient) return;
                const from = String(attrs.from || '');
                if (!from.endsWith('@s.whatsapp.net')) return;
                const me = (socket && socket.user) || (socket.authState && socket.authState.creds && socket.authState.creds.me) || {};
                const meUser = String(me.id || selfJid || '').split('@')[0].split(':')[0];
                const fromUser = from.split('@')[0].split(':')[0];
                if (!meUser || fromUser !== meUser) return;
                const lidUser = String(me.lid || '').split('@')[0].split(':')[0];
                if (lidUser) attrs.recipient = lidUser + '@lid';
            };
            if (typeof ws.prependListener === 'function') ws.prependListener('CB:message', fillSelfChatRecipient);
            else ws.on('CB:message', fillSelfChatRecipient);
            ws.on('CB:message', (node) => {
                if (gen !== sockGen) return;
                lastWsMs = Date.now();
                try { if (socket && socket.ev && typeof socket.ev.flush === 'function') socket.ev.flush(); } catch (_) {}
                const attrs = (node && node.attrs) || {};
                let encType = '';
                if (Array.isArray(node.content)) {
                    const enc = node.content.find((c) => c && c.tag === 'enc');
                    if (enc && enc.attrs) encType = String(enc.attrs.type || '');
                }
                const blob = [attrs.from, attrs.participant, attrs.recipient, attrs.participant_pn, attrs.sender_pn].join(' ');
                if (/216638251077681|917019895010/.test(blob) || String(attrs.recipient || '').length) {
                    origConsoleError('[zepto] raw-msg from=' + (attrs.from || '') + ' participant=' + (attrs.participant || '') + ' recipient=' + (attrs.recipient || '') + ' type=' + (attrs.type || '') + ' enc=' + encType + ' id=' + (attrs.id || ''));
                }
            });
        }
    } catch (_) {}

    // Handle incoming messages
    socket.ev.on('messages.upsert', async ({ messages, type }) => {
        if (gen !== sockGen) return;
        const m0 = messages && messages[0];
        const fm0 = !!(m0 && m0.key && m0.key.fromMe);
        const j0 = (m0 && m0.key && m0.key.remoteJid) || '';
        const group0 = String(j0).endsWith('@g.us');
        // Diagnostic: self-chat upserts were vanishing with zero logs
        // (15:08 pkmsgs decrypted, session .56 written, nothing emitted).
        // Log every matching message, not just messages[0].jid — history
        // batches are headed by a group JID.
        const selfRe = /216638251077681|200008104202464|19082673946862|917019895010/;
        for (const m of (messages || [])) {
            const blob = [
                (m.key && m.key.remoteJid) || '',
                (m.key && m.key.remoteJidAlt) || '',
                (m.key && m.key.senderPn) || '',
                (m.key && m.key.participant) || ''
            ].join(' ');
            if (!selfRe.test(blob)) continue;
            origConsoleError('[zepto] upsert-msg type=' + type
                + ' id=' + (m.key && m.key.id)
                + ' jid=' + (m.key && m.key.remoteJid)
                + ' alt=' + ((m.key && m.key.remoteJidAlt) || '')
                + ' senderPn=' + ((m.key && m.key.senderPn) || '')
                + ' fromMe=' + !!(m.key && m.key.fromMe)
                + ' ts=' + (m.messageTimestamp || 0)
                + ' keys=' + JSON.stringify(Object.keys(m.message || {})));
        }
        if (type === 'notify' || (fm0 && !group0) || !emittedSinceHeal) {
            origConsoleError('[zepto] upsert type=' + type + ' n=' + ((messages && messages.length) || 0) + ' jid=' + j0 + ' fromMe=' + fm0 + ' hasMsg=' + !!(m0 && m0.message));
        }
        // notify/append/prepend: live + history. Dedup is ledger/isReplay.
        if (type !== 'notify' && type !== 'append' && type !== 'prepend') return;

        for (const msg of messages) {
            if (!msg.key) continue;

            const remoteJid = msg.key.remoteJid;
            if (!remoteJid) continue;

            const mid = msg.key.id;

            // Skip status and broadcast messages
            if (remoteJid.endsWith('@status') || remoteJid.endsWith('@broadcast')) continue;

            const isGroupChat = remoteJid.endsWith('@g.us');
            if (msg.key.fromMe) {
                const peerE164 = jidToE164(remoteJid);
                const peerDigits = String(peerE164 || '').replace(/[^0-9]/g, '');
                const selfDigits = String(selfE164 || '').replace(/[^0-9]/g, '');
                const isOwnPhoneJid = Boolean(selfDigits && peerDigits === selfDigits && remoteJid.endsWith('@s.whatsapp.net'));
                // PN self-chat ("Message yourself" addressed as our own @s.whatsapp.net).
                // Used to `continue` here, which silently dropped operator pings after LID→PN remap.
                if (isOwnPhoneJid) {
                    origConsoleError('[zepto] fromMe self-pn', remoteJid);
                } else if (!isGroupChat) {
                    const pn = jidToE164(msg.key.remoteJidAlt || msg.key.senderPn || '');
                    const pnDigits = String(pn || peerDigits).replace(/[^0-9]/g, '');
                    const allowed = remoteJid.endsWith('@lid') || (pnDigits && allowedFrom.has(pnDigits));
                    if (!allowed) {
                        origConsoleError('[zepto] skip fromMe', remoteJid);
                        continue;
                    }
                }
            }

            if (!msg.message) {
                if (shouldCountDecryptFail(type)) {
                    noteDecryptFail(remoteJid);
                    if (msg.key.fromMe && !isGroupChat) origConsoleError('[zepto] ciphertext fromMe live ' + remoteJid + ' ' + mid);
                    maybeHealDecrypt('ciphertext');
                } else if (msg.key.fromMe && !isGroupChat) {
                    origConsoleError('[zepto] ciphertext fromMe history type=' + type + ' ' + remoteJid + ' ' + mid);
                }
                continue;
            }
            rememberRecentMessage(mid, msg.message);

            let messageData = extractMessageData(msg);
            if (messageData.mediaType === 'image') {
                messageData = await saveInboundMedia(msg, messageData);
            }
            if ((!messageData.body || !String(messageData.body).trim()) && !messageData.mediaType) {
                if (msg.key.fromMe && !isGroupChat) origConsoleError('[zepto] skip empty', remoteJid, mid);
                continue;
            }
            if (msg.key.fromMe && isGroupChat && !/barvis/i.test(String(messageData.body || ''))) continue;
            if (isReplay(remoteJid, !!msg.key.fromMe, messageData.body, mid)) {
                if (shouldMarkSessionHealthy({ fromMe: !!msg.key.fromMe, isGroup: isGroupChat, hasBody: !!(messageData.body && String(messageData.body).trim()) })) {
                    sessionHealthy = true;
                    emittedSinceHeal = true;
                    origConsoleError('[zepto] session healthy via replay chat=' + remoteJid + ' type=' + type);
                }
                if (msg.key.fromMe && !isGroupChat) origConsoleError('[zepto] skip replay', remoteJid, mid);
                continue;
            }

            let emitted = false;
            messageHandlers.forEach(handler => {
                try {
                    handler(messageData);
                    emitted = true;
                } catch (err) {
                    console.error('Message handler error:', err);
                }
            });
            // History append/prepend is not proof the live socket works.
            // Other chats emitting used to set this and skip maybeHealDecrypt
            // while self-chat stayed ciphertext.
            const hasBody = !!(messageData.body && String(messageData.body).trim());
            if (emitted && shouldMarkSessionHealthy({ fromMe: !!msg.key.fromMe, isGroup: isGroupChat, hasBody })) {
                sessionHealthy = true;
                emittedSinceHeal = true;
                nodeRestartSent = false;
                origConsoleError('[zepto] session healthy chat=' + remoteJid + ' type=' + type + ' id=' + mid);
            } else if (emitted && type === 'notify') {
                emittedSinceHeal = true;
                nodeRestartSent = false;
            }
            if (emitted || messageHandlers.length === 0) {
                markHandled(remoteJid, !!msg.key.fromMe, messageData.body, mid, false);
            }
        }
    });

    socket.ev.on('messaging-history.set', async ({ messages, isLatest, syncType }) => {
        if (gen !== sockGen) return;
        const all = messages || [];
        origConsoleError('[zepto] history n=' + all.length + ' latest=' + isLatest + ' syncType=' + String(syncType));
        const cutoff = Math.floor(Date.now() / 1000) - 6 * 3600;
        const recent = all.filter((m) => {
            const ts = Number(m && m.messageTimestamp || 0);
            if (ts < cutoff) return false;
            const jid = (m.key && m.key.remoteJid) || '';
            if (!jid || jid.endsWith('@g.us') || jid.endsWith('@status') || jid.endsWith('@broadcast')) return false;
            return !!(m.key && m.key.fromMe);
        });
        origConsoleError('[zepto] history ingest n=' + recent.length);
        if (!recent.length) return;
        socket.ev.emit('messages.upsert', { messages: recent, type: 'append' });
    });

    return { success: true };
}

/**
 * Wait for connection to be established
 */
async function waitForConnection(timeout = 60000) {
    return new Promise((resolve, reject) => {
        if (isConnected) {
            resolve({ connected: true, selfJid, selfE164 });
            return;
        }

        const timer = setTimeout(() => {
            cleanup();
            reject(new Error('Connection timeout'));
        }, timeout);

        const handler = (update) => {
            if (update.type === 'connected') {
                clearTimeout(timer);
                cleanup();
                resolve({ connected: true, selfJid: update.selfJid, selfE164: update.selfE164 });
            } else if (update.type === 'disconnected') {
                clearTimeout(timer);
                cleanup();
                reject(new Error(`Connection failed: ${update.status}`));
            }
        };

        const cleanup = () => {
            const idx = connectionHandlers.indexOf(handler);
            if (idx !== -1) connectionHandlers.splice(idx, 1);
        };

        connectionHandlers.push(handler);
    });
}

/**
 * Send a text message
 */
function withTimeout(promise, ms, label) {
    let timer;
    const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(label || `timeout ${ms}ms`)), ms);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

async function sendMessage(to, text, options = {}) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const jid = normalizeJid(to);
    const result = await withTimeout(socket.sendMessage(jid, { text }), 20000, 'sendMessage timeout');
    const sid = result?.key?.id;
    markHandled(jid, true, text, sid, true);

    return {
        success: true,
        messageId: sid,
        timestamp: result?.messageTimestamp
    };
}

/**
 * Send a media message
 */
async function sendMedia(to, mediaPath, caption, options = {}) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const jid = normalizeJid(to);

    if (!fs.existsSync(mediaPath)) {
        throw new Error(`Media file not found: ${mediaPath}`);
    }

    const mediaBuffer = fs.readFileSync(mediaPath);
    const mediaType = getMimeType(mediaPath);

    let mediaMessage;
    if (mediaType.startsWith('image/')) {
        mediaMessage = {
            image: mediaBuffer,
            caption: caption || undefined
        };
    } else if (mediaType.startsWith('video/')) {
        mediaMessage = {
            video: mediaBuffer,
            caption: caption || undefined
        };
    } else if (mediaType.startsWith('audio/')) {
        // WhatsApp expects explicit opus codec for PTT voice notes
        const codec = mediaType === 'audio/ogg' ? 'audio/ogg; codecs=opus' : mediaType;
        mediaMessage = {
            audio: mediaBuffer,
            mimetype: codec,
            ptt: true
        };
    } else {
        mediaMessage = {
            document: mediaBuffer,
            mimetype: mediaType,
            caption: caption || undefined
        };
    }

    const result = await socket.sendMessage(jid, mediaMessage);

    return {
        success: true,
        messageId: result?.key?.id,
        timestamp: result?.messageTimestamp
    };
}

/**
 * Send a reaction
 */
async function sendReaction(chatJid, messageId, emoji, options = {}) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const jid = normalizeJid(chatJid);

    const reactionMessage = {
        react: {
            key: {
                remoteJid: jid,
                fromMe: options.fromMe || false,
                id: messageId,
                participant: options.participant
            },
            text: emoji
        }
    };

    await socket.sendMessage(jid, reactionMessage);

    return { success: true };
}

/**
 * Send a poll
 */
async function sendPoll(to, poll) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const jid = normalizeJid(to);

    const pollMessage = {
        poll: {
            name: poll.name,
            values: poll.options,
            selectableCount: poll.selectableCount || 1
        }
    };

    const result = await socket.sendMessage(jid, pollMessage);

    return {
        success: true,
        messageId: result?.key?.id,
        timestamp: result?.messageTimestamp
    };
}

/**
 * Mark messages as read
 */
async function markRead(messages) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const keys = messages.map(msg => ({
        remoteJid: msg.remoteJid,
        id: msg.id,
        fromMe: msg.fromMe || false,
        participant: msg.participant
    }));

    await socket.readMessages(keys);

    return { success: true };
}

/**
 * Send presence update
 */
async function sendPresence(presence, toJid) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    if (toJid) {
        await socket.sendPresenceUpdate(presence, normalizeJid(toJid));
    } else {
        await socket.sendPresenceUpdate(presence);
    }

    return { success: true };
}

/**
 * Get contact info
 */
async function getContactInfo(jid) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const normalizedJid = normalizeJid(jid);

    try {
        const info = await socket.onWhatsApp(normalizedJid);

        if (info && info.length > 0) {
            return {
                success: true,
                exists: info[0].exists,
                jid: info[0].jid
            };
        }

        return { success: true, exists: false };
    } catch (err) {
        return { success: false, error: err.message };
    }
}

/**
 * Get group metadata
 */
async function getGroupMetadata(jid) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const normalizedJid = normalizeJid(jid);

    try {
        const metadata = await socket.groupMetadata(normalizedJid);

        return {
            success: true,
            subject: metadata.subject,
            participants: metadata.participants.map(p => ({
                id: p.id,
                admin: p.admin
            }))
        };
    } catch (err) {
        return { success: false, error: err.message };
    }
}

/**
 * Disconnect and cleanup
 */
async function disconnect() {
    shuttingDown = true;
    clearReconnectTimer();
    reconnectInFlight = false;
    const previous = socket;
    socket = null;
    discardSocket(previous);

    isConnected = false;
    selfJid = null;
    selfE164 = null;
    messageHandlers = [];
    connectionHandlers = [];
    qrHandlers = [];

    return { success: true };
}

/**
 * Register event handlers
 */
function onMessage(handler) {
    messageHandlers.push(handler);
}

function onConnection(handler) {
    connectionHandlers.push(handler);
}

function onQr(handler) {
    qrHandlers.push(handler);
}

/**
 * Utility functions
 */
function normalizeJid(input) {
    if (!input) return null;

    // If already a JID, return as-is
    if (input.includes('@')) {
        return input;
    }

    // Assume E.164 format, convert to JID
    const cleaned = input.replace(/[^0-9]/g, '');
    if (cleaned.length > 0) {
        return `${cleaned}@s.whatsapp.net`;
    }

    return input;
}

function jidToE164(jid) {
    if (!jid) return null;
    return String(jid).replace(/@s\.whatsapp\.net$/, '').replace(/@g\.us$/, '').replace(/@lid$/, '');
}

function extractMessageData(msg) {
    const remoteJid = msg.key.remoteJid;
    const isGroup = remoteJid && remoteJid.endsWith('@g.us');
    const participantJid = msg.key.participant;
    const fromMe = !!msg.key.fromMe;
    const altJid = msg.key.remoteJidAlt || msg.key.senderPn || msg.key.participantAlt || null;

    let body = '';
    let mediaType = null;
    let location = null;
    let mentionedJids = [];

    const message = (function unwrap(m) {
        if (!m) return m;
        const inner = m.ephemeralMessage?.message || m.viewOnceMessage?.message || m.viewOnceMessageV2?.message || m.viewOnceMessageV2Extension?.message || m.documentWithCaptionMessage?.message || m.editedMessage?.message || m.protocolMessage?.editedMessage;
        return inner ? unwrap(inner) : m;
    })(msg.message);


    if (message) {
        // Extract text
        if (message.conversation) {
            body = message.conversation;
        } else if (message.extendedTextMessage) {
            body = message.extendedTextMessage.text || '';
            mentionedJids = message.extendedTextMessage.contextInfo?.mentionedJid || [];
        } else if (message.imageMessage) {
            body = message.imageMessage.caption || '';
            mediaType = 'image';
        } else if (message.videoMessage) {
            body = message.videoMessage.caption || '';
            mediaType = 'video';
        } else if (message.documentMessage) {
            body = message.documentMessage.caption || '';
            mediaType = 'document';
        } else if (message.audioMessage) {
            mediaType = 'audio';
        } else if (message.locationMessage) {
            location = {
                latitude: message.locationMessage.degreesLatitude,
                longitude: message.locationMessage.degreesLongitude
            };
            body = `📍 Location: ${location.latitude}, ${location.longitude}`;
        } else if (message.liveLocationMessage) {
            location = {
                latitude: message.liveLocationMessage.degreesLatitude,
                longitude: message.liveLocationMessage.degreesLongitude
            };
            body = `📍 Live Location: ${location.latitude}, ${location.longitude}`;
        }
    }

    // Extract reply context
    let replyContext = null;
    const contextInfo = message?.extendedTextMessage?.contextInfo ||
                        message?.imageMessage?.contextInfo ||
                        message?.videoMessage?.contextInfo;

    if (contextInfo?.stanzaId) {
        replyContext = {
            messageId: contextInfo.stanzaId,
            participant: contextInfo.participant,
            quotedMessage: contextInfo.quotedMessage
        };
    }

    return {
        id: msg.key.id,
        from: isGroup ? remoteJid : jidToE164(remoteJid),
        to: selfE164,
        chatId: remoteJid,
        chatType: isGroup ? 'group' : 'direct',
        senderJid: isGroup ? (participantJid || altJid || remoteJid) : (fromMe ? selfJid : (altJid || remoteJid)),
        senderE164: fromMe
            ? (selfE164 || null)
            : (jidToE164(altJid) || (isGroup ? jidToE164(participantJid) : jidToE164(remoteJid))),
        fromMe,
        senderName: fromMe ? 'Baala' : msg.pushName,
        body,
        mediaType,
        mediaPath: null,
        mediaMime: null,
        location,
        mentionedJids,
        replyContext: replyContext ? { messageId: replyContext.messageId, participant: replyContext.participant } : null,
        timestamp: msg.messageTimestamp ? Number(msg.messageTimestamp) * 1000 : Date.now()
    };
}

async function saveInboundMedia(msg, messageData) {
    try {
        const buf = await downloadMediaMessage(msg, 'buffer', {});
        if (!buf || !buf.length || buf.length > 6 * 1024 * 1024) {
            console.error('media skip: empty or too large', buf && buf.length);
            return messageData;
        }
        const dir = path.join(authDir || '.', 'media');
        fs.mkdirSync(dir, { recursive: true });
        const mime = (msg.message && msg.message.imageMessage && msg.message.imageMessage.mimetype) || 'image/jpeg';
        const ext = mime.includes('png') ? '.png' : mime.includes('webp') ? '.webp' : '.jpg';
        const id = String(msg.key.id || Date.now()).replace(/[^A-Za-z0-9_-]/g, '_');
        const dest = path.join(dir, id + ext);
        fs.writeFileSync(dest, buf);
        messageData.mediaPath = dest;
        messageData.mediaMime = mime;
        const lastDir = path.join(authDir || '.', 'last-image');
        fs.mkdirSync(lastDir, { recursive: true });
        const safe = String(messageData.chatId || 'chat').replace(/[^A-Za-z0-9._-]/g, '_');
        fs.writeFileSync(path.join(lastDir, safe + '.txt'), mime + '\n' + dest);
        console.error('[zepto] saved inbound image', dest, buf.length);
    } catch (err) {
        console.error('media download failed:', err && err.message ? err.message : err);
    }
    return messageData;
}

function getMimeType(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    const mimeTypes = {
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.png': 'image/png',
        '.gif': 'image/gif',
        '.webp': 'image/webp',
        '.mp4': 'video/mp4',
        '.mov': 'video/quicktime',
        '.avi': 'video/x-msvideo',
        '.mp3': 'audio/mpeg',
        '.ogg': 'audio/ogg',
        '.wav': 'audio/wav',
        '.pdf': 'application/pdf',
        '.doc': 'application/msword',
        '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        '.xls': 'application/vnd.ms-excel',
        '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        '.txt': 'text/plain',
        '.zip': 'application/zip',
        '.rar': 'application/x-rar-compressed'
    };

    return mimeTypes[ext] || 'application/octet-stream';
}

/**
 * JSON-RPC interface for communication with Zig
 */
async function handleRpcRequest(request) {
    const { id, method, params } = request;

    async function sendResponse(result) {
        console.log(JSON.stringify({ jsonrpc: '2.0', id, result }));
    }

    async function sendError(error) {
        console.log(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -1, message: String(error) } }));
    }

    try {
        switch (method) {
            case 'init':
                await sendResponse(await init(params));
                break;
            case 'setAllowFrom':
                await sendResponse(setAllowFrom(params?.allow_from));
                break;
            case 'heal':
                await sendResponse(await (async () => {
                    const w = wipeSignalSessions(authDir || lastInitOptions.auth_dir, 'rpc');
                    await init(lastInitOptions);
                    return { success: true, wiped: w };
                })());
                break;
            case 'waitForConnection':
                await sendResponse(await waitForConnection(params?.timeout));
                break;
            case 'sendMessage':
                await sendResponse(await sendMessage(params.to, params.text, params.options));
                break;
            case 'sendMedia':
                await sendResponse(await sendMedia(params.to, params.mediaPath, params.caption, params.options));
                break;
            case 'sendReaction':
                await sendResponse(await sendReaction(params.chatJid, params.messageId, params.emoji, params.options));
                break;
            case 'sendPoll':
                await sendResponse(await sendPoll(params.to, params.poll));
                break;
            case 'markRead':
                await sendResponse(await markRead(params.messages));
                break;
            case 'sendPresence':
                await sendResponse(await sendPresence(params.presence, params.toJid));
                break;
            case 'getContactInfo':
                await sendResponse(await getContactInfo(params.jid));
                break;
            case 'getGroupMetadata':
                await sendResponse(await getGroupMetadata(params.jid));
                break;
            case 'disconnect':
                await sendResponse(await disconnect());
                break;
            case 'onMessage':
                onMessage((msg) => {
                    const params = {
                        id: String(msg.id || ''),
                        from: String(msg.from || ''),
                        to: String(msg.to || ''),
                        chatId: String(msg.chatId || ''),
                        chatType: msg.chatType || 'direct',
                        senderJid: String(msg.senderJid || ''),
                        senderE164: String(msg.senderE164 || ''),
                        senderName: String(msg.senderName || ''),
                        fromMe: !!msg.fromMe,
                        body: String(msg.body || ''),
                        timestamp: Number(msg.timestamp || 0),
                    };
                    const line = JSON.stringify({ jsonrpc: '2.0', method: 'message', params });
                    console.log(line);
                    origConsoleError('[zepto] emit ' + params.chatId + ' ' + params.fromMe + ' ' + (params.body || '').slice(0, 80));
                });
                await sendResponse({ success: true });
                break;
            case 'onConnection':
                onConnection((update) => {
                    const params = {
                        type: update && update.type ? update.type : 'disconnected',
                        selfJid: (update && update.selfJid) || '',
                        selfE164: (update && update.selfE164) || '',
                    };
                    console.log(JSON.stringify({ jsonrpc: '2.0', method: 'connection', params }));
                });
                await sendResponse({ success: true });
                break;
            case 'onQr':
                onQr((qr) => {
                    console.log(JSON.stringify({ jsonrpc: '2.0', method: 'qr', params: { qr } }));
                });
                await sendResponse({ success: true });
                break;
            default:
                await sendError(`Unknown method: ${method}`);
        }
    } catch (err) {
        await sendError(err);
    }
}

/**
 * Main entry point - read JSON-RPC requests from stdin
 */
if (require.main === module) {
    console.error = (...args) => {
        const s = args.map((a) => (typeof a === 'string' ? a : (a && a.message) || String(a))).join(' ');
        if (s.includes('Bad MAC') || s.includes('Failed to decrypt')) {
            // History/offline MAC noise is not a live sick socket. Do not
            // increment decryptFails. Rate-limit so stderr cannot stall Node.
            const now = Date.now();
            if (now - lastDecryptLogMs >= 10000) {
                lastDecryptLogMs = now;
                origConsoleError('[zepto] mac-noise ' + s.replace(/\s+/g, ' ').slice(0, 80));
            }
            return;
        }
        origConsoleError(...args);
    };
    let buffer = '';

    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
        buffer += chunk;

        // Process complete JSON lines
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
            if (line.trim()) {
                try {
                    const request = JSON.parse(line);
                    handleRpcRequest(request);
                } catch (err) {
                    console.error('Failed to parse request:', err);
                }
            }
        }
    });

    process.stdin.on('end', () => {
        if (buffer.trim()) {
            try {
                const request = JSON.parse(buffer);
                handleRpcRequest(request);
            } catch (err) {
                console.error('Failed to parse final request:', err);
            }
        }
    });

    // Handle graceful shutdown
    process.on('SIGINT', async () => {
        shuttingDown = true;
        await disconnect();
        process.exit(0);
    });

    process.on('SIGTERM', async () => {
        shuttingDown = true;
        await disconnect();
        process.exit(0);
    });
}

// Export for testing
module.exports = {
    init,
    setAllowFrom,
    waitForConnection,
    sendMessage,
    sendMedia,
    sendReaction,
    sendPoll,
    markRead,
    sendPresence,
    getContactInfo,
    getGroupMetadata,
    disconnect,
    scheduleReconnect,
    onMessage,
    onConnection,
    onQr,
    normalizeJid,
    jidToE164,
    wipeSignalSessions,
    isWipableSignalFile,
    healAndReinit,
    altDecryptJids,
    shouldCountDecryptFail,
    shouldMarkSessionHealthy,
    shouldAutoHeal,
    shouldRequestNodeRestart
};
