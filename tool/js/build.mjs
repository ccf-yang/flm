import esbuild from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const here = path.dirname(fileURLToPath(import.meta.url))
const src = path.resolve(here, '../../../lx-music-mobile/src')
const shims = path.resolve(here, 'shims')
const outfile = path.resolve(here, '../../assets/js/engine.js')

const shimOf = (name) => ({ path: path.join(shims, name) })

const resolvePackage = (specifier) => {
  const [name, ...rest] = specifier.split('/')
  const base = path.join(here, 'node_modules', name)
  if (!fs.existsSync(base)) return null
  if (rest.length) {
    const sub = path.join(base, ...rest)
    return fs.existsSync(sub) ? sub : null
  }
  const pkgPath = path.join(base, 'package.json')
  if (!fs.existsSync(pkgPath)) return null
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
  const browser = typeof pkg.browser === 'string'
    ? pkg.browser
    : pkg.browser?.['./index.js'] ?? pkg.browser?.['index.js']
  const entry = browser || pkg.module || pkg.main || 'index.js'
  const resolved = path.join(base, entry)
  return fs.existsSync(resolved) ? resolved : path.join(base, 'index.js')
}

const resolveFile = (target) => {
  const base = path.resolve(src, target)
  const candidates = [
    base,
    `${base}.ts`,
    `${base}.tsx`,
    `${base}.js`,
    `${base}.jsx`,
    `${base}.json`,
    path.join(base, 'index.ts'),
    path.join(base, 'index.tsx'),
    path.join(base, 'index.js'),
    path.join(base, 'index.jsx'),
  ]
  for (const candidate of candidates) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate
  }
  return null
}

const aliasPlugin = {
  name: 'lx-music-alias',
  setup(build) {
    build.onResolve({ filter: /^@\/utils\/request$/ }, () => shimOf('request.js'))
    build.onResolve({ filter: /^@\/utils\/nativeModules\/crypto$/ }, () => shimOf('native_crypto.js'))
    build.onResolve({ filter: /^@\/store\/setting\/state$/ }, () => shimOf('setting_state.js'))
    build.onResolve({ filter: /^react-native-quick-md5$/ }, () => shimOf('md5.js'))
    build.onResolve({ filter: /^react-native-quick-base64$/ }, () => shimOf('base64.js'))
    build.onResolve({ filter: /^react-native-background-timer$/ }, () => shimOf('timer.js'))

    build.onResolve({ filter: /^(pako|he|buffer|crypto-js|node-forge)(\/.*)?$/ }, (args) => {
      const resolved = resolvePackage(args.path)
      return resolved ? { path: resolved } : null
    })

    build.onResolve({ filter: /(^|\/)request(\.js)?$/ }, (args) => {
      if (args.importer.includes('/src/utils/musicSdk/')) return shimOf('request.js')
      return null
    })

    build.onResolve({ filter: /^@\// }, (args) => {
      const target = args.path.slice(2)
      const resolved = resolveFile(target)
      if (!resolved) {
        return { errors: [{ text: `Could not resolve ${args.path} from ${args.importer}` }] }
      }
      return { path: resolved }
    })
  },
}

// iOS JavaScriptCore before 16.4 does not support RegExp lookbehind.  The kw
// SDK uses one in objStr2JSON; rewrite it with lookahead-only patterns so the
// whole bundle does not fail to parse on older iPhones.
const kwCompatPlugin = {
  name: 'kw-lookbehind-compat',
  setup(build) {
    build.onLoad({ filter: /kw\/util\.js$/ }, (args) => {
      const source = fs.readFileSync(args.path, 'utf8')
      const lines = source.split('\n')
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].includes('JSON.parse(str.replace(') && lines[i].includes('(?<=')) {
          lines[i] =
            `  return JSON.parse(str.replace(/([({,:]\\s*)'|'(?=\\s*,\\s*')|'(?=\\s*:)|'(?=\\s*})/g, (match, prefix) => (prefix ?? '') + '"'))`
          break
        }
      }
      return { contents: lines.join('\n'), loader: 'js' }
    })
  },
}

await esbuild.build({
  entryPoints: [path.join(here, 'entry.js')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020'],
  outfile,
  minify: true,
  legalComments: 'none',
  mainFields: ['browser', 'module', 'main'],
  define: {
    'process.env.NODE_ENV': '"production"',
    global: 'globalThis',
  },
  plugins: [aliasPlugin, kwCompatPlugin],
  logLevel: 'info',
})

// Capture parse/runtime errors from the engine script.  Without this a syntax
// error leaves LXEngine undefined and webview_flutter only reports a generic
// "Failed evaluating JavaScript" PlatformException.
const errorPrelude = `(function () {
  window.__flmErrors = window.__flmErrors || [];
  function record(message, source, line, column, stack) {
    var text = String(message || 'unknown');
    window.__flmErrors.push(text);
    try {
      if (typeof FlmBridge !== 'undefined' && FlmBridge.postMessage) {
        FlmBridge.postMessage(JSON.stringify({
          type: 'jsError',
          message: text,
          source: source || '',
          line: line || 0,
          column: column || 0,
          stack: stack || ''
        }));
      }
    } catch (_) {}
  }
  window.addEventListener('error', function (event) {
    record(
      event.message || (event.error && event.error.message) || 'unknown',
      event.filename,
      event.lineno,
      event.colno,
      event.error && event.error.stack
    );
  });
  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    record('unhandledrejection: ' + String((reason && reason.stack) || reason || 'unknown'));
  });
})();`

const htmlFile = path.resolve(here, '../../assets/js/engine.html')
const bundle = fs.readFileSync(outfile, 'utf8').replace(/<\/script/gi, '<\\/script')
fs.writeFileSync(htmlFile, `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body>
<script>${errorPrelude}</script>
<script>${bundle}</script>
</body>
</html>
`)

const sourceCryptoFile = path.resolve(here, '../../assets/js/source_crypto.js')
await esbuild.build({
  entryPoints: [path.join(here, 'source_crypto_entry.js')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020'],
  outfile: sourceCryptoFile,
  minify: true,
  legalComments: 'none',
  mainFields: ['browser', 'module', 'main'],
  define: {
    'process.env.NODE_ENV': '"production"',
    global: 'globalThis',
  },
  plugins: [aliasPlugin],
  logLevel: 'info',
})

const preloadFile = path.resolve(here, '../../../lx-music-mobile/android/app/src/main/assets/script/user-api-preload.js')
// The original preload deep-freezes globalThis, which is safe in QuickJS but
// dangerous in a real WebView (it walks the DOM).  The lx object is already
// frozen separately; skip the global walk.
const preload = fs
  .readFileSync(preloadFile, 'utf8')
  .replace('freezeObjectProperty(globalThis)', '/* flm: globalThis is not deep-frozen in WebView */')
  .replace(/<\/script/gi, '<\\/script')
const sourceCrypto = fs.readFileSync(sourceCryptoFile, 'utf8').replace(/<\/script/gi, '<\\/script')
const runtime = fs.readFileSync(path.join(here, 'source_runtime.js'), 'utf8').replace(/<\/script/gi, '<\\/script')
const sourceHtmlFile = path.resolve(here, '../../assets/js/user_source.html')
fs.writeFileSync(sourceHtmlFile, `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body>
<script>${sourceCrypto}</script>
<script>${preload}</script>
<script>${runtime}</script>
</body>
</html>
`)

console.log('Built', outfile)
console.log('Built', htmlFile)
console.log('Built', sourceCryptoFile)
console.log('Built', sourceHtmlFile)
