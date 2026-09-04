// Rewrites the four figures inside assets/stats.svg from the live GitHub API.
// Only the numbers and the aria-label change; the artwork is untouched.
//
// Authentication is local-only: scripts/refresh-stats.ps1 reads a dedicated
// classic PAT from Windows Credential Manager and exposes it to this process as
// STATS_TOKEN. GitHub requires the classic read:user scope for private/internal
// contribution data; repo is also required to enumerate owned private repos.

import { readFileSync, writeFileSync } from 'node:fs';

const LOGIN = 'QuickkNastyy';
const SVG = 'assets/stats.svg';
const token = process.env.STATS_TOKEN;
if (!token) throw new Error('no token: run scripts/refresh-stats.ps1 (token is stored in Windows Credential Manager)');

const request = async (url, init = {}) => {
  const res = await fetch(url, {
    ...init,
    headers: {
      authorization: `Bearer ${token}`,
      accept: 'application/vnd.github+json',
      'user-agent': `${LOGIN}-profile-stats`,
      ...init.headers,
    },
  });
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status} ${await res.text()}`);
  return res;
};

const api = async (url, init = {}) => (await request(url, init)).json();

// Verify identity and classic scopes before reading or writing any stats.
// Fine-grained PATs do not expose the classic read:user scope GitHub documents
// as required for private/internal ContributionsCollection data.
const authRes = await request('https://api.github.com/user');
const authUser = await authRes.json();
if (authUser.login !== LOGIN) {
  throw new Error(`token belongs to ${authUser.login || 'an unknown user'}, expected ${LOGIN}`);
}
const scopes = (authRes.headers.get('x-oauth-scopes') || '')
  .split(',')
  .map((scope) => scope.trim())
  .filter(Boolean);
for (const required of ['repo', 'read:user']) {
  if (!scopes.includes(required)) {
    throw new Error(`STATS_TOKEN is missing required classic PAT scope: ${required}`);
  }
}

// ---- contributions (rolling last 12 months) ----
const gql = await api('https://api.github.com/graphql', {
  method: 'POST',
  body: JSON.stringify({
    query: `query($login:String!){
      user(login:$login){
        contributionsCollection{
          contributionCalendar{ totalContributions }
          totalCommitContributions
          restrictedContributionsCount
          hasAnyRestrictedContributions
          commitContributionsByRepository(maxRepositories:100){
            repository{ isPrivate }
            contributions(first:1){ totalCount }
          }
        }
      }
    }`,
    variables: { login: LOGIN },
  }),
});
if (gql.errors) throw new Error(JSON.stringify(gql.errors));
const cc = gql.data?.user?.contributionsCollection;
if (!cc) throw new Error('GitHub did not return a contributions collection');

const contributions = cc.contributionCalendar.totalContributions;
// totalCommitContributions is already GitHub's commit total. Do not add
// restrictedContributionsCount: that field can include non-commit contributions.
const commits = cc.totalCommitContributions;
const privateCommitContributions = cc.commitContributionsByRepository
  .filter((entry) => entry.repository.isPrivate)
  .reduce((sum, entry) => sum + entry.contributions.totalCount, 0);

// ---- repositories + stars ----
// GET /user/repos includes owned private repositories with repo scope.
const repos = [];
for (let page = 1; ; page += 1) {
  if (page > 100) throw new Error('repository pagination exceeded safety limit');
  const batch = await api(`https://api.github.com/user/repos?per_page=100&affiliation=owner&page=${page}`);
  if (!Array.isArray(batch)) throw new Error('GitHub returned an invalid repository list');
  repos.push(...batch);
  if (batch.length < 100) break;
}

const repositories = repos.length;
const privateRepositories = repos.filter((repo) => repo.private).length;
const stars = repos.reduce((sum, repo) => sum + repo.stargazers_count, 0);

const fetchedStats = { contributions, commits, repositories, stars };
console.log('fetched:', fetchedStats);
console.log('private visibility:', {
  privateRepositories,
  privateCommitContributions,
  restrictedContributions: cc.restrictedContributionsCount,
  hasRestrictedContributions: cc.hasAnyRestrictedContributions,
});

for (const [key, value] of Object.entries(fetchedStats)) {
  if (!Number.isFinite(value)) throw new Error(`bad value for ${key}: ${value}`);
}
if (contributions === 0 && commits === 0) {
  throw new Error('refusing to write all-zero stats; the token or contribution data is probably wrong');
}
if (privateRepositories === 0) {
  console.warn('warning: GitHub returned no owned private repositories; verify token access if that is unexpected');
}

// ---- rewrite the SVG ----
const fmt = (n) => n.toLocaleString('en-US');
let svg = readFileSync(SVG, 'utf8');
const before = svg;

// A successful refresh commit is authored to QuickkNastyy and therefore becomes
// one additional contribution and commit on the profile. When the card needs a
// refresh, include that imminent commit in the target values so the card settles
// after the push instead of being permanently one commit behind itself.
const readCurrentStat = (key) => {
  const re = new RegExp(`<text data-stat="${key}"[^>]*>([^<]*)</text>`);
  const match = svg.match(re);
  if (!match) throw new Error(`marker data-stat="${key}" not found in ${SVG}`);
  const value = Number(match[1].replace(/,/g, ''));
  if (!Number.isFinite(value)) throw new Error(`invalid existing value for ${key}: ${match[1]}`);
  return value;
};
const currentStats = Object.fromEntries(
  Object.keys(fetchedStats).map((key) => [key, readCurrentStat(key)]),
);
const fetchedMatchesCard = Object.entries(fetchedStats)
  .every(([key, value]) => currentStats[key] === value);
const anticipateCommit = process.env.STATS_ANTICIPATE_COMMIT === '1' && !fetchedMatchesCard;
const stats = anticipateCommit
  ? { ...fetchedStats, contributions: contributions + 1, commits: commits + 1 }
  : fetchedStats;
if (anticipateCommit) console.log('target includes expected refresh commit:', stats);

for (const [key, value] of Object.entries(stats)) {
  const re = new RegExp(`(<text data-stat="${key}"[^>]*>)([^<]*)(</text>)`);
  if (!re.test(svg)) throw new Error(`marker data-stat="${key}" not found in ${SVG}`);
  svg = svg.replace(re, `$1${fmt(value)}$3`);
}

svg = svg.replace(
  /(data-aria="1" aria-label=")[^"]*(")/,
  `$1${fmt(stats.contributions)} contributions, ${fmt(stats.commits)} commits, ${fmt(stats.repositories)} repositories, ${fmt(stats.stars)} stars earned in the last 12 months$2`,
);

if (svg === before) {
  console.log('no change');
  process.exit(0);
}
writeFileSync(SVG, svg);
console.log('updated', SVG);
