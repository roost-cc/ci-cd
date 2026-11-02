// Preloaded with NODE_OPTIONS=--import for tests/run.sh: the fake registry.
//
//   FAKE_REGISTRY      JSON file, { "<url>": <the answer> }. Any other url is a 503.
//   FAKE_REGISTRY_LOG  append each requested url to this file
import { appendFileSync, readFileSync } from 'node:fs';

const answers = JSON.parse(readFileSync(process.env.FAKE_REGISTRY, 'utf8'));

globalThis.fetch = async (url) => {
  appendFileSync(process.env.FAKE_REGISTRY_LOG, `${url}\n`);
  if (!Object.hasOwn(answers, url)) return new Response('', { status: 503 });
  return new Response(JSON.stringify(answers[url]));
};
