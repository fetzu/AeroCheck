// Release history for the Changelog page. Fetches published GitHub releases at BUILD TIME and renders
// each release body (GFM markdown) to HTML with Astro's own markdown processor. Read-only; memoized
// per build. Falls back to an empty list if GitHub is unreachable (the page shows a notice).
//
// S9-15: a release body comes from anyone with release-publish rights on the app repo, and the HTML
// below is injected with `set:html` in Changelog.astro with no other review gate — publishing a
// release auto-deploys this site. Rendering it safely closes two vectors, neither of which any of the
// 24 releases published so far actually use (see the WEB-1 PR description for the before/after diff):
//   1. Raw HTML embedded in the markdown source (`<script>`, `<img onerror=…>`, …) — `remarkRehype:
//      { allowDangerousHtml: false }` tells mdast-util-to-hast to drop embedded HTML nodes outright
//      instead of the default astro config (`allowDangerousHtml: true` end to end via rehype-raw /
//      rehype-stringify) which would render it verbatim.
//   2. A dangerous URL scheme on an ordinary markdown link/image (`[x](javascript:…)`) — `sanitizeUrls`
//      below strips any `<a href>` / `<img src>` that isn't http(s).
import { createMarkdownProcessor } from '@astrojs/markdown-remark';

export interface Release {
  tag: string;
  name: string;
  iso: string;
  html: string;
  url: string;
  prerelease: boolean;
}

// Minimal hast shape — just enough to walk the tree; avoids adding a dependency on @types/hast (only
// present transitively today) for what's a handful of lines.
interface HastNode {
  type?: string;
  tagName?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
}

const URL_ATTR_BY_TAG: Record<string, string> = { a: 'href', img: 'src' };

function sanitizeUrls() {
  return (tree: HastNode) => {
    const walk = (node: HastNode) => {
      if (node.type === 'element' && node.tagName) {
        const attr = URL_ATTR_BY_TAG[node.tagName];
        const value = attr ? node.properties?.[attr] : undefined;
        if (attr && typeof value === 'string' && !/^https?:\/\//i.test(value)) {
          delete node.properties![attr];
        }
      }
      node.children?.forEach(walk);
    };
    walk(tree);
  };
}

let cache: Release[] | undefined;
let processorPromise: ReturnType<typeof createMarkdownProcessor> | undefined;

function processor() {
  return (processorPromise ??= createMarkdownProcessor({
    gfm: true,
    remarkRehype: { allowDangerousHtml: false },
    rehypePlugins: [sanitizeUrls],
  }));
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
