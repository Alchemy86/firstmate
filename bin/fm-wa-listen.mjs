#!/usr/bin/env node
// Inbound WhatsApp listener for the firstmate WhatsApp channel.
//
// Runs as a long-lived child of bin/fm-wa-listen.sh and holds ONE WhatsApp
// connection on its OWN linked-device credential folder, separate from
// mudslide's. That separation is the whole point: WhatsApp allows one live
// connection per credential folder, so a listener sharing mudslide's folder
// would fight `mudslide send`. See docs/whatsapp-channel.md for the decision.
//
// This process is RECEIVE-ONLY. Outbound stays on the untouched `mudslide send`
// path (bin/fm-wa-send.sh), so arming or disarming the listener can never break
// sending.
//
// Commands:
//   pair <e164> [rounds]
//                 request an 8-character pairing code for a NEW linked device,
//                 print it, and wait for the link to complete; each expiry
//                 within <rounds> starts a fresh code
//   listen        run until stopped, stashing accepted captain messages to
//                 <state>/wa-inbox/<message-id>.json
//   status        print one JSON line describing the credential folder
//   handle-fixture
//                 read one synthetic message on stdin and report whether it
//                 would be stashed; used by tests/fm-wa-channel.test.sh
//
// Everything it writes is private (0600 files, 0700 directories) and lives
// under the home's gitignored state/ tree.
//
// Environment (all set by bin/fm-wa-listen.sh):
//   FM_WA_STATE        state directory (required)
//   FM_WA_AUTH_DIR     credential folder for THIS device (required)
//   FM_WA_CAPTAIN      captain's number, digits only, e.g. 447700900123
//   FM_WA_ALLOW_DEVICES  comma-separated WhatsApp device numbers to accept
//                        (default "0" - the captain's own phone)
//   FM_WA_BAILEYS_DIR  baileys package directory (auto-discovered when unset)
//   FM_WA_HISTORY_HORIZON  seconds of backlog to accept on first run (default 0)

import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import process from 'node:process'

const STATE = requiredEnv('FM_WA_STATE')
const AUTH_DIR = requiredEnv('FM_WA_AUTH_DIR')
const CAPTAIN = (process.env.FM_WA_CAPTAIN || '').replace(/[^0-9]/g, '')
const ALLOW_DEVICES = parseDevices(process.env.FM_WA_ALLOW_DEVICES ?? '0')
const HISTORY_HORIZON = Number.parseInt(process.env.FM_WA_HISTORY_HORIZON ?? '0', 10) || 0
// How long an unconsumed outbound digest can still suppress an inbound message.
// An echo returns within seconds; anything older is text the captain never sent
// back, so it must stop counting as one.
const ECHO_TTL_SECONDS = 600

const INBOX = path.join(STATE, 'wa-inbox')
const SEEN = path.join(STATE, 'wa-seen')
const SENT = path.join(STATE, 'wa-sent')
const WATERMARK = path.join(STATE, 'wa-watermark')
const LISTENER_STATUS = path.join(STATE, 'wa-listener.status')
const LISTENER_BEAT = path.join(STATE, 'wa-listener.beat')

// Message ids are attacker-influenceable in principle, so they are never used
// as a path component until they match this slug.
const SAFE_ID = /^[A-Za-z0-9._-]{1,128}$/

function requiredEnv(name) {
  const value = process.env[name]
  if (!value) {
    process.stderr.write(`fm-wa-listen: ${name} is required\n`)
    process.exit(2)
  }
  return value
}

function parseDevices(raw) {
  const out = new Set()
  for (const part of String(raw).split(',')) {
    const trimmed = part.trim()
    if (trimmed === '') continue
    if (trimmed === '*') return '*'
    const n = Number.parseInt(trimmed, 10)
    if (Number.isInteger(n) && n >= 0) out.add(n)
  }
  return out.size > 0 ? out : new Set([0])
}

