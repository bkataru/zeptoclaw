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
        syncFullHistory: false,
        markOnlineOnConnect: false,
    });

    // Save credentials on update
    socket.ev.on('creds.update', saveCreds);

    // Handle connection updates
    socket.ev.on('connection.update', (update) => {
        if (gen !== sockGen) return;
        const { connection, lastDisconnect, qr } = update;

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
            clearReconnectTimer();
            selfJid = socket.user?.id;
            selfE164 = selfJid ? jidToE164(selfJid) : null;

            // Notify connection handlers
            connectionHandlers.forEach(handler => handler({ type: 'connected', selfJid, selfE164 }));
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
            scheduleReconnect(status == null ? 'close' : status);
        }
    });

    // Handle incoming messages
    socket.ev.on('messages.upsert', async ({ messages, type }) => {
        if (gen !== sockGen) return;
        // notify = live; append can also be live on LID/group. Dedup is ledger/isReplay.
        if (type !== 'notify' && type !== 'append') return;

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
                if (isOwnPhoneJid) continue;
                if (!isGroupChat) {
                    const pn = jidToE164(msg.key.remoteJidAlt || msg.key.senderPn || '');
                    const pnDigits = String(pn || peerDigits).replace(/[^0-9]/g, '');
                    const allowed = remoteJid.endsWith('@lid') || (pnDigits && allowedFrom.has(pnDigits));
                    if (!allowed) continue;
                }
            }

            let messageData = extractMessageData(msg);
            if (messageData.mediaType === 'image') {
                messageData = await saveInboundMedia(msg, messageData);
            }
            if ((!messageData.body || !String(messageData.body).trim()) && !messageData.mediaType) continue;
            if (msg.key.fromMe && isGroupChat && !/barvis/i.test(String(messageData.body || ''))) continue;
            if (isReplay(remoteJid, !!msg.key.fromMe, messageData.body, mid)) continue;

            let emitted = false;
            messageHandlers.forEach(handler => {
                try {
                    handler(messageData);
                    emitted = true;
                } catch (err) {
                    console.error('Message handler error:', err);
                }
            });
            if (emitted || messageHandlers.length === 0) {
                markHandled(remoteJid, !!msg.key.fromMe, messageData.body, mid, false);
            }
        }
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
                    console.error('[zepto] emit', params.chatId, params.fromMe, (params.body || '').slice(0, 80));
                    console.log(line);
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
    jidToE164
};
