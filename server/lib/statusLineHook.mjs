#!/usr/bin/env node
/*
 * CHRISTOPHER'S STATUS-LINE HOOK — how a build learns its Claude usage and its
 * Claude limits without ever touching the Claude credential.
 *
 * Every Claude session Christopher starts is given this as its status line
 * (terminal.js launchFlags: a --settings file with statusLine.command). Claude
 * Code runs it after replies and every refreshInterval seconds, and writes a
 * JSON description of the session to its stdin. Two parts of that matter here:
 *
 *   rate_limits.five_hour / .seven_day  { used_percentage 0-100, resets_at s }
 *       Anthropic's OWN numbers for this Claude account, taken from headers on
 *       every reply — the same "Current session" and "Current week" Claude
 *       shows. They work for a `claude setup-token` login too, where the
 *       /api/oauth/usage endpoint refuses the token (it lacks user:profile).
 *   cost.total_cost_usd, cost.total_duration_ms
 *       The session process's running API-equivalent cost, computed by Claude
 *       Code from every API call it made — subagents and side calls included.
 *       NOT always from 0: on --resume Claude Code restores the total saved in
 *       the transcript at the last graceful exit. So the first value a process
 *       reports is its BASE, and only growth above it is this process's usage.
 *
 * ONE FILE PER LAUNCH. Christopher passes four arguments in the command:
 *   <launchId> <crmUserId|-> <crmOrgId|-> <subscriptionKey|->
 * launchId is fresh for every spawn, so two processes on the same session id
 * (a pane and an external window, say) never share a file or a baseline, and the
 * person who STARTED the session is recorded with every reading — the usage is
 * theirs even if someone else is signed in by the time it is read.
 *
 * WHICH CLAUDE ACCOUNT. The status-line JSON carries the account's limits but
 * not WHICH account they belong to. The 4th argument says it: the id of the
 * CRM-assigned Claude subscription whose token this session runs on, or '-'
 * for the build's own login (an older command line has no 4th argument at
 * all, which means the same). Every cost snapshot carries it as
 * subscriptionKey ('' for the build's own login), and limits are kept PER
 * SUBSCRIPTION — limits/<subscription id>.json, or limits/_local.json for the
 * build's own login — so two sessions on two subscriptions never overwrite
 * each other's percentages.
 *
 * This script only WRITES SNAPSHOTS into the build's usage folder (COS_USAGE_DIR,
 * under the secrets root). It sends nothing anywhere. usageReporter.js reads the
 * snapshots, turns them into per-hour increments for whoever is signed in, and
 * reports them to the CRM. Keeping the network out of this script matters: it
 * runs on every status refresh, and Claude Code waits for its output.
 *
 * AND IT STILL HAS TO BE A STATUS LINE. Christopher's --settings replaces the
 * person's own statusLine for these sessions, so if they had one, it is chained:
 * its command arrives base64-encoded in COS_STATUSLINE_CHAIN, is run with the
 * same stdin, and its output is what gets printed. Without one, a short line of
 * our own: model · 5-hour % · week %.
 *
 * Rules for this file: never throw, never hang (Claude Code is waiting), never
 * write outside COS_USAGE_DIR, and never read or write any credential.
 */

import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'

const SESSION_ID_RE = /^[A-Za-z0-9-]{8,64}$/
const LAUNCH_ID_RE = /^[A-Za-z0-9]{8,64}$/
const OWNER_ID_RE = /^[A-Za-z0-9-]{1,64}$/
/* A subscription id is the CRM's uuid. It names a file below, so nothing else
   is accepted as one — anything else is the build's own login. */
const SUBSCRIPTION_KEY_RE = /^[0-9a-f-]{36}$/i
const LOCAL_LIMITS = '_local'
const CHAIN_TIMEOUT_MS = 3000

const [argLaunch, argUser, argOrg, argSub] = process.argv.slice(2)
const LAUNCH_ID = LAUNCH_ID_RE.test(argLaunch ?? '') ? argLaunch : null
const OWNER_USER = OWNER_ID_RE.test(argUser ?? '') && argUser !== '-' ? argUser : null
const OWNER_ORG = OWNER_ID_RE.test(argOrg ?? '') && argOrg !== '-' ? argOrg : null
const SUBSCRIPTION_KEY = SUBSCRIPTION_KEY_RE.test(argSub ?? '') ? argSub.toLowerCase() : ''

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8')
  } catch {
    return ''
  }
}