function logLine(message) {
  // stdout is the supervisor's log file; keep it one line per event so an
  // operator can tail it without a parser.
  process.stdout.write(`${new Date().toISOString()} ${message}\n`)
}

// ---------------------------------------------------------------- baileys ---

function baileysDir() {
  if (process.env.FM_WA_BAILEYS_DIR) return process.env.FM_WA_BAILEYS_DIR
  const candidates = []
  const globalRoots = [
    path.join(os.homedir(), '.local', 'lib', 'node_modules'),
    '/usr/local/lib/node_modules',
    '/usr/lib/node_modules',
  ]
  for (const root of globalRoots) {
    candidates.push(path.join(root, 'mudslide', 'node_modules', 'baileys'))
    candidates.push(path.join(root, 'baileys'))
  }
  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, 'lib', 'index.js'))) return candidate
  }
  return null
}

async function loadBaileys() {
  const dir = baileysDir()
  if (!dir) {
    process.stderr.write('fm-wa-listen: cannot find the baileys package; set FM_WA_BAILEYS_DIR\n')
    process.exit(3)
  }
  const mod = await import(path.join(dir, 'lib', 'index.js'))
  let logger = null
  try {
    // Reuse the pino that ships beside baileys so the socket stays silent.
    const require = createRequire(path.join(dir, 'package.json'))
    logger = require('pino')({ level: 'silent' })
  } catch {
    logger = null
  }
  return { mod, dir, logger }
}

async function makeSocket(mod, logger) {
  const { useMultiFileAuthState, fetchLatestWaWebVersion } = mod
  const makeWASocket = mod.makeWASocket ?? mod.default
  ensurePrivateDir(AUTH_DIR)
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR)
  let version
  try {
    ({ version } = await fetchLatestWaWebVersion({}))
  } catch {
    version = undefined
  }
  const platform = process.platform === 'darwin' ? 'macOS'
    : process.platform === 'win32' ? 'Windows' : 'Linux'
  const sock = makeWASocket({
    auth: state,
    ...(logger ? { logger } : {}),
    browser: [platform, 'Chrome', '10.15.0'],
    ...(version ? { version } : {}),
    syncFullHistory: false,
    markOnlineOnConnect: false,
    // The captain's other devices own read receipts and history; this listener
    // must never resend anything, so it declines to look messages up.
    getMessage: async () => undefined,
  })
  sock.ev.on('creds.update', async () => {
    await saveCreds()
    hardenAuthDir()
  })
  return sock
}

// ------------------------------------------------------------ private i/o ---

function ensurePrivateDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  try {
    const st = fs.lstatSync(dir)
    if (!st.isDirectory() || st.isSymbolicLink()) throw new Error('not a directory')
    if ((st.mode & 0o077) !== 0) fs.chmodSync(dir, 0o700)
  } catch (err) {
    throw new Error(`unusable private directory ${dir}: ${err.message}`)
  }
}

// Create-exclusive write: two listeners, or a listener racing its own restart,
// can never both claim the same message id, and a drained id is never rebuilt.
function publishOnce(dir, base, body) {
  ensurePrivateDir(dir)
  const dest = path.join(dir, base)
  let fd
  try {
    fd = fs.openSync(dest, 'wx', 0o600)
  } catch (err) {
    if (err.code === 'EEXIST') return false
    throw err
  }
  try {
    fs.writeFileSync(fd, body)
  } finally {
    fs.closeSync(fd)
  }
  return true
}

function readWatermark() {
  try {
    const n = Number.parseInt(fs.readFileSync(WATERMARK, 'utf8').trim(), 10)
    return Number.isFinite(n) ? n : null
  } catch {
    return null
  }
}

function writeWatermark(ts) {
  const tmp = `${WATERMARK}.tmp-${process.pid}`
  fs.writeFileSync(tmp, `${ts}\n`, { mode: 0o600 })
  fs.renameSync(tmp, WATERMARK)
}

function writeListenerStatus(fields) {
  const tmp = `${LISTENER_STATUS}.tmp-${process.pid}`
  fs.writeFileSync(tmp, `${JSON.stringify(fields)}\n`, { mode: 0o600 })
  fs.renameSync(tmp, LISTENER_STATUS)
}

