import { Buffer } from 'buffer'

globalThis.Buffer = Buffer
globalThis.global = globalThis

if (!globalThis.process) {
  globalThis.process = { versions: { app: '1.9.1' }, env: {} }
} else {
  globalThis.process.versions = { ...(globalThis.process.versions || {}), app: '1.9.1' }
  globalThis.process.env = globalThis.process.env || {}
}

globalThis.i18n = {
  t(key, params) {
    if (!params) return key
    return Object.keys(params).reduce(
      (text, name) => text.replace(new RegExp(`\\{${name}\\}`, 'g'), String(params[name])),
      key,
    )
  },
}

globalThis.lx = {
  qualityList: {
    kw: ['128k', '320k', 'flac', 'flac24bit'],
    kg: ['128k', '320k', 'flac', 'flac24bit'],
    tx: ['128k', '320k', 'flac', 'flac24bit'],
    wy: ['128k', '320k', 'flac', 'flac24bit'],
    mg: ['128k', '320k', 'flac', 'flac24bit'],
    local: [],
  },
  apis: {},
  gettingUrlId: '',
  playerStatus: {},
}
