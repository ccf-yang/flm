import { Buffer } from 'buffer'

/**
 * Browser/WebView replacement for src/utils/request.js.
 *
 * The Dart side owns the actual HTTP stack (dio) and the cookie jar.  Every
 * request is forwarded through the FlmBridge JavaScript channel.  Responses
 * come back through window.__flmHttpResolve, which lets the SDK keep using
 * its original Promise based API.
 */

let nextRequestId = 0
const pending = new Map()

const post = (payload) => {
  if (typeof window.FlmBridge?.postMessage !== 'function') {
    throw new Error('FlmBridge is not available')
  }
  window.FlmBridge.postMessage(JSON.stringify(payload))
}

export const httpFetch = (url, options = { method: 'get' }) => {
  const id = ++nextRequestId
  let aborted = false

  const promise = new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject })
    post({ type: 'http', id, url, options })
  }).then((resp) => {
    if (aborted) throw new Error('Aborted')
    if (options.binary && typeof resp.body === 'string') {
      resp.body = Buffer.from(resp.body, 'base64')
    } else if (typeof resp.body === 'string') {
      try {
        resp.body = JSON.parse(resp.body)
      } catch (_) {}
    }
    return resp
  })

  return {
    promise,
    cancelHttp() {
      aborted = true
      pending.delete(id)
      post({ type: 'httpCancel', id })
    },
  }
}

export const httpGet = (url, options, callback) => {
  if (typeof options === 'function') {
    callback = options
    options = {}
  }
  const request = httpFetch(url, { ...options, method: 'get' })
  request.promise.then(
    (resp) => callback(null, resp, resp.body),
    (err) => callback(err, null, null),
  )
  return () => request.cancelHttp()
}

export const checkUrl = async (url, options = {}) => {
  const resp = await httpFetch(url, { method: 'head', ...options }).promise
  if (resp.statusCode === 200) return
  throw new Error(String(resp.statusCode))
}

window.__flmHttpResolve = (id, ok, data) => {
  const target = pending.get(id)
  if (!target) return
  pending.delete(id)
  if (ok) target.resolve(data)
  else target.reject(new Error(data?.message ?? 'request failed'))
}