function atomicWrite(file, value) {
  const tmp = `${file}.tmp-${process.pid}`
  fs.writeFileSync(tmp, JSON.stringify(value), { encoding: 'utf8', mode: 0o600 })
  fs.renameSync(tmp, file)
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

/* used_percentage is 0-100 with one decimal. A known Claude Code bug has put
   the resets_at epoch in it (#60263), so anything above 101 is not a percent. */
function window(w) {
  if (!w || typeof w !== 'object') return null
  const pct = Number(w.used_percentage)
  const resetsS = Number(w.resets_at)
  if (!Number.isFinite(resetsS) || resetsS <= 0) return null
  return {
    percent: Number.isFinite(pct) && pct >= 0 && pct <= 101 ? pct : null,
    resetsAt: new Date(resetsS * 1000).toISOString(),
  }
}

function record(input) {
  const dir = process.env.COS_USAGE_DIR
  if (!dir) return
  const now = new Date().toISOString()
  fs.mkdirSync(path.join(dir, 'sessions'), { recursive: true })

  const sessionId = typeof input.session_id === 'string' && SESSION_ID_RE.test(input.session_id) ? input.session_id : null
  const cost = Number(input?.cost?.total_cost_usd)
  const duration = Number(input?.cost?.total_duration_ms)
  if (sessionId && LAUNCH_ID && Number.isFinite(cost) && cost >= 0) {
    const file = path.join(dir, 'sessions', `${sessionId}.${LAUNCH_ID}.json`)
    const durationMs = Number.isFinite(duration) && duration >= 0 ? duration : null
    let prev = null
    try {
      prev = JSON.parse(fs.readFileSync(file, 'utf8'))
    } catch {
      prev = null
    }
    /* Same process as the last reading if nothing went backwards. Otherwise
       this is a new process under the same launch (the `--resume || --session-id`
       fallback runs two): its first value is a new base. */
    const sameProcess =
      prev && Number.isFinite(prev.costUsd) && Number.isFinite(prev.baseCostUsd) && cost >= prev.costUsd &&
      (durationMs === null || !Number.isFinite(prev.durationMs) || durationMs >= prev.durationMs)
    atomicWrite(file, {
      sessionId,
      launchId: LAUNCH_ID,
      proc: sameProcess ? prev.proc : (Number(prev?.proc) || 0) + 1,
      at: now,
      costUsd: cost,
      baseCostUsd: sameProcess ? prev.baseCostUsd : cost,
      durationMs,
      userId: OWNER_USER,
      orgId: OWNER_ORG,
      subscriptionKey: SUBSCRIPTION_KEY,
      model: typeof input?.model?.id === 'string' ? input.model.id.slice(0, 80) : null,
      effort: typeof input?.effort?.level === 'string' ? input.effort.level.slice(0, 20) : null,
      projectId: process.env.COS_PROJECT_ID || null,
    })
  }

  const rl = input?.rate_limits
  if (rl && typeof rl === 'object') {
    const fiveHour = window(rl.five_hour)
    const week = window(rl.seven_day)
    if (fiveHour || week) {
      const extra = {}
      for (const [k, v] of Object.entries(rl)) {
        if (k !== 'five_hour' && k !== 'seven_day' && v && typeof v === 'object') extra[k] = v
      }
      /* One file per Claude account — see "WHICH CLAUDE ACCOUNT" above. */
      const limitsDir = path.join(dir, 'limits')
      fs.mkdirSync(limitsDir, { recursive: true })
      const file = path.join(limitsDir, `${SUBSCRIPTION_KEY || LOCAL_LIMITS}.json`)
      let prev = readJson(file)
      /* Before subscriptions, the build's own login had a single limits.json
         (every session ran on it then). Its last reading carries over into
         _local.json — the merge keeps a window until its own reset — and the
         old file goes, so nothing goes on forwarding a frozen copy of it. */
      const legacy = SUBSCRIPTION_KEY ? null : path.join(dir, 'limits.json')
      if (legacy && fs.existsSync(legacy)) {
        if (!prev) prev = readJson(legacy)
        try {
          fs.unlinkSync(legacy)
        } catch {
          /* another session's hook got there first */
        }
      }
      atomicWrite(file, {
        at: now,
        sessionId,
        subscriptionKey: SUBSCRIPTION_KEY,
        fiveHour: merge(fiveHour, prev?.fiveHour),
        week: merge(week, prev?.week),
        ...(Object.keys(extra).length ? { extra } : {}),
      })
    }
  }
}

/* PER-WINDOW MERGE. Claude Code reports each window independently — one can be
   missing while the other is present, and a window is dropped from the payload
   once its reset passes. Writing a reading as-is would let a reading that only
   carries the 5-hour window erase a perfectly good weekly one. So: a fresh
   window wins; a missing one keeps the previous value until that previous
   window's own reset time has passed; and a fresh window whose percent was
   rejected (the epoch bug) keeps the previous percent when it describes the
   same window (same reset). */
function merge(next, prev) {
  const prevLive = prev && typeof prev.resetsAt === 'string' && Date.parse(prev.resetsAt) > Date.now() ? prev : null
  if (!next) return prevLive
  if (next.percent === null && prevLive && prevLive.resetsAt === next.resetsAt) {
    return { ...next, percent: prevLive.percent ?? null }
  }
  return next
}

/* The shell Claude Code itself would run a status line in: Git Bash on Windows
   when it is installed (PowerShell otherwise), bash elsewhere. A person's own
   status line is written for THAT shell — cmd.exe, which `shell: true` means
   on Windows, breaks `input=$(cat)` and every .sh script. */
function chainShell() {
  if (process.platform !== 'win32') {
    return fs.existsSync('/bin/bash') ? { file: '/bin/bash', args: ['-c'], bash: true } : { file: '/bin/sh', args: ['-c'], bash: false }
  }
  const candidates = [
    process.env.CLAUDE_CODE_GIT_BASH_PATH,
    path.join(process.env.ProgramFiles || 'C:/Program Files', 'Git', 'bin', 'bash.exe'),
    path.join(process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)', 'Git', 'bin', 'bash.exe'),
    process.env.LOCALAPPDATA ? path.join(process.env.LOCALAPPDATA, 'Programs', 'Git', 'bin', 'bash.exe') : null,
  ].filter(Boolean)
  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) return { file: c, args: ['-c'], bash: true }
    } catch {
      /* next */
    }
  }
  return { file: 'powershell.exe', args: ['-NoProfile', '-NonInteractive', '-Command'], bash: false }
}