// ----------------------------------------------------------- echo guard -----

function normalizeText(text) {
  return String(text).replace(/\s+/g, ' ').trim()
}

// An echo comes back within seconds, so a digest older than the TTL belongs to
// text the captain never repeated. Keeping it forever would make those exact
// words a permanent trap: the first time the captain himself typed them, his
// instruction would be swallowed as an echo. Sweeping bounds both that risk and
// the growth of the directory.
function pruneStaleEchoes() {
  const cutoff = Date.now() - ECHO_TTL_SECONDS * 1000
  let entries = []
  try { entries = fs.readdirSync(SENT) } catch { return }
  for (const entry of entries) {
    if (!entry.endsWith('.sent')) continue
    const marker = path.join(SENT, entry)
    try {
      if (fs.statSync(marker).mtimeMs < cutoff) fs.rmSync(marker, { force: true })
    } catch { /* raced with another sweep */ }
  }
}

// Second line of defence behind the device filter. bin/fm-wa-send.sh records a
// digest of everything firstmate sends; if an inbound message matches an
// unconsumed digest that is still within the TTL it is firstmate's own words
// coming back and is dropped. Consuming the marker keeps the captain free to
// repeat the same words later.
async function consumeOwnEcho(text) {
  const normalized = normalizeText(text)
  if (normalized === '') return false
  pruneStaleEchoes()
  const { createHash } = await import('node:crypto')
  const digest = createHash('sha256').update(normalized, 'utf8').digest('hex')
  const marker = path.join(SENT, `${digest}.sent`)
  try {
    fs.unlinkSync(marker)
    return true
  } catch {
    return false
  }
}

// -------------------------------------------------------- message reading ---

function unwrap(message) {
  let current = message
  for (let depth = 0; current && depth < 8; depth += 1) {
    if (current.ephemeralMessage?.message) { current = current.ephemeralMessage.message; continue }
    if (current.viewOnceMessage?.message) { current = current.viewOnceMessage.message; continue }
    if (current.viewOnceMessageV2?.message) { current = current.viewOnceMessageV2.message; continue }
    if (current.viewOnceMessageV2Extension?.message) { current = current.viewOnceMessageV2Extension.message; continue }
    if (current.documentWithCaptionMessage?.message) { current = current.documentWithCaptionMessage.message; continue }
    if (current.editedMessage?.message) { current = current.editedMessage.message; continue }
    return current
  }
  return current
}

function extractText(message) {
  if (!message) return ''
  if (typeof message.conversation === 'string') return message.conversation
  if (typeof message.extendedTextMessage?.text === 'string') return message.extendedTextMessage.text
  for (const key of ['imageMessage', 'videoMessage', 'documentMessage', 'audioMessage']) {
    const caption = message[key]?.caption
    if (typeof caption === 'string' && caption !== '') return caption
  }
  return ''
}

function contextInfoOf(message) {
  if (!message) return null
  if (message.extendedTextMessage?.contextInfo) return message.extendedTextMessage.contextInfo
  for (const key of Object.keys(message)) {
    const ctx = message[key]?.contextInfo
    if (ctx) return ctx
  }
  return null
}

function quotedContext(ctx) {
  if (!ctx?.quotedMessage) return null
  const quoted = unwrap(ctx.quotedMessage)
  return {
    stanza_id: ctx.stanzaId ?? null,
    participant: ctx.participant ?? null,
    text: extractText(quoted) || null,
  }
}

function attachmentKind(message) {
  if (!message) return null
  for (const key of ['imageMessage', 'videoMessage', 'documentMessage', 'audioMessage', 'stickerMessage']) {
    if (message[key]) return key.replace(/Message$/, '')
  }
  return null
}

// ------------------------------------------------------------- accept/deny ---

