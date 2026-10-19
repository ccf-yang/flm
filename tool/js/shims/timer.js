const BackgroundTimer = {
  setTimeout: (handler, timeout, ...args) => setTimeout(handler, timeout, ...args),
  clearTimeout: (id) => clearTimeout(id),
  setInterval: (handler, timeout, ...args) => setInterval(handler, timeout, ...args),
  clearInterval: (id) => clearInterval(id),
}

export default BackgroundTimer
