// Resolves the app version shown in the footer at BUILD TIME (SSG). Prefers the latest published
// GitHub release (what users actually have), falls back to the local git tag, then a constant —
// so a build never fails just because it's offline or rate-limited. Memoized per build process.
const REPO = 'fetzu/AeroCheck';
const FALLBACK = '4.0.0';

let cached: string | undefined;

export async function appVersion(): Promise<string> {
  if (cached !== undefined) return cached;
  cached = await resolve();
  return cached;
}

async function resolve(): Promise<string> {
  // 1. Latest published GitHub release (robust in CI without git tags).
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'aerocheck-site-build' },
    });
    if (res.ok) {
      const tag = String((await res.json())?.tag_name ?? '').replace(/^v/i, '').trim();
      if (tag) return tag;
    }
  } catch { /* offline / rate-limited — fall through */ }

  // 2. Local git tag (works in a full checkout that has tags; worktrees share the repo's tags).
  try {
    const { execSync } = await import('node:child_process');
    const tag = execSync('git describe --tags --abbrev=0', { stdio: ['ignore', 'pipe', 'ignore'] })
      .toString().trim().replace(/^v/i, '');
    if (tag) return tag;
  } catch { /* no git / no tags — fall through */ }

  // 3. Last resort.
  return FALLBACK;
}
