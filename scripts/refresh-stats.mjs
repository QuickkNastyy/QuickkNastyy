// Rewrites the four figures inside assets/stats.svg from the live GitHub API.
// Only the numbers and the aria-label change; the artwork is untouched.
//
// Token: prefers STATS_TOKEN (a PAT with read:user + repo) so private repos and
// private contributions are counted. Falls back to GITHUB_TOKEN, which can only
// see public activity and will therefore report lower figures.

import { readFileSync, writeFileSync } from 'node:fs';

const LOGIN = 'QuickkNastyy';
const SVG = 'assets/stats.svg';
const token = process.env.STATS_TOKEN || process.env.GITHUB_TOKEN;
if (!token) throw new Error('no token: set STATS_TOKEN or GITHUB_TOKEN');
const scoped = Boolean(process.env.STATS_TOKEN);

// GITHUB_TOKEN can only see public activity, so it reports far lower figures
// than a scoped PAT. Writing those would quietly downgrade a correct card.
// Leave the last good numbers in place instead.
if (!scoped) {
  console.log('STATS_TOKEN not set — skipping. A public-only token would lower');
  console.log('the figures rather than refresh them, so the card is left alone.');
  process.exit(0);
}

const api = async (url, init = {}) => {
  const res = await fetch(url, {
    ...init,
    headers: {
      authorization: `bearer ${token}`,
      accept: 'application/vnd.github+json',
      'user-agent': `${LOGIN}-profile-stats`,
      ...init.headers,
    },
  });
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status} ${await res.text()}`);
  return res.json();
};

// ---- contributions (last 12 months) ----
const gql = await api('https://api.github.com/graphql', {
  method: 'POST',
  body: JSON.stringify({
    query: `query($login:String!){
      user(login:$login){
        contributionsCollection{
          contributionCalendar{ totalContributions }
          totalCommitContributions
          restrictedContributionsCount
        }
      }
    }`,
    variables: { login: LOGIN },
  }),
});
if (gql.errors) throw new Error(JSON.stringify(gql.errors));
const cc = gql.data.user.contributionsCollection;
const contributions = cc.contributionCalendar.totalContributions;
const commits = cc.totalCommitContributions + cc.restrictedContributionsCount;

// ---- repositories + stars ----
// user/repos includes private ones when the token is scoped for it.
const endpoint = scoped
  ? 'https://api.github.com/user/repos?per_page=100&affiliation=owner'
  : `https://api.github.com/users/${LOGIN}/repos?per_page=100&type=owner`;
const repos = await api(endpoint);
const repositories = repos.length;
const stars = repos.reduce((n, r) => n + r.stargazers_count, 0);

const stats = { contributions, commits, repositories, stars };
console.log('fetched:', stats, scoped ? '(scoped token)' : '(public only)');

for (const [k, v] of Object.entries(stats)) {
  if (!Number.isFinite(v)) throw new Error(`bad value for ${k}: ${v}`);
}
if (contributions === 0 && commits === 0) {
  throw new Error('refusing to write all-zero stats; the token is probably wrong');
}

// ---- rewrite the SVG ----
const fmt = (n) => n.toLocaleString('en-US');
let svg = readFileSync(SVG, 'utf8');
const before = svg;

for (const [key, value] of Object.entries(stats)) {
  const re = new RegExp(`(<text data-stat="${key}"[^>]*>)([^<]*)(</text>)`);
  if (!re.test(svg)) throw new Error(`marker data-stat="${key}" not found in ${SVG}`);
  svg = svg.replace(re, `$1${fmt(value)}$3`);
}

svg = svg.replace(
  /(data-aria="1" aria-label=")[^"]*(")/,
  `$1${fmt(contributions)} contributions, ${fmt(commits)} commits, ${fmt(repositories)} repositories, ${fmt(stars)} stars earned in the last 12 months$2`
);

if (svg === before) {
  console.log('no change');
  process.exit(0);
}
writeFileSync(SVG, svg);
console.log('updated', SVG);
