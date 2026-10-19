import { Buffer } from 'buffer'
import { aesEncryptSync, aesDecryptSync, rsaEncryptSync, rsaDecryptSync, AES_MODE, RSA_PADDING } from './shims/native_crypto.js'
import { stringMd5 } from './shims/md5.js'
import { btoa, atob } from './shims/base64.js'

window.Buffer = Buffer
window.LXCrypto = {
  aesEncryptSync,
  aesDecryptSync,
  rsaEncryptSync,
  rsaDecryptSync,
  AES_MODE,
  RSA_PADDING,
  stringMd5,
  btoa,
  atob,
}
