import type { Register } from 'claude-code'
import { readOptions, readingOf, readingPath } from './limits'

let sessionId = ''
let path: string | null = null

export const register: Register = (on, options) => {
  const opts = readOptions(options)

  on('session.start', async ($, e, next) => {
    sessionId = await $.session.id()
    path = readingPath((await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')))
    return next(e)
  })

  // Fires after each main-thread turn and whenever a window moves a whole point. The whole file is rewritten each time, last writer
  // wins, so it names whichever account the latest session on this machine ran on and `measured_at` dates it. A failed write is
  // dropped: a readout never touches the session, and the launch line says when the file is stale or missing.
  on('session.measure', async ($, e, next) => {
    if (opts.enabled && path !== null) {
      const text = readingOf(e.rateLimits, sessionId, await $.clock.now())
      if (text !== null) {
        try {
          await $.fs.write(path, text)
        } catch {
          // see above
        }
      }
    }
    return next(e)
  })
}