function jidUser(jid) {
  if (typeof jid !== 'string') return null
  const at = jid.indexOf('@')
  if (at < 0) return null
  return jid.slice(0, at).split(':')[0].split('_')[0]
}

function jidDevice(jid) {
  if (typeof jid !== 'string') return null
  const at = jid.indexOf('@')
  if (at < 0) return null
  const combined = jid.slice(0, at)
  const sep = combined.indexOf(':')
  if (sep < 0) return 0
  const n = Number.parseInt(combined.slice(sep + 1), 10)
  return Number.isInteger(n) ? n : null
}

function deviceAllowed(device) {
  if (ALLOW_DEVICES === '*') return true
  return device !== null && ALLOW_DEVICES.has(device)
}

// ------------------------------------------------------------------ listen ---

async function runListen() {
  const { mod, logger } = await loadBaileys()
  const { DisconnectReason } = mod

  ensurePrivateDir(STATE)
  ensurePrivateDir(INBOX)
  ensurePrivateDir(SEEN)
  ensurePrivateDir(SENT)

  // A first run must not ingest the account's backlog. The watermark is the
  // durable "everything at or before this second is already accounted for"
  // line, so a restart still picks up what arrived while we were down.
  let watermark = readWatermark()
  if (watermark === null) {
    watermark = Math.floor(Date.now() / 1000) - HISTORY_HORIZON
    writeWatermark(watermark)
    logLine(`initialized watermark at ${watermark}`)
  }

  // The device number is the signal that separates the captain typing on his
  // phone from firstmate's own replies coming back through the shared
  // self-chat. baileys drops it from the emitted key, so capture it from the
  // raw stanza and correlate by message id.
  const deviceById = new Map()
  const rememberDevice = (stanza) => {
    const id = stanza?.attrs?.id
    const from = stanza?.attrs?.participant || stanza?.attrs?.from
    if (!id || !from) return
    deviceById.set(id, jidDevice(from))
    if (deviceById.size > 512) {
      const oldest = deviceById.keys().next().value
      deviceById.delete(oldest)
    }
  }

  let backoff = 1000
  let closing = false
  let current = null
  let connected = false

  // The pid alone says nothing about the channel: a listener can sit alive with
  // a socket that never comes back. The beat is touched only while the
  // connection is actually open, so bin/fm-wa-poll.sh can tell a working
  // listener from a wedged one.
  const touchBeat = () => {
    try {
      fs.writeFileSync(LISTENER_BEAT, `${Math.floor(Date.now() / 1000)}\n`, { mode: 0o600 })
    } catch { /* best effort */ }
  }
  const beatTimer = setInterval(() => { if (connected) touchBeat() }, 60000)
  if (beatTimer.unref) beatTimer.unref()

  const endSocket = (sock) => {
    if (!sock) return
    try { sock.end(undefined) } catch { /* already gone */ }
  }

  const shutdown = () => {
    closing = true
    clearInterval(beatTimer)
    writeListenerStatus({ state: 'stopped', at: Date.now() })
    endSocket(current)
    process.exit(0)
  }
  process.once('SIGTERM', shutdown)
  process.once('SIGINT', shutdown)

  const connect = async () => {
    const sock = await makeSocket(mod, logger)
    current = sock
    if (sock.ws?.on) sock.ws.on('CB:message', rememberDevice)

    sock.ev.on('connection.update', (update) => {
      const { connection, lastDisconnect, qr } = update
      if (qr) {
        logLine('connection needs pairing: run bin/fm-wa-listen.sh pair')
        writeListenerStatus({ state: 'unpaired', at: Date.now() })
      }
      if (connection === 'open') {
        backoff = 1000
        connected = true
        const me = sock.user?.id ?? null
        touchBeat()
        logLine(`connected as ${me}`)
        writeListenerStatus({ state: 'connected', me, at: Date.now() })
      }
      if (connection === 'close') {
        connected = false
        const code = lastDisconnect?.error?.output?.statusCode
        if (code === DisconnectReason?.loggedOut) {
          logLine('logged out on WhatsApp; re-pair with bin/fm-wa-listen.sh pair')
          writeListenerStatus({ state: 'logged-out', at: Date.now() })
          endSocket(sock)
          process.exit(4)
        }
        if (closing) return
        // Release the dead socket before opening its replacement, so one
        // credential folder never carries two live connections.
        endSocket(sock)
        writeListenerStatus({ state: 'reconnecting', code: code ?? null, at: Date.now() })
        logLine(`connection closed (${code ?? 'unknown'}); reconnecting in ${backoff}ms`)
        setTimeout(() => { connect().catch((err) => logLine(`reconnect failed: ${err.message}`)) }, backoff)
        backoff = Math.min(backoff * 2, 60000)
      }
    })

    sock.ev.on('messages.upsert', async ({ messages, type }) => {
      if (type !== 'notify' && type !== 'append') return
      for (const msg of messages ?? []) {
        try {
          await handleMessage(msg, deviceById, () => watermark, (ts) => { watermark = ts })
        } catch (err) {
          logLine(`message handling failed: ${err.message}`)
        }
      }
    })
  }

  await connect()
}

