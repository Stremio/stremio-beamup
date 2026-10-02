const assert = require('node:assert/strict')
const { spawnSync } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const root = path.resolve(__dirname, '..')
const { APP_TMPL, APP_DOCKER_TMPL } = require('./beamup-sync-swarm')

test('config survives export, transfer and both Swarm templates', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'beamup-config-'))
  const bin = path.join(home, 'bin')
  fs.mkdirSync(bin)
  const dokku = path.join(bin, 'dokku')
  fs.writeFileSync(dokku, `#!/bin/sh
if [ "$1" = 'config:keys' ]; then printf 'API_KEY\\nMULTILINE\\n'; exit; fi
if [ "$3" = 'API_KEY' ]; then printf 'abc $word: # quoted\\n'; exit; fi
if [ "$3" = 'MULTILINE' ]; then printf 'first\\nsecond\\n'; exit; fi
exit 1
`, { mode: 0o755 })
  const exported = spawnSync('node', [path.join(root, 'scripts/beamup-export-app-config'), 'owner-addon'], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` }, encoding: 'utf8'
  })
  assert.equal(exported.status, 0, exported.stderr)
  assert.deepEqual(JSON.parse(exported.stdout), { API_KEY: 'abc $word: # quoted', MULTILINE: 'first\nsecond' })

  const stored = spawnSync('node', [path.join(root, 'scripts/beamup-store-app-config'), 'owner-addon'], {
    env: { ...process.env, HOME: home }, input: exported.stdout, encoding: 'utf8'
  })
  assert.equal(stored.status, 0, stored.stderr)
  const file = path.join(home, '.beamup-app-config', 'owner-addon.json')
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)

  const oldHome = process.env.HOME
  process.env.HOME = home
  try {
    for (const template of [APP_TMPL, APP_DOCKER_TMPL]) {
      const yaml = template('owner-addon', 'image', 8001)
      assert.match(yaml, /API_KEY: "abc \$\$word: # quoted"/)
      assert.match(yaml, /MULTILINE: "first\\nsecond"/)
      assert.match(yaml, /PORT: "8001"/)
      assert.doesNotMatch(yaml, /- PORT=/)
    }
  } finally {
    process.env.HOME = oldHome
    fs.rmSync(home, { recursive: true, force: true })
  }
})
