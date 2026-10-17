import type { Register } from 'claude-code'
import { accountOf, configPath, historyLine, historyPath, readOptions, readingOf, readingPath, rotationDirs, statusText, weeklyResetOf } from './limits'

let sessionId = ''
let path: string | null = null
let historyFile: string | null = null
let history: string[] = []
let configFile: string | null = null
let rotating = false
let account: string | null = null
let weeklyReset: string | null = null

type Host = { fs: { exists(p: string): Promise<boolean>; read(p: string): Promise<string> } }

async function readAccount($: Host): Promise<string | null> {
  if (configFile === null) return null
  try {
    return (await $.fs.exists(configFile)) ? accountOf(await $.fs.read(configFile)) : null
  } catch {
    return null
  }
}

export const register: Register = (on, options) => {
  const opts = readOptions(options)

  on('session.start', async ($, e, next) => {
    sessionId = await $.session.id()
    const home = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))
    path = readingPath(home)
    historyFile = historyPath(home, sessionId)
    configFile = configPath(home, await $.env.get('CLAUDE_CONFIG_DIR'))
    // A reload starts the module over; the session's file is where its earlier readings live.
    history = []
    if (historyFile !== null && (await $.fs.exists(historyFile))) {
      history = (await $.fs.read(historyFile)).split('\n').filter((line) => line !== '')
    }
    rotating = false
    for (const dir of rotationDirs(home, await $.env.get('XDG_DATA_HOME'))) {
      if (await $.fs.exists(dir)) {
        rotating = true
        break
      }
    }
    account = await readAccount($)
    weeklyReset = null
    if (opts.enabled && opts.status && rotating) $.ui.status(statusText(account, []))
    return next(e)
  })

  // Fires after each main-thread turn and whenever a window moves a whole point. The whole file is rewritten each time, last writer
  // wins, so it names whichever account the latest session on this machine ran on and `measured_at` dates it. The session's history
  // gains a line only when a window moved, or when the login moved under the session. A failed write is dropped: a readout never
  // touches the session, and the launch line says when the file is stale or missing.
  on('session.measure', async ($, e, next) => {
    if (opts.enabled && path !== null) {
      const now = await $.clock.now()
      let switchedFrom: string | null = null
      if (e.rateLimits.length > 0) {
        // The identity file is re-read only when the reading's weekly reset moved (a switch, or the week rolling over) or no
        // identity is known yet, so a turn costs no file read in the steady state.
        const reset = weeklyResetOf(e.rateLimits)
        if (reset !== weeklyReset || account === null) {
          const seen = await readAccount($)
          if (seen !== null && account !== null && seen !== account) switchedFrom = account
          if (seen !== null) account = seen
          weeklyReset = reset
        }
      }
      const text = readingOf(e.rateLimits, sessionId, now, account)
      if (text !== null) {
        try {
          await $.fs.write(path, text)
        } catch {
          // see above
        }
      }
      const line = e.changed.includes('rateLimits') || switchedFrom !== null ? historyLine(e.rateLimits, now, account, switchedFrom) : null
      if (line !== null && historyFile !== null) {
        history.push(line)
        try {
          await $.fs.write(historyFile, `${history.join('\n')}\n`)
        } catch {
          // see above
        }
      }
      // Pinned under the prompt only on a machine that rotates accounts; everywhere else the mod stays silent, so a single-account
      // user sees no change. Not a statusLine command: configuring one of those removes the footer's keyboard hints for everyone.
      if (opts.status && rotating && e.rateLimits.length > 0) $.ui.status(statusText(account, e.rateLimits))
    }
    return next(e)
  })
}