async function handleMessage(msg, deviceById, getWatermark, setWatermark) {
  const key = msg?.key ?? {}
  const id = key.id
  const remoteJid = key.remoteJid ?? ''
  const timestamp = Number(msg?.messageTimestamp ?? 0) || 0

  if (!id || !SAFE_ID.test(id)) return reject('unsafe or missing message id', id)

  // Everything strictly before the watermark is history, not a new instruction.
  // The comparison must stay strict: WhatsApp timestamps are whole seconds, so
  // two messages typed in quick succession routinely share one, and the durable
  // wa-seen marker is what makes a redelivery idempotent.
  if (timestamp !== 0 && timestamp < getWatermark()) {
    return reject('older than the history watermark', id)
  }

  // Groups, broadcasts, status and newsletters are never a captain instruction.
  if (!remoteJid.endsWith('@s.whatsapp.net')) return reject('non-direct chat', remoteJid)

  // The channel is the captain's own chat with himself: his phone writes it,
  // firstmate's linked device reads it. Anything with another user on either
  // side of the key is not that channel.
  if (CAPTAIN !== '' && jidUser(remoteJid) !== CAPTAIN) return reject('chat is not the captain', remoteJid)
  if (key.fromMe !== true) return reject('not from the captain account', remoteJid)

  const device = deviceById.get(id) ?? null
  if (!deviceAllowed(device)) {
    // Device 2 is mudslide, i.e. firstmate's own outbound echoing back.
    return reject(`device ${device ?? 'unknown'} is not an accepted captain device`, id)
  }

  const body = unwrap(msg.message)
  if (!body) return reject('no readable message body', id)
  const ctx = contextInfoOf(body)
  if (ctx?.isForwarded === true || (ctx?.forwardingScore ?? 0) > 0) {
    return reject('forwarded message', id)
  }

  const text = extractText(body)
  if (normalizeText(text) === '') return reject('no text to act on', id)

  if (await consumeOwnEcho(text)) return reject('matches firstmate outbound', id)

  // The durable marker outlives the inbox file, so a message firstmate has
  // already drained is never re-offered even after the inbox entry is removed.
  if (fs.existsSync(path.join(SEEN, `${id}.seen`))) return reject('already handled', id)

  const record = {
    schema: 'fm-wa-inbox-v1',
    id,
    chat_jid: remoteJid,
    sender: jidUser(remoteJid),
    sender_device: device,
    from_me: true,
    timestamp,
    received_at: Math.floor(Date.now() / 1000),
    push_name: msg.pushName ?? null,
    text,
    attachment: attachmentKind(body),
    quoted: quotedContext(ctx),
  }
  // The inbox record is published first and its create-exclusive write is the
  // real claim on this id. Marking the message seen before it is safely stashed
  // would turn a failed inbox write into a permanently lost instruction.
  if (!publishOnce(INBOX, `${id}.json`, `${JSON.stringify(record, null, 2)}\n`)) {
    return reject('already stashed', id)
  }
  publishOnce(SEEN, `${id}.seen`, `${timestamp}\n`)
  if (timestamp > getWatermark()) {
    setWatermark(timestamp)
    writeWatermark(timestamp)
  }
  logLine(`stashed ${id} from device ${device}`)
}

