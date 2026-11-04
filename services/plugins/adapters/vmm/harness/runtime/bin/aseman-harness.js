#!/usr/bin/env node
/**
 * Starts Aseman's agent runtime: DeepSeek Harness (dsh) as a long-lived host
 * running the `aseman` profile (the shipped `sdk` template plus Aseman's patch
 * layer, lib/profile.js). dsh's home, Sessions and indexes live under
 * $ASEMAN_DATA_DIR. The process exits when dsh does; the node restarts it.
 */

import { spawn, spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { readConfig } from '../lib/config.js'
import { buildPatch, TOKEN_ENV } from '../lib/profile.js'

const PROFILE = 'aseman'

function dshBinary() {
  if (process.env.ASEMAN_DSH_BIN) return process.env.ASEMAN_DSH_BIN
  const require = createRequire(import.meta.url)
  const pkgPath = require.resolve('@deepseek-ai/dsh/package.json')
  const pkg = require(pkgPath)
  const bin = typeof pkg.bin === 'string' ? pkg.bin : pkg.bin?.dsh
  if (!bin) throw new Error('the installed @deepseek-ai/dsh has no dsh binary')
  return resolve(dirname(pkgPath), bin)
}

function runSync(bin, args, env) {
  const isJs = bin.endsWith('.js') || bin.endsWith('.mjs')
  const done = spawnSync(isJs ? process.execPath : bin, isJs ? [bin, ...args] : args, { env, encoding: 'utf8', timeout: 180_000 })
  return done
}

/** Row ids the installed dsh's `aseman` profile composes (rows differ by release). */
function availableRows(bin, env) {
  const done = runSync(bin, ['--profile', PROFILE, '--dump-default-config'], env)
  if (done.status !== 0) return undefined
  const ids = new Set([...String(done.stdout).matchAll(/^\s*-?\s*id:\s*([A-Za-z0-9_.-]+)\s*$/gm)].map((m) => m[1]))
  return ids.size ? ids : undefined
}

function main() {
  const config = readConfig()
  if (!config.gateway) throw new Error('ASEMAN_GATEWAY_URL is required')
  if (!config.secret) throw new Error('ASEMAN_RUNTIME_SECRET is required')
  const home = join(config.dataDir, 'home')
  const dshHome = join(config.dataDir, 'dsh')
  mkdirSync(home, { recursive: true })
  mkdirSync(dshHome, { recursive: true })
  const env = {
    ...process.env,
    HOME: home,
    DSH_HOME: dshHome,
    XDG_CONFIG_HOME: join(home, '.config'),
    XDG_DATA_HOME: join(home, '.local', 'share'),
    XDG_STATE_HOME: join(home, '.local', 'state'),
    // Nothing leaves the node from an agent turn.
    DSH_TELEMETRY_DISABLED: '1',
    DO_NOT_TRACK: '1',
    // The route's key slot; each request is authorized by its turn's token.
    [TOKEN_ENV]: 'aseman-turn',
  }
  const bin = dshBinary()
  if (!existsSync(join(dshHome, 'profiles', PROFILE))) {
    const init = runSync(bin, ['--profile', PROFILE, '--from-default-profile', 'sdk', '--help'], env)
    if (init.status !== 0) throw new Error(`creating the ${PROFILE} profile failed: ${init.stderr || init.stdout}`)
  }
  const patchPath = join(config.dataDir, 'aseman.patch.yml')
  const rows = buildPatch(config, availableRows(bin, env))
  writeFileSync(patchPath, `# Aseman profile layer (generated at start)\n${JSON.stringify(rows, null, 2)}\n`, { mode: 0o600 })

  const isJs = bin.endsWith('.js') || bin.endsWith('.mjs')
  const args = ['--profile', PROFILE, '--patch', patchPath]
  const child = spawn(isJs ? process.execPath : bin, isJs ? [bin, ...args] : args, {
    env,
    cwd: config.dataDir,
    stdio: ['ignore', 'inherit', 'inherit'],
  })
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => child.kill(sig))
  child.on('exit', (code, signal) => process.exit(code ?? (signal ? 1 : 0)))
}

try {
  main()
} catch (error) {
  console.error(`aseman-harness: ${error?.message ?? error}`)
  process.exit(1)
}
