import type { Register } from 'claude-code'
import { historyLine, historyPath, readOptions, readingOf, readingPath } from './limits'

let sessionId = ''
let path: string | null = null
let historyFile: string | null = null
let history: string[] = []

export const register: Register = (on, options) => {
  const opts = readOptions(options)

  on('session.start', async ($, e, next) => {
    sessionId = await $.session.id()
    const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))
    path = readingPath(home)
    historyFile = historyPath(home, sessionId)
    // A reload starts the module over; the session's file is where its earlier readings live.
    history = []
    if (historyFile !== null && (await $.fs.exists(historyFile))) {
      history = (await $.fs.read(historyFile)).split('\n').filter((line) => line !== '')
    }
    return next(e)
  })

  // Fires after each main-thread turn and whenever a window moves a whole point. The whole file is rewritten each time, last writer
  // wins, so it names whichever account the latest session on this machine ran on and `measured_at` dates it. The session's history
  // gains a line only when a window moved. A failed write is dropped: a readout never touches the session, and the launch line says
  // when the file is stale or missing.
  on('session.measure', async ($, e, next) => {
    if (opts.enabled && path !== null) {
      const now = await $.clock.now()
      const text = readingOf(e.rateLimits, sessionId, now)
      if (text !== null) {
        try {
          await $.fs.write(path, text)
        } catch {
          // see above
        }
      }
      const line = e.changed.includes('rateLimits') ? historyLine(e.rateLimits, now) : null
      if (line !== null && historyFile !== null) {
        history.push(line)
        try {
          await $.fs.write(historyFile, `${history.join('\n')}\n`)
        } catch {
          // see above
        }
      }
    }
    return next(e)
  })
}