function reject(why, detail) {
  logLine(`ignored (${why}) ${detail ?? ''}`.trimEnd())
}

// --------------------------------------------------------------- fixture ---
//
// Drive handleMessage with a synthetic message so every accept/reject rule -
// device, chat kind, sender, forwarding, echo, watermark, text extraction - is
// testable without a live WhatsApp session. Reads one JSON object on stdin:
//   { "stanza_from": "447700900123:0@s.whatsapp.net", "message": <WAMessage> }
// and prints the resulting inbox decision.

async function runFixture() {
  ensurePrivateDir(STATE)
  ensurePrivateDir(INBOX)
  ensurePrivateDir(SEEN)
  ensurePrivateDir(SENT)

  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const fixture = JSON.parse(Buffer.concat(chunks).toString('utf8'))

  let watermark = readWatermark()
  if (watermark === null) {
    watermark = 0
    writeWatermark(watermark)
  }

  const deviceById = new Map()
  const msg = fixture.message
  if (fixture.stanza_from && msg?.key?.id) {
    deviceById.set(msg.key.id, jidDevice(fixture.stanza_from))
  }

  const before = fs.existsSync(path.join(INBOX, `${msg?.key?.id}.json`))
  await handleMessage(msg, deviceById, () => watermark, (ts) => { watermark = ts })
  const after = msg?.key?.id && SAFE_ID.test(msg.key.id)
    ? fs.existsSync(path.join(INBOX, `${msg.key.id}.json`))
    : false
  process.stdout.write(`${(!before && after) ? 'ACCEPTED' : 'REJECTED'} ${msg?.key?.id ?? ''}\n`)
}

// -------------------------------------------------------------------- pair ---

async function runPair(number, rounds) {
  const digits = String(number).replace(/[^0-9]/g, '')
  if (digits.length < 8) {
    process.stderr.write('fm-wa-listen: pair needs the captain number in international form\n')
    process.exit(2)
  }
  if (isRegistered()) {
    process.stderr.write(`fm-wa-listen: ${AUTH_DIR} already holds a linked device; unpair first\n`)
    process.exit(2)
  }
  const { mod, logger } = await loadBaileys()
  const { delay, DisconnectReason } = mod
  let remaining = Number.isInteger(rounds) && rounds > 0 ? rounds : 1

  // A pairing code lives for a couple of minutes. The captain is often away
  // from his phone when the link is set up, so each expiry (408) starts a fresh
  // round with a new code rather than ending the attempt. Every round prints
  // its own PAIRING_CODE line, so whoever is relaying codes always has the
  // current one.
  //
  // Once WhatsApp accepts the code it asks for a reconnect (restartRequired),
  // and baileys has already saved the credentials that reconnect must use. That
  // reconnect therefore keeps the credential folder and requests no new code;
  // only a genuinely fresh round clears the folder.
  let linked = false
  let relinks = 0
  const MAX_RELINKS = 5

  const attempt = async ({ fresh }) => {
    remaining -= 1
    if (fresh) clearAuthDir()
    // A restart reconnect is finishing an accepted link, not starting one.
    let requested = !fresh
    const sock = await makeSocket(mod, logger)
    sock.ev.on('connection.update', async (update) => {
      const { connection, lastDisconnect } = update
      if (connection === 'connecting' && !requested) {
        requested = true
        await delay(5000)
        try {
          const code = await sock.requestPairingCode(digits)
          const shown = code && code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code
          process.stdout.write(`PAIRING_CODE ${shown}\n`)
        } catch (err) {
          process.stderr.write(`fm-wa-listen: pairing code request failed: ${err.message}\n`)
          process.exit(5)
        }
      }
      if (connection === 'open') {
        hardenAuthDir()
        writeListenerStatus({ state: 'paired', me: sock.user?.id ?? null, at: Date.now() })
        process.stdout.write(`PAIRED ${sock.user?.id ?? ''}\n`)
        // Let the credential writes flush before exiting.
        await delay(3000)
        process.exit(0)
      }
      if (connection === 'close') {
        const code = lastDisconnect?.error?.output?.statusCode
        try { sock.end(undefined) } catch { /* already gone */ }
        if (code === DisconnectReason?.restartRequired || linked) {
          // The link completed and WhatsApp wants a reconnect to finish it.
          // Reconnect on the credentials baileys just saved; clearing them here
          // would throw away the link and ask for another code forever.
          linked = true
          relinks += 1
          if (relinks > MAX_RELINKS) {
            process.stderr.write('fm-wa-listen: the linked device never settled after pairing\n')
            process.exit(6)
          }
          if (relinks === 1) process.stdout.write('PAIRING_ACCEPTED; reconnecting to finish the link\n')
          remaining += 1
          await delay(2000)
          await attempt({ fresh: false })
          return
        }
        if (remaining > 0) {
          process.stdout.write(`PAIRING_EXPIRED ${code ?? 'unknown'}; requesting a fresh code\n`)
          await delay(2000)
          await attempt({ fresh: true })
          return
        }
        process.stderr.write(`fm-wa-listen: pairing connection closed (${code ?? 'unknown'})\n`)
        process.exit(6)
      }
    })
  }
  await attempt({ fresh: true })
}