function chained(raw) {
  const enc = process.env.COS_STATUSLINE_CHAIN
  if (!enc) return null
  let command = ''
  try {
    command = Buffer.from(enc, 'base64').toString('utf8')
  } catch {
    return null
  }
  if (!command.trim()) return null
  const sh = chainShell()
  // Claude Code runs a .sh status line through bash explicitly; so do we.
  if (sh.bash && /^\S+\.sh(\s|$)/.test(command.trim())) command = `bash ${command.trim()}`
  const r = spawnSync(sh.file, [...sh.args, command], {
    input: raw,
    encoding: 'utf8',
    timeout: CHAIN_TIMEOUT_MS,
    windowsHide: true,
  })
  if (r.error || r.status !== 0) return null
  return typeof r.stdout === 'string' ? r.stdout.replace(/\s+$/, '') : null
}

function ownLine(input) {
  const parts = []
  const model = input?.model?.display_name || input?.model?.id
  if (model) parts.push(String(model))
  const five = window(input?.rate_limits?.five_hour)
  const week = window(input?.rate_limits?.seven_day)
  if (five?.percent != null) parts.push(`5h ${Math.floor(five.percent)}%`)
  if (week?.percent != null) parts.push(`week ${Math.floor(week.percent)}%`)
  return parts.join(' · ')
}

const raw = readStdin()
let input = {}
try {
  input = raw ? JSON.parse(raw) : {}
} catch {
  input = {}
}
try {
  record(input)
} catch {
  /* a status line must never fail because the usage folder did */
}
let line = null
try {
  line = chained(raw)
} catch {
  line = null
}
if (line === null) line = ownLine(input)
process.stdout.write(line ? `${line}\n` : '\n')
