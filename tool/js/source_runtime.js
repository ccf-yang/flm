(function () {
  const nativeSetTimeout = window.setTimeout.bind(window)
  const post = (payload) => {
    if (typeof window.FlmBridge?.postMessage === 'function') {
      window.FlmBridge.postMessage(JSON.stringify(payload))
    }
  }

  window.__flmSourcePost = post
  window.__flmKey = ''

  const utf8ToB64 = (str) => {
    const bytes = new TextEncoder().encode(String(str))
    let binary = ''
    for (const byte of bytes) binary += String.fromCharCode(byte)
    return window.btoa(binary)
  }

  const b64ToBytes = (b64) => {
    const binary = window.atob(String(b64))
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  }

  window.__lx_native_call__ = (key, action, data) => {
    let parsed = data
    if (typeof data === 'string') {
      try {
        parsed = JSON.parse(data)
      } catch (_) {
        parsed = data
      }
    }
    post({ type: 'sourceNative', key, action, data: parsed })
  }

  window.__lx_native_call__set_timeout = (id, timeout) => {
    nativeSetTimeout(() => {
      try {
        window.__lx_native__(window.__flmKey, '__set_timeout__', JSON.stringify(id))
      } catch (_) {}
    }, Number(timeout) || 0)
  }

  window.__lx_native_call__utils_str2b64 = (str) => utf8ToB64(str)
  window.__lx_native_call__utils_b642buf = (b64) => JSON.stringify(Array.from(b64ToBytes(b64)))
  window.__lx_native_call__utils_str2md5 = (str) => window.LXCrypto.stringMd5(str)
  window.__lx_native_call__utils_aes_encrypt = (data, key, iv, mode) =>
    window.LXCrypto.aesEncryptSync(data, key, iv, mode)
  window.__lx_native_call__utils_rsa_encrypt = (data, key, padding) =>
    window.LXCrypto.rsaEncryptSync(data, key, padding)
  window.__lx_native_call__utils_aes_decrypt = (data, key, iv, mode) =>
    window.LXCrypto.aesDecryptSync(data, key, iv, mode)

  window.FlmSource = {
    prepare(info) {
      window.__flmKey = info.key
      globalThis.lx_setup(
        info.key,
        info.id,
        info.name,
        info.description || '',
        info.version || '',
        info.author || '',
        info.homepage || '',
        info.script || '',
      )
      return true
    },
  }
})()
