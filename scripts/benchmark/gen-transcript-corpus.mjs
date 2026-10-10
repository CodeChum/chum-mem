// Synthetic Claude Code transcript corpus for importer checks (scripts/import-sessions.ts).
//   node scripts/benchmark/gen-transcript-corpus.mjs <out-root, path must contain "claude">   (MAIN_N=5000 makes the main transcript
//   parse slower than its subagents, which reproduced the subagent-first loss with --concurrency 2)
// then: pnpm sessions:import --roots <out-root> --allow-folders=-Users-tester-demo-repo --server <LOCAL stack> --project <new uuid> --yes
// Session A: main ($MAIN_N, default 200 events) + subagents/agent-a1 (15) + subagents/agent-a2 (25) = 240.
// Session B: main only (30 events). Session C: 20 events, 4 of them carry fake key-shaped strings.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
const root = process.argv[2];
const proj = join(root, '-Users-tester-demo-repo');
const base = Date.parse('2026-10-01T08:00:00Z');
let clock = 0;
function lines(sid, n, opts = {}) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const user = i % 2 === 0;
    const ts = new Date(base + (clock++) * 1000).toISOString();
    let text = `${opts.label ?? 'main'} turn ${i}: ${user ? 'question about the sample widget cache' : 'answer about the sample widget cache'}`;
    if (opts.secretAt && opts.secretAt[i]) text += ' ' + opts.secretAt[i];
    out.push(JSON.stringify({
      type: user ? 'user' : 'assistant', uuid: randomUUID(), sessionId: sid, timestamp: ts, cwd: '/tmp/demo-repo',
      ...(opts.sidechain ? { isSidechain: true, agentId: opts.label } : {}),
      message: user ? { role: 'user', content: text } : { role: 'assistant', content: [{ type: 'text', text }] }
    }));
  }
  return out.join('\n') + '\n';
}
const A = process.env.SID_A ?? randomUUID(), B = process.env.SID_B ?? randomUUID(), C = process.env.SID_C ?? randomUUID();
mkdirSync(join(proj, A, 'subagents'), { recursive: true });
writeFileSync(join(proj, `${A}.jsonl`), lines(A, Number(process.env.MAIN_N ?? 200)));
writeFileSync(join(proj, A, 'subagents', 'agent-a1.jsonl'), lines(A, 15, { sidechain: true, label: 'a1' }));
writeFileSync(join(proj, A, 'subagents', 'agent-a2.jsonl'), lines(A, 25, { sidechain: true, label: 'a2' }));
writeFileSync(join(proj, `${B}.jsonl`), lines(B, 30));
// Fake key-shaped strings, built at run time so no real-looking literal sits in a file.
const fakeAnthropic = 'sk-' + 'ant-' + 'api03-' + 'FAKEFAKEFAKEFAKEFAKEFAKE0123';
const fakeDbUrl = 'postgres' + '://demo_user:' + 'notreal' + 'pw123@db.example.invalid:5432/demo';
const fakeAws = 'AKIA' + 'FAKEFAKEFAKEFAKE';
writeFileSync(join(proj, `${C}.jsonl`), lines(C, 20, { label: 'c', secretAt: { 3: fakeAnthropic, 7: `DATABASE_URL=${fakeDbUrl}`, 8: fakeDbUrl, 12: fakeAws } }));
console.log(JSON.stringify({ A, B, C }));
