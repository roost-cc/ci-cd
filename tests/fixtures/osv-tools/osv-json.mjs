// Prints an osv-scanner report for tests/run.sh, for the fake scanner to serve.
//
// Each argument is one finding, as a JSON object:
//   { lockfile, package, version, ecosystem, ids, aliases, score, fixed, published }
// `ids` may name several advisories, each with the matching entry of
// `published` when that is an array. Anything left out takes the default below.
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
  return {
    source: { path: `@DIR@/${finding.lockfile}`, type: 'lockfile' },
    packages: [
      {
        package: {
          name: finding.package,
          version: finding.version,
          ecosystem: finding.ecosystem,
        },
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
                  events: [{ introduced: '0' }, ...(finding.fixed ? [{ fixed: finding.fixed }] : [])],
                },
              ],
            },
          ],
        })),
      },
    ],
  };
});

console.log(JSON.stringify({ results }, null, 2));
