import './prelude.js'
import musicSdk from '@/utils/musicSdk'
import { toNewMusicInfo, toOldMusicInfo } from '@/utils'

const SOURCES = ['kw', 'kg', 'tx', 'wy', 'mg']

const unwrap = async (value) => {
  if (value && typeof value.promise?.then === 'function') return await value.promise
  return await value
}

// The SDK returns the legacy LX music-info shape.  The original app converts
// it in store/search/music, store/songlist and store/leaderboard before the UI
// sees it; we must do the same or every song loses its id/meta.
const normalizeSongs = (result) => {
  if (!result || !Array.isArray(result.list)) return result
  return {
    ...result,
    list: result.list.map((item) => toNewMusicInfo(item)),
  }
}

const moduleOf = (source, name) => {
  const mod = musicSdk[source]
  if (!mod) throw new Error(`source not supported: ${source}`)
  const target = mod[name]
  if (!target) throw new Error(`action not supported: ${source}.${name}`)
  return target
}

const searchMusic = async ({ source = 'kw', keyword = '', page = 1, limit } = {}) => {
  if (!keyword.trim()) return { list: [], total: 0, page, limit: limit ?? 30, allPage: 0, source }
  if (source === 'all') {
    const results = await Promise.all(SOURCES.map(async (id) => {
      const mod = musicSdk[id]?.musicSearch
      if (!mod) return null
      try {
        return normalizeSongs(await mod.search(keyword, page, limit ?? mod.limit ?? 30))
      } catch (_) {
        return null
      }
    }))
    const valid = results.filter(Boolean)
    return {
      list: valid.flatMap((item) => item.list ?? []),
      total: valid.reduce((sum, item) => sum + (item.total ?? 0), 0),
      page,
      limit: limit ?? 30,
      allPage: valid.length ? Math.max(...valid.map((item) => item.allPage ?? 1)) : 0,
      source: 'all',
    }
  }
  return normalizeSongs(
    await moduleOf(source, 'musicSearch').search(keyword, page, limit ?? 30),
  )
}

const searchSonglist = async ({ source = 'kw', keyword = '', page = 1, limit } = {}) => {
  if (!keyword.trim()) return { list: [], total: 0, page, limit: limit ?? 20, source }
  if (source === 'all') {
    const results = await Promise.all(SOURCES.map(async (id) => {
      const mod = musicSdk[id]?.songList
      if (!mod) return null
      try {
        return await mod.search(keyword, page, limit ?? 20)
      } catch (_) {
        return null
      }
    }))
    const valid = results.filter(Boolean)
    return {
      list: valid.flatMap((item) => item.list ?? []),
      total: valid.reduce((sum, item) => sum + (item.total ?? 0), 0),
      page,
      limit: limit ?? 20,
      source: 'all',
    }
  }
  return await moduleOf(source, 'songList').search(keyword, page, limit ?? 20)
}

const songlistTags = async ({ source = 'kw' } = {}) => {
  const mod = moduleOf(source, 'songList')
  if (typeof mod.getTags === 'function') return await mod.getTags()
  const tags = typeof mod.getTag === 'function' ? await mod.getTag() : []
  const hotTag = typeof mod.getHotTag === 'function' ? await mod.getHotTag() : []
  return { tags, hotTag, source }
}

const songlistSorts = ({ source = 'kw' } = {}) => {
  const mod = moduleOf(source, 'songList')
  return { list: mod.sortList ?? [], source }
}

const songlistList = async ({ source = 'kw', sortId = '', tagId = '', page = 1 } = {}) => {
  const mod = moduleOf(source, 'songList')
  const result = await mod.getList(sortId, tagId, page)
  return { ...result, source }
}

const songlistDetail = async ({ source = 'kw', id, page = 1 } = {}) => {
  if (!id) throw new Error('songlist id is required')
  const mod = moduleOf(source, 'songList')
  return normalizeSongs(await mod.getListDetail(id, page))
}

const leaderboards = async ({ source = 'kw' } = {}) => {
  const mod = moduleOf(source, 'leaderboard')
  return await mod.getBoards()
}

const leaderboardDetail = async ({ source = 'kw', id, page = 1 } = {}) => {
  if (!id) throw new Error('leaderboard id is required')
  const mod = moduleOf(source, 'leaderboard')
  // Board ids from the UI are `kw__93`, `kg__8888`, ... while the SDK's
  // getList() expects only the source-specific bang id.  This split used to
  // live in core/leaderboard.ts.
  const rawId = String(id)
  const bangId = rawId.includes('__') ? rawId.split('__').slice(1).join('__') : rawId
  return normalizeSongs(await mod.getList(bangId, page))
}

const hotSearch = async ({ source = 'kw' } = {}) => {
  const mod = musicSdk[source]?.hotSearch
  if (!mod) return { source, list: [] }
  return await mod.getList()
}

const tipSearch = async ({ keyword = '' } = {}) => {
  const mod = musicSdk.kw?.tipSearch
  if (!mod || !keyword.trim()) return []
  return await mod.search(keyword)
}

const lyric = async ({ source = 'kw', song } = {}) => {
  if (!song) throw new Error('song is required')
  const old = toOldMusicInfo(song)
  const mod = moduleOf(source, 'getLyric')
  return await unwrap(mod.call(musicSdk[source], old, true))
}

const pic = async ({ source = 'kw', song } = {}) => {
  if (!song) throw new Error('song is required')
  const old = toOldMusicInfo(song)
  const mod = moduleOf(source, 'getPic')
  return await unwrap(mod.call(musicSdk[source], old))
}

const musicDetailUrl = ({ source = 'kw', song } = {}) => {
  if (!song) return ''
  const old = toOldMusicInfo(song)
  const mod = musicSdk[source]
  return mod?.getMusicDetailPageUrl?.(old) ?? ''
}

const sourceList = () => ({ list: SOURCES })

const handlers = {
  searchMusic,
  searchSonglist,
  songlistTags,
  songlistSorts,
  songlistList,
  songlistDetail,
  leaderboards,
  leaderboardDetail,
  hotSearch,
  tipSearch,
  lyric,
  pic,
  musicDetailUrl,
  sourceList,
}

window.LXEngine = {
  dispatch(id, action, params) {
    const handler = handlers[action]
    if (!handler) {
      window.FlmBridge?.postMessage(JSON.stringify({
        type: 'engineError',
        id,
        message: `unknown action: ${action}`,
      }))
      return
    }
    Promise.resolve()
      .then(() => handler(params ?? {}))
      .then((data) => {
        window.FlmBridge?.postMessage(JSON.stringify({ type: 'engineResult', id, data }))
      })
      .catch((error) => {
        window.FlmBridge?.postMessage(JSON.stringify({
          type: 'engineError',
          id,
          message: String(error?.message ?? error),
          stack: String(error?.stack ?? ''),
        }))
      })
  },
}

window.__flmEngineReady = true
