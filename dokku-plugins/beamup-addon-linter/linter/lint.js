// Calls a deployed addon and lints its manifest with stremio-addon-linter
// https://github.com/Stremio/stremio-addon-linter
//
// Usage: node lint.js <base url>
//
// Nothing is printed: the output of this script reaches the user pushing the
// addon, and we do not disclose why an addon was rejected. The result is
// communicated through the exit code only.
//
// Exit codes: 0 the addon is valid, 1 the addon is invalid,
// 2 the linter could not run (a beamup problem, not the addon's)

const BASE_URL = process.argv[2]
const TIMEOUT_MS = 10000
const ATTEMPTS = 5
const RETRY_DELAY_MS = 3000

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// the app has only just started, so give it a few tries to come up
async function fetchManifest(url) {
	for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
		try {
			const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS) })
			if (!res.ok) throw new Error(`responded with HTTP ${res.status}`)
			return await res.json()
		} catch (err) {
			if (attempt === ATTEMPTS) throw err
			await sleep(RETRY_DELAY_MS)
		}
	}
}

async function main() {
	if (!BASE_URL) return 2

	// required here so a missing dependency is reported as a beamup problem
	// rather than as an invalid addon
	let lintManifest
	try {
		lintManifest = require('stremio-addon-linter').lintManifest
	} catch (err) {
		return 2
	}

	let manifest
	try {
		manifest = await fetchManifest(new URL('/manifest.json', BASE_URL).href)
	} catch (err) {
		// an addon that does not serve a manifest is not a valid addon
		return 1
	}

	return lintManifest(manifest).valid ? 0 : 1
}

main().then(
	(code) => process.exit(code),
	() => process.exit(2)
)
