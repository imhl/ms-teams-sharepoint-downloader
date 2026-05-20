const REPO = 'brendangooden/ms-teams-sharepoint-downloader';

export interface RepoStats {
  stars: number;
  forks: number;
}

let cached: Promise<RepoStats> | null = null;

export function getRepoStats(): Promise<RepoStats> {
  if (cached) return cached;
  cached = (async () => {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}`, {
        headers: {
          Accept: 'application/vnd.github+json',
          'User-Agent': 'teamsvideotranscriptexporter-site',
        },
      });
      if (!res.ok) throw new Error(`GitHub API ${res.status}`);
      const data: { stargazers_count?: number; forks_count?: number } = await res.json();
      return {
        stars: data.stargazers_count ?? 0,
        forks: data.forks_count ?? 0,
      };
    } catch {
      return { stars: 0, forks: 0 };
    }
  })();
  return cached;
}

export function formatCount(n: number): string {
  if (n < 1000) return String(n);
  return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
}
