// Prints an osv-scanner report for tests/run.sh, for the fake scanner to serve.
//
// Each argument is one finding, as a JSON object:
//   { lockfile, package, version, ecosystem, ids, aliases, score, fixed, gitFixed,
//     published, clean }
// `ids` may name several advisories, each with the matching entry of
// `published` when that is an array. `fixed` may be a list, and `gitFixed` is a
// commit in a GIT range. `clean` is a package with no finding, as --all-packages
// reports it. Anything left out takes the default below.
const DEFAULTS = {
  lockfile: 'package-lock.json',
  package: 'lodash',
  version: '4.17.15',
  ecosystem: 'npm',
  ids: ['GHSA-aaaa-aaaa-aaaa'],
  aliases: [],
  score: '8.1',
  published: '2021-02-15T13:15:00Z',
};

const results = process.argv.slice(2).map((argument) => {
  const finding = { ...DEFAULTS, ...JSON.parse(argument) };
  const published = [finding.published].flat();
  const pkg = { name: finding.package, version: finding.version, ecosystem: finding.ecosystem };
  const source = { path: `@DIR@/${finding.lockfile}`, type: 'lockfile' };
  if (finding.clean) return { source, packages: [{ package: pkg }] };
  return {
    source,
    packages: [
      {
        package: pkg,
        groups: [
          {
            ids: finding.ids,
            aliases: finding.aliases,
            max_severity: finding.score,
          },
        ],
        vulnerabilities: finding.ids.map((id, index) => ({
          id,
          published: published[index] ?? published[0],
          affected: [
            {
              package: { ecosystem: finding.ecosystem, name: finding.package },
              ranges: [
                {
                  type: 'SEMVER',
                  events: [{ introduced: '0' }, ...[finding.fixed ?? []].flat().map((fixed) => ({ fixed }))],
                },
                ...(finding.gitFixed
                  ? [{ type: 'GIT', events: [{ introduced: '0' }, { fixed: finding.gitFixed }] }]
                  : []),
              ],
            },
          ],
        })),
      },
    ],
  };
});

console.log(JSON.stringify({ results }, null, 2));
