const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { wipeSignalSessions, isWipableSignalFile } = require('./baileys_wrapper.js');

test('wipeSignalSessions deletes session and sender-key only', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zepto-wipe-'));
    try {
        fs.writeFileSync(path.join(dir, 'creds.json'), '{"registered":true}');
        fs.writeFileSync(path.join(dir, 'session-216638251077681.0.json'), '{}');
        fs.writeFileSync(path.join(dir, 'sender-key-x.json'), '{}');
        fs.writeFileSync(path.join(dir, 'pre-key-1.json'), '{}');
        fs.writeFileSync(path.join(dir, 'app-state-sync-key-AAAA.json'), '{}');
        fs.writeFileSync(path.join(dir, 'inbound-ledger.json'), '{}');

        assert.equal(isWipableSignalFile('session-216638251077681.0.json'), true);
        assert.equal(isWipableSignalFile('creds.json'), false);

        const counts = wipeSignalSessions(dir, 'test');
        assert.equal(counts.session, 1);
        assert.equal(counts.senderKey, 1);
        assert.equal(fs.existsSync(path.join(dir, 'creds.json')), true);
        assert.equal(fs.existsSync(path.join(dir, 'pre-key-1.json')), true);
        assert.equal(fs.existsSync(path.join(dir, 'app-state-sync-key-AAAA.json')), true);
        assert.equal(fs.existsSync(path.join(dir, 'inbound-ledger.json')), true);
        assert.equal(fs.existsSync(path.join(dir, 'session-216638251077681.0.json')), false);
        assert.equal(fs.existsSync(path.join(dir, 'sender-key-x.json')), false);
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

test('altDecryptJids retries own LID device sessions for PN from', () => {
    const { altDecryptJids } = require('./baileys_wrapper.js');
    const alts = altDecryptJids('917019895010@s.whatsapp.net', {
        mePn: '917019895010',
        meLid: '216638251077681',
        devicesByUser: {
            '216638251077681': [0, 56],
            '917019895010': [0]
        }
    });
    assert.ok(alts.includes('216638251077681@lid'));
    assert.ok(alts.includes('216638251077681:56@lid'));
    assert.ok(!alts.includes('917019895010@s.whatsapp.net'));
});

test('heal policy ignores history ciphertext and close-storm restarts', () => {
    const {
        shouldCountDecryptFail,
        shouldMarkSessionHealthy,
        shouldAutoHeal,
        shouldRequestNodeRestart,
    } = require('./baileys_wrapper.js');

    assert.equal(shouldCountDecryptFail('append'), false);
    assert.equal(shouldCountDecryptFail('prepend'), false);
    assert.equal(shouldCountDecryptFail('notify'), true);

    assert.equal(shouldMarkSessionHealthy({ fromMe: true, isGroup: false, hasBody: true }), true);
    assert.equal(shouldMarkSessionHealthy({ fromMe: true, isGroup: false, hasBody: false }), false);
    assert.equal(shouldMarkSessionHealthy({ fromMe: true, isGroup: true, hasBody: true }), false);

    assert.equal(shouldAutoHeal({ decryptFails: 52, connectedAtMs: 1, nowMs: 70000, sessionHealthy: true }), false);
    assert.equal(shouldAutoHeal({ decryptFails: 52, connectedAtMs: 1, nowMs: 70000, sessionHealthy: false }), true);
    assert.equal(shouldAutoHeal({ decryptFails: 52, connectedAtMs: 1, nowMs: 30000, sessionHealthy: false }), false);
    assert.equal(shouldAutoHeal({ decryptFails: 3, connectedAtMs: 1, nowMs: 70000, sessionHealthy: false }), false);

    assert.equal(shouldRequestNodeRestart({ sessionHealthy: false, healsInWindow: 3, nodeRestartSent: false, reason: 'close-storm' }), false);
    assert.equal(shouldRequestNodeRestart({ sessionHealthy: false, healsInWindow: 2, nodeRestartSent: false, reason: 'decrypt-after-heal' }), true);
    assert.equal(shouldRequestNodeRestart({ sessionHealthy: true, healsInWindow: 2, nodeRestartSent: false, reason: 'decrypt-after-heal' }), false);
});

test('altDecryptJids device variants stay on same server', () => {
    const { altDecryptJids } = require('./baileys_wrapper.js');
    const alts = altDecryptJids('216638251077681:56@lid', {
        mePn: '917019895010',
        meLid: '216638251077681',
        devicesByUser: { '216638251077681': [0, 55, 56] }
    });
    assert.ok(alts.includes('216638251077681@lid'));
    assert.ok(alts.includes('216638251077681:55@lid'));
    assert.ok(alts.includes('917019895010@s.whatsapp.net'));
    assert.ok(!alts.includes('216638251077681:56@lid'));
});
