// Release history for the Changelog page. Fetches published GitHub releases at BUILD TIME and renders
// each release body (GFM markdown) to HTML with Astro's own markdown processor. Read-only; memoized
// per build. Falls back to an empty list if GitHub is unreachable (the page shows a notice).
import { createMarkdownProcessor } from '@astrojs/markdown-remark';

export interface Release {
  tag: string;
  name: string;
  iso: string;
  html: string;
  url: string;
  prerelease: boolean;
}

let cache: Release[] | undefined;
let processorPromise: ReturnType<typeof createMarkdownProcessor> | undefined;

function processor() {
  return (processorPromise ??= createMarkdownProcessor({ gfm: true }));
}

export async function getReleases(): Promise<Release[]> {
  if (cache) return cache;

  // Authenticated when GITHUB_TOKEN is present (CI) → 5000/hr instead of the anonymous 60/hr.
  const headers: Record<string, string> = { Accept: 'application/vnd.github+json', 'User-Agent': 'aerocheck-site-build' };
  const token = (globalThis as any).process?.env?.GITHUB_TOKEN;
  if (token) headers.Authorization = `Bearer ${token}`;

  let raw: any[] = [];
  try {
    const res = await fetch('https://api.github.com/repos/fetzu/AeroCheck/releases?per_page=100', { headers });
    if (res.ok) raw = await res.json();
  } catch { /* offline / rate-limited — page shows a notice */ }

  const md = await processor();
  const releases: Release[] = [];
  for (const r of raw) {
    if (r.draft) continue;
    const { code } = await md.render((r.body ?? '').trim() || '_No release notes._');
    releases.push({
      tag: String(r.tag_name ?? '').replace(/^v/i, ''),
      name: r.name || r.tag_name || '',
      iso: r.published_at ?? '',
      html: code,
      url: r.html_url ?? '',
      prerelease: Boolean(r.prerelease),
    });
  }

  cache = releases;
  return releases;
}
