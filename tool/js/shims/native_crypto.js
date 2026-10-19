import CryptoJS from 'crypto-js'
import forge from 'node-forge'
import { Buffer } from 'buffer'

export const AES_MODE = {
  CBC_128_PKCS7Padding: 'AES/CBC/PKCS7Padding',
  ECB_128_NoPadding: 'AES',
}

export const RSA_PADDING = {
  OAEPWithSHA1AndMGF1Padding: 'RSA/ECB/OAEPWithSHA1AndMGF1Padding',
  NoPadding: 'RSA/ECB/NoPadding',
}

const looksLikeBase64 = (str) =>
  typeof str === 'string' && str.length > 0 && /^[A-Za-z0-9+/=\r\n]+$/.test(str)

const isWordArray = (value) =>
  value != null &&
  typeof value === 'object' &&
  Array.isArray(value.words) &&
  typeof value.sigBytes === 'number'

const bytesToWordArray = (data) => {
  let bytes
  if (data instanceof ArrayBuffer) {
    bytes = new Uint8Array(data)
  } else if (ArrayBuffer.isView(data)) {
    bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  } else {
    bytes = new Uint8Array(data)
  }
  const words = []
  for (let i = 0; i < bytes.length; i++) {
    words[i >>> 2] = (words[i >>> 2] || 0) | (bytes[i] << (24 - (i % 4) * 8))
  }
  return CryptoJS.lib.WordArray.create(words, bytes.length)
}

const toWordArray = (data) => {
  if (isWordArray(data)) return data
  if (typeof data === 'string') return CryptoJS.enc.Base64.parse(data)
  return bytesToWordArray(data)
}

const toKey = (key) => {
  if (isWordArray(key)) return key
  if (typeof key === 'string') {
    return looksLikeBase64(key) ? CryptoJS.enc.Base64.parse(key) : CryptoJS.enc.Utf8.parse(key)
  }
  return toWordArray(key)
}

const aesOptions = (mode, iv) => {
  if (mode === AES_MODE.ECB_128_NoPadding) {
    return { mode: CryptoJS.mode.ECB, padding: CryptoJS.pad.NoPadding }
  }
  return {
    mode: CryptoJS.mode.CBC,
    padding: CryptoJS.pad.Pkcs7,
    iv: iv ? toKey(iv) : CryptoJS.lib.WordArray.create([0, 0, 0, 0]),
  }
}

export const aesEncryptSync = (data, key, iv, mode) => {
  const encrypted = CryptoJS.AES.encrypt(
    toWordArray(data),
    toKey(key),
    aesOptions(mode, iv),
  )
  return encrypted.ciphertext.toString(CryptoJS.enc.Base64)
}

export const aesDecryptSync = (data, key, iv, mode) => {
  const decrypted = CryptoJS.AES.decrypt(
    { ciphertext: toWordArray(data) },
    toKey(key),
    aesOptions(mode, iv),
  )
  try {
    return CryptoJS.enc.Utf8.stringify(decrypted)
  } catch (_) {
    return Buffer.from(decrypted.toString(CryptoJS.enc.Hex), 'hex').toString('utf8')
  }
}

const normalizePem = (key, type) => {
  if (typeof key !== 'string') throw new Error('Invalid RSA key')
  if (key.includes('BEGIN')) return key
  const body = key.replace(/\s+/g, '').match(/.{1,64}/g)?.join('\n') ?? ''
  return `-----BEGIN ${type}-----\n${body}\n-----END ${type}-----`
}

const rsaScheme = (padding) =>
  padding === RSA_PADDING.OAEPWithSHA1AndMGF1Padding ? 'RSA-OAEP' : 'NONE'

export const rsaEncryptSync = (data, key, padding) => {
  const publicKey = forge.pki.publicKeyFromPem(normalizePem(key, 'PUBLIC KEY'))
  const bin = Buffer.from(toWordArray(data).toString(CryptoJS.enc.Base64), 'base64').toString('binary')
  const encrypted = publicKey.encrypt(bin, rsaScheme(padding))
  return Buffer.from(encrypted, 'binary').toString('base64')
}

export const rsaDecryptSync = (data, key, padding) => {
  const privateKey = forge.pki.privateKeyFromPem(normalizePem(key, 'PRIVATE KEY'))
  const bin = Buffer.from(toWordArray(data).toString(CryptoJS.enc.Base64), 'base64').toString('binary')
  const decrypted = privateKey.decrypt(bin, rsaScheme(padding))
  return Buffer.from(decrypted, 'binary').toString('base64')
}

export const hashSHA1 = (text) => CryptoJS.SHA1(String(text)).toString()