// ------------------------------------------------------------------ status ---

function isRegistered() {
  try {
    return JSON.parse(fs.readFileSync(path.join(AUTH_DIR, 'creds.json'), 'utf8'))?.registered === true
  } catch {
    return false
  }
}

function clearAuthDir() {
  let entries = []
  try { entries = fs.readdirSync(AUTH_DIR) } catch { return }
  for (const entry of entries) {
    if (entry.endsWith('.json')) fs.rmSync(path.join(AUTH_DIR, entry), { force: true })
  }
}

// baileys writes its credential files world-readable; the folder is 0700 so
// they are already unreachable, but narrow the files too.
function hardenAuthDir() {
  let entries = []
  try { entries = fs.readdirSync(AUTH_DIR) } catch { return }
  for (const entry of entries) {
    try { fs.chmodSync(path.join(AUTH_DIR, entry), 0o600) } catch { /* best effort */ }
  }
}

function runStatus() {
  const creds = path.join(AUTH_DIR, 'creds.json')
  let me = null
  let registered = false
  try {
    const parsed = JSON.parse(fs.readFileSync(creds, 'utf8'))
    me = parsed?.me?.id ?? null
    registered = parsed?.registered === true
  } catch { /* not paired yet */ }
  process.stdout.write(`${JSON.stringify({ auth_dir: AUTH_DIR, paired: me !== null, registered, me })}\n`)
}

// -------------------------------------------------------------------- main ---

const [command, ...rest] = process.argv.slice(2)
switch (command) {
  case 'listen':
    runListen().catch((err) => {
      process.stderr.write(`fm-wa-listen: ${err.stack ?? err.message}\n`)
      process.exit(1)
    })
    break
  case 'pair':
    runPair(rest[0] ?? CAPTAIN, Number.parseInt(rest[1] ?? '1', 10)).catch((err) => {
      process.stderr.write(`fm-wa-listen: ${err.stack ?? err.message}\n`)
      process.exit(1)
    })
    break
  case 'status':
    runStatus()
    break
  case 'handle-fixture':
    runFixture().catch((err) => {
      process.stderr.write(`fm-wa-listen: ${err.stack ?? err.message}\n`)
      process.exit(1)
    })
    break
  default:
    process.stderr.write('usage: fm-wa-listen.mjs listen|pair [<e164>] [<rounds>]|status|handle-fixture\n')
    process.exit(2)
}
