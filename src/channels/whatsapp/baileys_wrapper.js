#!/usr/bin/env node

/**
 * Baileys Wrapper for ZeptoClaw
 * Provides a JSON-RPC interface to Baileys WhatsApp library
 */

const { default: makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, makeCacheableSignalKeyStore } = require('@whiskeysockets/baileys');
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

// Logger
const logger = pino({ level: 'silent' });

/**
 * Initialize WhatsApp connection
 */
async function init(options = {}) {
    const { auth_dir, print_qr = true, browser = ['zeptoclaw', 'cli', '1.0.0'] } = options;

    authDir = auth_dir || path.join(process.env.HOME, '.local', 'share', 'zeptoclaw', 'sessions', 'whatsapp');

    // Ensure auth directory exists
    if (!fs.existsSync(authDir)) {
        fs.mkdirSync(authDir, { recursive: true });
    }

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
        const { connection, lastDisconnect, qr } = update;

        if (qr) {
            // Notify QR handlers
            qrHandlers.forEach(handler => handler(qr));

            // Print QR to terminal if requested
            if (print_qr) {
                console.log('\nScan this QR code in WhatsApp (Linked Devices):');
                qrcode.generate(qr, { small: true });
            }
        }

        if (connection === 'open') {
            isConnected = true;
            selfJid = socket.user?.id;
            selfE164 = selfJid ? jidToE164(selfJid) : null;

            // Notify connection handlers
            connectionHandlers.forEach(handler => handler({ type: 'connected', selfJid, selfE164 }));
        }

        if (connection === 'close') {
            isConnected = false;
            const status = lastDisconnect?.error?.output?.statusCode;

            // Notify connection handlers
            connectionHandlers.forEach(handler => handler({
                type: 'disconnected',
                status,
                isLoggedOut: status === DisconnectReason.loggedOut,
                error: lastDisconnect?.error
            }));
        }
    });

    // Handle incoming messages
    socket.ev.on('messages.upsert', async ({ messages, type }) => {
        if (type !== 'notify' && type !== 'append') return;

        for (const msg of messages) {
            if (!msg.key) continue;

            const remoteJid = msg.key.remoteJid;
            if (!remoteJid) continue;

            // Skip status and broadcast messages
            if (remoteJid.endsWith('@status') || remoteJid.endsWith('@broadcast')) continue;

            // Skip messages from self
            if (msg.key.fromMe) continue;

            // Extract message data
            const messageData = extractMessageData(msg);

            // Notify message handlers
            messageHandlers.forEach(handler => {
                try {
                    handler(messageData);
                } catch (err) {
                    console.error('Message handler error:', err);
                }
            });
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
async function sendMessage(to, text, options = {}) {
    if (!socket || !isConnected) {
        throw new Error('Not connected to WhatsApp');
    }

    const jid = normalizeJid(to);
    const result = await socket.sendMessage(jid, { text });

    return {
        success: true,
        messageId: result?.key?.id,
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
    if (socket) {
        try {
            socket.ws?.close();
        } catch (err) {
            // Ignore close errors
        }
        socket = null;
    }

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
    return jid.replace(/@s\.whatsapp\.net$/, '').replace(/@g\.us$/, '');
}

function extractMessageData(msg) {
    const remoteJid = msg.key.remoteJid;
    const isGroup = remoteJid && remoteJid.endsWith('@g.us');
    const participantJid = msg.key.participant;

    let body = '';
    let mediaType = null;
    let location = null;
    let mentionedJids = [];

    const message = msg.message;

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
        senderJid: isGroup ? participantJid : remoteJid,
        senderE164: isGroup ? jidToE164(participantJid) : jidToE164(remoteJid),
        senderName: msg.pushName,
        body,
        mediaType,
        location,
        mentionedJids,
        replyContext,
        timestamp: msg.messageTimestamp ? Number(msg.messageTimestamp) * 1000 : Date.now()
    };
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
function handleRpcRequest(request) {
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
                    console.log(JSON.stringify({ jsonrpc: '2.0', method: 'message', params: msg }));
                });
                await sendResponse({ success: true });
                break;
            case 'onConnection':
                onConnection((update) => {
                    console.log(JSON.stringify({ jsonrpc: '2.0', method: 'connection', params: update }));
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
        await disconnect();
        process.exit(0);
    });

    process.on('SIGTERM', async () => {
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
    onMessage,
    onConnection,
    onQr,
    normalizeJid,
    jidToE164
};
