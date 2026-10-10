import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, readFileSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { readdir, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, extname, join, resolve } from 'node:path';
import readline from 'node:readline';

type Provider = string;
type CanonicalEventType =
  | 'prompt'
  | 'response'
  | 'tool_call'
  | 'tool_result'
  | 'file_change'
  | 'command'
  | 'test_result'
  | 'summary'
  | 'error'
  | 'annotation'
  // v2.2.1: provider-specific semantic events. Stored with structured
  // content but hard-rejected at the claim extractor (belief gate).
  // See docs/research/v2.2.1-pckc/DESIGN.md §1.
  | 'reasoning'
  | 'turn_context'
  | 'agent_message';

interface ImportOptions {
  serverUrl: string;
  projectId: string;
  roots: string[];
  dryRun: boolean;
  from?: Date;
  to?: Date;
  maxFiles?: number;
  maxEventsPerSession?: number;
  concurrency: number;
  batchSize: number;
  fresh: boolean;
  /** Exact project-folder names to import (see --allow-folders). */
  allowFolders?: string[];
  allFolders: boolean;
  /** Import events that match the sensitive-content patterns (off by default). */
  includeSensitive: boolean;
}

interface SessionStartPayload {
  provider: Provider;
  projectId: string;
  externalSessionId: string;
  repo: {
    repoName?: string;
    branch?: string;
    commitSha?: string;
    filePaths: string[];
  };
  metadata: Record<string, unknown>;
}

interface SessionEventPayload {
  sessionId: string;
  eventId: string;
  idempotencyKey: string;
  provider: Provider;
  eventType: CanonicalEventType;
  eventTime: string;
  payload: Record<string, unknown>;
  rawPayload: Record<string, unknown>;
  /** v2.2.1: turn-graph identifier clustering events from one model step. */
  turnId?: string;
}

interface SessionEndPayload {
  sessionId: string;
  summary?: string;
  metadata: Record<string, unknown>;
  defer?: boolean;
}

interface ParsedSession {
  provider: Provider;
  externalSessionId: string;
  repo: SessionStartPayload['repo'];
  metadata: Record<string, unknown>;
  startedAt?: string;
  endedAt?: string;
  events: SessionEventPayload[];
  summary?: string;
}

interface ImportStats {
  filesDiscovered: number;
  filesProcessed: number;
  filesSkippedByDate: number;
  sessionsImported: number;
  eventsImported: number;
  sessionsFailed: number;
  sessionsDuplicate: number;
  eventsHeldSensitive: number;
  heldByPattern: Record<string, number>;
  elapsedMs: number;
}

const MAX_EVENT_STRING_CHARS = 200_000;
const DEFAULT_CONCURRENCY = 8;
const DEFAULT_BATCH_SIZE = 1000;
const LEGACY_DEFAULT_PROJECT_ID = '00000000-0000-0000-0000-000000000003';

function parseArgs(argv: string[]): ImportOptions {
  const args = new Map<string, string | boolean>();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token || (!token.startsWith('--') && token !== '-yes' && !token.startsWith('-'))) {
      continue;
    }
    // Support -yes shorthand
    if (token === '-yes' || token === '--yes') {
      args.set('--yes', true);
      continue;
    }
    if (!token.startsWith('--')) {
      continue;
    }
    const [key, inlineValue] = token.split('=', 2);
    if (inlineValue !== undefined) {
      args.set(key!, inlineValue);
      continue;
    }
    const next = argv[index + 1];
    if (!next || next.startsWith('--') || next.startsWith('-')) {
      args.set(key!, true);
      continue;
    }
    args.set(key!, next);
    index += 1;
  }

  const rootsRaw =
    stringArg(args, '--roots')
    ?? `${join(homedir(), '.codex', 'sessions')},${join(homedir(), '.claude', 'projects')},${join(homedir(), '.gemini', 'tmp')}`;

  const options: ImportOptions = {
    serverUrl: stringArg(args, '--server-url') ?? stringArg(args, '--server') ?? 'http://localhost:63001',
    projectId: defaultProjectId(args),
    roots: rootsRaw.split(',').map((value) => resolve(expandHome(value.trim()))).filter((value) => value.length > 0),
    dryRun: boolArg(args, '--dry-run'),
    concurrency: Number(stringArg(args, '--concurrency') ?? DEFAULT_CONCURRENCY),
    batchSize: Number(stringArg(args, '--batch-size') ?? DEFAULT_BATCH_SIZE),
    fresh: boolArg(args, '--fresh'),
    allFolders: boolArg(args, '--all-folders'),
    includeSensitive: boolArg(args, '--include-sensitive')
  };

  // Review 2026-10-09: the backfill glob `-Users-<you>-gradechum-gradechum*`
  // also matched sibling folders (the customer-bot project: 97.6% of the
  // imported sessions, with customer chat). Imports now need an explicit list
  // of project-folder names. Use the `=` form, because the folder names start
  // with "-": --allow-folders=-Users-me-gradechum-gradechum,-Users-me-gradechum-gradechum--wt-x
  const allowRaw = args.get('--allow-folders');
  if (allowRaw === true) {
    throw new Error('--allow-folders needs a value; use --allow-folders=<name>[,<name>…] (the = form, because folder names start with "-")');
  }
  if (typeof allowRaw === 'string') {
    options.allowFolders = allowRaw.split(',').map((value) => value.trim()).filter((value) => value.length > 0);
  }

  const from = stringArg(args, '--from');
  const to = stringArg(args, '--to');
  const maxFiles = stringArg(args, '--max-files');
  const maxEventsPerSession = stringArg(args, '--max-events');

  if (from) {
    options.from = new Date(from);
  }
  if (to) {
    options.to = new Date(to);
  }
  if (maxFiles) {
    options.maxFiles = Number(maxFiles);
  }
  if (maxEventsPerSession) {
    options.maxEventsPerSession = Number(maxEventsPerSession);
  }

  if (!options.dryRun && !boolArg(args, '--yes')) {
    throw new Error('Refusing non-dry-run execution without --yes. Run with --dry-run first.');
  }

  return options;
}

function stringArg(args: Map<string, string | boolean>, key: string): string | undefined {
  const value = args.get(key);
  return typeof value === 'string' ? value : undefined;
}

function boolArg(args: Map<string, string | boolean>, key: string): boolean {
  return args.get(key) === true;
}

function defaultProjectId(args: Map<string, string | boolean>): string {
  return (
    stringArg(args, '--project-id')
    ?? stringArg(args, '--project')
    ?? projectIdFromChumMem()
    ?? validProjectId(process.env.CHUM_MEM_PROJECT_ID)
    ?? LEGACY_DEFAULT_PROJECT_ID
  );
}

function projectIdFromChumMem(): string | undefined {
  try {
    const raw = readFileSync(join(process.cwd(), '.chum-mem'), 'utf8');
    const parsed = JSON.parse(raw) as { projectId?: unknown };
    return validProjectId(parsed.projectId);
  } catch {
    return undefined;
  }
}

function validProjectId(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(trimmed)
    ? trimmed
    : undefined;
}

function expandHome(input: string): string {
  if (input === '~') {
    return homedir();
  }
  if (input.startsWith('~/')) {
    return join(homedir(), input.slice(2));
  }
  return input;
}

// ─── File collection ────────────────────────────────────────────────

async function collectSessionFiles(
  roots: string[],
  allowFolders?: string[]
): Promise<{ files: string[]; skippedFolders: string[] }> {
  const files: string[] = [];
  const skippedFolders: string[] = [];

  async function walk(path: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(path, { withFileTypes: true });
    } catch {
      return;
    }

    const promises: Promise<void>[] = [];
    for (const entry of entries) {
      const fullPath = join(path, entry.name);
      if (entry.isDirectory()) {
        promises.push(walk(fullPath));
        continue;
      }
      if (entry.isFile() && (extname(entry.name) === '.jsonl' || extname(entry.name) === '.json') && !entry.name.includes('logs.json')) {
        files.push(fullPath);
      }
    }
    await Promise.all(promises);
  }

  if (!allowFolders) {
    await Promise.all(roots.map((root) => walk(root)));
  } else {
    // A root whose own name is allowed is walked whole; otherwise only its
    // immediate sub-folders whose names are listed exactly (no prefix match).
    const allowed = new Set(allowFolders);
    await Promise.all(roots.map(async (root) => {
      if (allowed.has(basename(root))) {
        await walk(root);
        return;
      }
      let entries;
      try {
        entries = await readdir(root, { withFileTypes: true });
      } catch {
        return;
      }
      await Promise.all(entries.map(async (entry) => {
        if (!entry.isDirectory()) return;
        if (allowed.has(entry.name)) {
          await walk(join(root, entry.name));
        } else {
          skippedFolders.push(join(root, entry.name));
        }
      }));
    }));
  }
  files.sort();
  skippedFolders.sort();
  return { files, skippedFolders };
}

// ─── Provider & timestamp inference ─────────────────────────────────

function inferProvider(filePath: string, sessionMeta: Record<string, unknown> | undefined): Provider {
  const lowerPath = filePath.toLowerCase();
  const payload = sessionMeta ?? {};
  const originator = String(payload.originator ?? '').toLowerCase();
  const source = String(payload.source ?? '').toLowerCase();
  const modelProvider = String(payload.model_provider ?? '').toLowerCase();
  const model = String(payload.model ?? '').toLowerCase();
  const joined = `${lowerPath} ${originator} ${source} ${modelProvider} ${model}`;
  const explicitProvider =
    normalizeProviderId(modelProvider) ??
    normalizeProviderId(source) ??
    normalizeProviderId(originator);
  if (explicitProvider) {
    return explicitProvider;
  }

  if (joined.includes('claude')) {
    return 'claude';
  }
  if (joined.includes('gemini')) {
    return 'gemini';
  }
  return 'codex';
}

function normalizeProviderId(value: string): Provider | undefined {
  const normalized = value.trim().toLowerCase();
  if (['user', 'human', 'assistant', 'system', 'unknown'].includes(normalized)) {
    return undefined;
  }
  if (/^[a-z0-9][a-z0-9._-]{0,63}$/.test(normalized)) {
    return normalized;
  }
  return undefined;
}

function extractSessionFileTimestamp(filePath: string): Date | undefined {
  const name = basename(filePath);
  let match = name.match(/rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-/);
  if (match) {
    const normalized = match[1]!.replace(/-/g, (_segment, index) => (index < 10 ? '-' : ':'));
    const timestamp = new Date(`${normalized}Z`);
    if (!Number.isNaN(timestamp.getTime())) return timestamp;
  }
  match = name.match(/session-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2})/);
  if (match) {
    const normalized = match[1]!.replace(/T(\d{2})-(\d{2})/, 'T$1:$2:00');
    const timestamp = new Date(`${normalized}Z`);
    if (!Number.isNaN(timestamp.getTime())) return timestamp;
  }
  return undefined;
}

function inDateRange(filePath: string, from?: Date, to?: Date): boolean {
  const timestamp = extractSessionFileTimestamp(filePath);
  if (!timestamp) {
    return true;
  }
  if (from && timestamp < from) {
    return false;
  }
  if (to && timestamp > to) {
    return false;
  }
  return true;
}

// ─── Event normalization ────────────────────────────────────────────

function normalizeEventType(item: Record<string, unknown>): CanonicalEventType | undefined {
  const topType = String(item.type ?? '').toLowerCase();
  const payloadType = String((item.payload as Record<string, unknown> | undefined)?.type ?? '').toLowerCase();
  const role = String((item.payload as Record<string, unknown> | undefined)?.role ?? '').toLowerCase();
  const eventType = String((item.payload as Record<string, unknown> | undefined)?.event_type ?? '').toLowerCase();

  if (topType === 'response_item') {
    if (payloadType === 'message') {
      if (role === 'user') {
        return 'prompt';
      }
      if (role === 'assistant') {
        return 'response';
      }
      return 'annotation';
    }
    if (payloadType === 'function_call' || payloadType === 'custom_tool_call') {
      return 'tool_call';
    }
    if (payloadType === 'function_call_output' || payloadType === 'custom_tool_call_output') {
      return 'tool_result';
    }
    if (payloadType === 'reasoning') {
      // v2.2.1: preserve reasoning traces as first-class events. The belief
      // gate rejects them from claim origination; they are stored so future
      // work can wire them as non-durable proof handles.
      return 'reasoning';
    }
  }

  if (topType === 'event_msg') {
    const msgType = String((item.payload as Record<string, unknown> | undefined)?.type ?? '').toLowerCase();
    if (msgType === 'agent_message') {
      // v2.2.1: structured assistant output, evaluated via the belief gate.
      return 'agent_message';
    }
    if (msgType === 'token_count') {
      return undefined;
    }

    const combined = `${eventType} ${JSON.stringify((item as any).payload ?? {})}`.toLowerCase();
    if (combined.includes('error') || combined.includes('failed')) {
      return 'error';
    }
    if (combined.includes('test')) {
      return 'test_result';
    }
    return 'annotation';
  }

  if (topType === 'turn_context') {
    // v2.2.1: turn boundary + provider env snapshot. Never a claim.
    return 'turn_context';
  }

  return undefined;
}

function extractMessageContent(payload: Record<string, unknown> | undefined): string | undefined {
  if (!payload) {
    return undefined;
  }
  const content = payload.content;
  if (typeof content === 'string') {
    return content;
  }
  if (!Array.isArray(content)) {
    return undefined;
  }

  const parts: string[] = [];
  for (const piece of content) {
    if (!piece || typeof piece !== 'object') {
      continue;
    }
    const text = (piece as Record<string, unknown>).text;
    if (typeof text === 'string' && text.length > 0) {
      parts.push(text);
    }
  }
  return parts.length > 0 ? parts.join('\n') : undefined;
}

function tryParseJsonObject(input: string | undefined): Record<string, unknown> | undefined {
  if (!input) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(input);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

function extractCommandFromArguments(payload: Record<string, unknown> | undefined): string | undefined {
  if (!payload) {
    return undefined;
  }
  if (typeof payload.cmd === 'string' && payload.cmd.trim().length > 0) {
    return payload.cmd.trim();
  }

  if (typeof payload.arguments === 'string') {
    const parsedArgs = tryParseJsonObject(payload.arguments);
    if (parsedArgs && typeof parsedArgs.cmd === 'string' && parsedArgs.cmd.trim().length > 0) {
      return parsedArgs.cmd.trim();
    }
    if (payload.arguments.trim().length > 0) {
      return payload.arguments.trim();
    }
  }

  return undefined;
}

function extractCommandOutput(raw: string | undefined): {
  message?: string;
  command?: string;
  exitCode?: number;
} {
  if (!raw || raw.trim().length === 0) {
    return {};
  }

  const commandMatch = raw.match(/(?:^|\n)Command:\s*(.+)/);
  const exitMatch = raw.match(/(?:^|\n)Process exited with code\s+(-?\d+)/);
  const outputIndex = raw.lastIndexOf('\nOutput:\n');

  const command = commandMatch?.[1]?.trim();
  const exitCode = exitMatch ? Number(exitMatch[1]) : undefined;
  const body =
    outputIndex >= 0
      ? raw.slice(outputIndex + '\nOutput:\n'.length).trim()
      : raw.trim();

  if (body.length === 0) {
    return { command, exitCode };
  }

  return { message: body, command, exitCode };
}

function extractEventMessage(input: {
  topType: string;
  payload: Record<string, unknown>;
}): string | undefined {
  const { topType, payload } = input;
  const payloadType = String(payload.type ?? '').toLowerCase();

  if (topType === 'event_msg') {
    if (typeof payload.message === 'string' && payload.message.trim().length > 0) {
      return payload.message.trim();
    }
    return undefined;
  }

  if (topType === 'response_item' && payloadType === 'function_call_output' && typeof payload.output === 'string') {
    return extractCommandOutput(payload.output).message;
  }

  return (
    extractMessageContent(payload)
    ?? (typeof payload.output === 'string' ? payload.output : undefined)
    ?? (typeof payload.summary === 'string' ? payload.summary : undefined)
  );
}

function stableId(input: string): string {
  return createHash('sha256').update(input).digest('hex').slice(0, 32);
}

function sanitizeAndTrimString(value: string): string {
  const sanitized = value.replace(/\u0000/g, '');
  if (sanitized.length <= MAX_EVENT_STRING_CHARS) {
    return sanitized;
  }
  return `${sanitized.slice(0, MAX_EVENT_STRING_CHARS)}\n...[truncated]`;
}

function sanitizeJson(value: unknown): unknown {
  if (typeof value === 'string') {
    return sanitizeAndTrimString(value);
  }
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeJson(entry));
  }
  if (!value || typeof value !== 'object') {
    return value;
  }

  const output: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    output[key] = sanitizeJson(entry);
  }
  return output;
}

function buildEventPayload(input: {
  sessionId: string;
  provider: Provider;
  index: number;
  line: Record<string, unknown>;
  maxEventsPerSession?: number;
  turnId?: string;
}): SessionEventPayload | undefined {
  if (input.maxEventsPerSession && input.index >= input.maxEventsPerSession) {
    return undefined;
  }

  const eventType = normalizeEventType(input.line);
  if (!eventType) {
    return undefined;
  }

  const payload = (input.line.payload as Record<string, unknown> | undefined) ?? {};
  const topType = String(input.line.type ?? '').toLowerCase();
  const payloadType = String(payload.type ?? '').toLowerCase();
  const timestamp = String(input.line.timestamp ?? new Date().toISOString());
  const serialized = JSON.stringify(input.line);

  const commandOutput = payloadType === 'function_call_output' && typeof payload.output === 'string'
    ? extractCommandOutput(payload.output)
    : {};

  const message = extractEventMessage({ topType, payload }) ?? commandOutput.message;

  const toolName =
    typeof payload.name === 'string'
      ? payload.name
      : typeof payload.tool_name === 'string'
        ? payload.tool_name
        : undefined;

  const command =
    commandOutput.command
    ?? extractCommandFromArguments(payload)
    ?? (typeof payload.command === 'string' ? payload.command : undefined);

  const exitCode = typeof commandOutput.exitCode === 'number'
    ? commandOutput.exitCode
    : undefined;

  const eventId = stableId(`${input.sessionId}:${input.index}:${serialized}`);
  const sanitizedMessage = message ? sanitizeAndTrimString(message) : undefined;
  const sanitizedToolName = toolName ? sanitizeAndTrimString(toolName) : undefined;
  const sanitizedCommand = command ? sanitizeAndTrimString(command) : undefined;
  return {
    sessionId: input.sessionId,
    eventId,
    idempotencyKey: `import-${eventId}`,
    provider: input.provider,
    eventType,
    eventTime: new Date(timestamp).toISOString(),
    payload: {
      ...(sanitizedMessage ? { message: sanitizedMessage } : {}),
      ...(sanitizedToolName ? { toolName: sanitizedToolName } : {}),
      ...(sanitizedCommand ? { command: sanitizedCommand } : {}),
      ...(typeof exitCode === 'number' ? { exitCode } : {}),
      metadata: {
        sourceType: input.line.type ?? null,
        responseItemType: payload.type ?? null
      }
    },
    rawPayload: sanitizeJson(payload) as Record<string, unknown>,
    ...(input.turnId ? { turnId: input.turnId } : {})
  };
}

// ─── Session parsing ────────────────────────────────────────────────

async function parseSessionFile(filePath: string, options: ImportOptions): Promise<ParsedSession | undefined> {
  if (extname(filePath) === '.json') {
    try {
      const fileContent = await readFile(filePath, 'utf8');
      const data = JSON.parse(fileContent);
      const externalSessionId = data.sessionId || stableId(filePath);
      const parsed: ParsedSession = {
        provider: 'gemini',
        externalSessionId,
        repo: { filePaths: [] },
        metadata: { source: 'bulk-import', filePath, projectHash: data.projectHash, ...(importUserEmail() ? { userEmail: importUserEmail() } : {}) },
        startedAt: data.startTime,
        events: []
      };
      const messages = data.messages || [];
      for (let i = 0; i < messages.length; i++) {
        if (options.maxEventsPerSession && i >= options.maxEventsPerSession) break;
        const msg = messages[i];
        let eventType: CanonicalEventType = msg.type === 'user' ? 'prompt' : 'response';
        let text = '';
        if (Array.isArray(msg.content)) {
          text = msg.content.map((c: any) => c.text || '').join('\n');
        }
        const eventId = stableId(`${externalSessionId}:${i}:${msg.id}`);
        parsed.events.push({
          sessionId: externalSessionId,
          eventId,
          idempotencyKey: `import-${eventId}`,
          provider: 'gemini',
          eventType,
          eventTime: msg.timestamp || new Date().toISOString(),
          payload: { message: sanitizeAndTrimString(text) },
          rawPayload: sanitizeJson(msg) as Record<string, unknown>
        });
      }
      if (parsed.events.length === 0) return undefined;
      parsed.summary = parsed.events.map(e => String(e.payload.message || '')).filter(Boolean).slice(-5).join('\n').slice(0, 1500);
      parsed.endedAt = data.lastUpdated || parsed.events.at(-1)?.eventTime;
      return parsed;
    } catch (e) { return undefined; }
  }

  const stream = createReadStream(filePath, { encoding: 'utf8' });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

  let sessionMeta: Record<string, unknown> | undefined;
  let parsed: ParsedSession | undefined;
  let lineIndex = 0;
  // v2.2.1 turn-graph: tracks the current turn id across the session scan.
  // Codex bumps on each `turn_context` line; Claude bumps on each user
  // message. See docs/research/v2.2.1-pckc/DESIGN.md §3.
  let turnCounter = 0;
  let currentTurnId: string | undefined;

  try {
    for await (const line of rl) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        lineIndex += 1;
        continue;
      }

      let parsedLine: Record<string, unknown>;
      try {
        parsedLine = JSON.parse(trimmed);
      } catch {
        lineIndex += 1;
        continue;
      }

      const topType = String(parsedLine.type ?? '');
      if (topType === 'session_meta') {
        sessionMeta = (parsedLine.payload as Record<string, unknown> | undefined) ?? {};
        const provider = inferProvider(filePath, sessionMeta);
        const externalSessionId = String((sessionMeta.id ?? '') || stableId(filePath));
        const repo = {
          repoName: undefined,
          branch: stringOrUndefined(sessionMeta.branch),
          commitSha: stringOrUndefined(sessionMeta.commit_hash),
          filePaths: [] as string[]
        };
        const startedAt = stringOrUndefined(sessionMeta.timestamp);

        parsed = {
          provider,
          externalSessionId,
          repo,
          metadata: {
            source: 'bulk-import',
            filePath,
            cwd: stringOrUndefined(sessionMeta.cwd),
            originator: stringOrUndefined(sessionMeta.originator),
            modelProvider: stringOrUndefined(sessionMeta.model_provider),
            ...(importUserEmail() ? { userEmail: importUserEmail() } : {})
          },
          startedAt,
          events: []
        };
      } else if (!parsed && filePath.includes('claude')) {
        const externalSessionId = String(parsedLine.sessionId || stableId(filePath));
        parsed = {
          provider: 'claude',
          externalSessionId,
          repo: { filePaths: [] },
          metadata: { source: 'bulk-import', filePath, cwd: stringOrUndefined(parsedLine.cwd), ...(importUserEmail() ? { userEmail: importUserEmail() } : {}) },
          startedAt: stringOrUndefined(parsedLine.timestamp),
          events: []
        };
      }

      if (parsed) {
        // v2.2.1: bump turn id before buildEventPayload so the new event
        // inherits the latest boundary.
        if (parsed.provider !== 'claude' && topType === 'turn_context') {
          turnCounter += 1;
          currentTurnId = `turn-${turnCounter}`;
        }
        if (parsed.provider === 'claude' && topType === 'user') {
          const anchor = String(parsedLine.uuid || lineIndex);
          currentTurnId = `turn-${stableId(anchor).slice(0, 16)}`;
        }

        let event: SessionEventPayload | undefined = undefined;

        if (parsed.provider === 'claude' && filePath.includes('claude')) {
           let eType: CanonicalEventType | undefined = undefined;
           if (topType === 'user') eType = 'prompt';
           if (topType === 'assistant') eType = 'response';
           if (topType === 'system' && parsedLine.subtype === 'local_command') eType = 'command';

           if (eType) {
             let message = '';
             let command = '';
             if (eType === 'command') {
                command = extractCommandOutput(String(parsedLine.content)).command || String(parsedLine.content);
             } else {
                message = typeof parsedLine.message === 'object' && parsedLine.message !== null
                  ? contentText((parsedLine.message as any).content)
                  : contentText(parsedLine.content);
             }

             // A subagent transcript shares the parent's session id and restarts
             // events.length at 0, so a uuid-less line is keyed by its file too.
             const lineKey = parsedLine.uuid || (isSubagentTranscript(filePath) ? `${basename(filePath)}#${lineIndex}` : lineIndex);
             const eventId = stableId(`${parsed.externalSessionId}:${parsed.events.length}:${lineKey}`);
             event = {
                sessionId: parsed.externalSessionId,
                eventId,
                idempotencyKey: `import-${eventId}`,
                provider: 'claude',
                eventType: eType,
                eventTime: String(parsedLine.timestamp || new Date().toISOString()),
                payload: {
                  ...(message ? { message: sanitizeAndTrimString(message) } : {}),
                  ...(command ? { command: sanitizeAndTrimString(command) } : {})
                },
                rawPayload: sanitizeJson(parsedLine) as Record<string, unknown>,
                ...(currentTurnId ? { turnId: currentTurnId } : {})
             };
           }
        } else {
           event = buildEventPayload({
            sessionId: parsed.externalSessionId,
            provider: parsed.provider,
            index: parsed.events.length,
            line: parsedLine,
            maxEventsPerSession: options.maxEventsPerSession,
            turnId: currentTurnId
          });
        }

        if (event) {
          parsed.events.push(event);
        }
      }

      lineIndex += 1;
    }
  } finally {
    rl.close();
    stream.close();
  }

  if (!parsed) {
    return undefined;
  }

  parsed.summary = parsed.events
    .map((event) => event.payload.message)
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .slice(-5)
    .join('\n')
    .slice(0, 1500);
  parsed.endedAt = parsed.events.at(-1)?.eventTime;

  return parsed;
}

// Author identity stamped on every imported session (hooks send the checkout's
// git user.email; a backfill has no checkout, so take CHUM_IMPORT_EMAIL or the
// global git identity of whoever runs the import).
let cachedImportEmail: string | undefined | null = null;
function importUserEmail(): string | undefined {
  if (cachedImportEmail !== null) return cachedImportEmail;
  const fromEnv = (process.env.CHUM_IMPORT_EMAIL || '').trim();
  if (fromEnv) { cachedImportEmail = fromEnv; return fromEnv; }
  try {
    const out = execFileSync('git', ['config', '--get', 'user.email'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    cachedImportEmail = out || undefined;
  } catch { cachedImportEmail = undefined; }
  return cachedImportEmail;
}

function stringOrUndefined(value: unknown): string | undefined {
  if (typeof value === 'string' && value.trim().length > 0) {
    return value.trim();
  }
  return undefined;
}

// ─── HTTP transport (ultra-fast: batched events, connection reuse) ───

const httpAgent = { keepAlive: true };

async function postJson<TResponse>(
  url: string,
  body: Record<string, unknown>,
  dryRun: boolean
): Promise<TResponse | undefined> {
  if (dryRun) {
    return undefined;
  }
  // The server rejects requests without a token once CHUM_MEM_API_TOKENS is set
  // (2026-10-09); without this header every session/start fails with 401 and
  // the whole backfill is counted as "failed".
  const headers: Record<string, string> = { 'content-type': 'application/json', 'connection': 'keep-alive' };
  const token = (process.env.CHUM_MEMORY_API_TOKEN || process.env.CHUM_IMPORT_TOKEN || '').trim();
  if (token) headers['x-chum-token'] = token;
  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    keepalive: true
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`${url} failed (${response.status}): ${text}`);
  }
  return (await response.json()) as TResponse;
}

// Send all events via high-throughput COPY-based bulk endpoint, falling back
// to regular batch INSERT if the bulk endpoint is unavailable.
async function sendEventBatch(
  events: SessionEventPayload[],
  serverUrl: string,
  sessionId: string,
  dryRun: boolean,
  batchSize: number
): Promise<number> {
  if (dryRun) return events.length;

  let sent = 0;
  for (let i = 0; i < events.length; i += batchSize) {
    const chunk = events.slice(i, i + batchSize);
    const body = {
      sessionId,
      events: chunk.map((event) => ({ ...event, sessionId }))
    };
    try {
      // Try COPY-based bulk endpoint first (UNLOGGED staging + deferred constraints).
      const result = await postJson<{ inserted: number; duplicates: number }>(
        `${serverUrl}/v1/ingest/session/events/bulk`,
        body,
        false
      );
      sent += (result?.inserted ?? 0) + (result?.duplicates ?? 0);
    } catch {
      // Fallback: regular batch INSERT endpoint
      try {
        const result = await postJson<{ inserted: number; duplicates: number }>(
          `${serverUrl}/v1/ingest/session/events`,
          body,
          false
        );
        sent += (result?.inserted ?? 0) + (result?.duplicates ?? 0);
      } catch {
        // Last resort: send individually
        for (const event of chunk) {
          try {
            await postJson(
              `${serverUrl}/v1/ingest/session/event`,
              { ...event, sessionId } as unknown as Record<string, unknown>,
              false
            );
          } catch { /* idempotent */ }
          sent++;
        }
      }
    }
  }
  return sent;
}

/**
 * Text of a Claude message `content`: a string, or an array of blocks of which
 * only `text` blocks are kept (tool_use / tool_result / thinking are not the
 * user's or the assistant's words). It used to be `String(content)`, which
 * stored every block-array reply as "[object Object]" (56,863 of 57,493
 * imported responses in the review store).
 */
function contentText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((block) => (block && typeof block === 'object' && (block as any).type === 'text' && typeof (block as any).text === 'string')
        ? (block as any).text as string
        : '')
      .filter((text) => text.length > 0)
      .join('\n');
  }
  return '';
}

function toIso(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? undefined : new Date(ms).toISOString();
}

/** First event time of the transcript (falls back to the parsed start). */
function transcriptStart(parsed: ParsedSession): string | undefined {
  const times = parsed.events.map((event) => toIso(event.eventTime)).filter((t): t is string => !!t).sort();
  return times[0] ?? toIso(parsed.startedAt);
}

/** Last event time of the transcript (falls back to the parsed end). */
function transcriptEnd(parsed: ParsedSession): string | undefined {
  const times = parsed.events.map((event) => toIso(event.eventTime)).filter((t): t is string => !!t).sort();
  return times.at(-1) ?? toIso(parsed.endedAt);
}

async function importSession(parsed: ParsedSession, options: ImportOptions): Promise<{ events: number; duplicate: boolean }> {
  const startPayload: SessionStartPayload = {
    provider: parsed.provider,
    projectId: options.projectId,
    externalSessionId: parsed.externalSessionId,
    repo: parsed.repo,
    // The server dates the session (and its memories) from these instead of
    // the import time when they are present.
    metadata: {
      ...parsed.metadata,
      ...(transcriptStart(parsed) ? { startedAt: transcriptStart(parsed) } : {})
    }
  };

  let startResponse: { sessionId: string; status?: string } | undefined;
  try {
    startResponse = await postJson<{ sessionId: string; status?: string }>(
      `${options.serverUrl}/v1/ingest/session/start`,
      startPayload as unknown as Record<string, unknown>,
      options.dryRun
    );
  } catch (err) {
    // If session already completed, skip unless --fresh
    const msg = err instanceof Error ? err.message : '';
    if (msg.includes('completed') && !options.fresh) {
      return { events: 0, duplicate: true };
    }
    throw err;
  }

  const sessionId = startResponse?.sessionId ?? `dry-${randomUUID()}`;

  // Skip already-completed sessions unless --fresh
  if (startResponse?.status === 'completed' && !options.fresh) {
    return { events: 0, duplicate: true };
  }

  // Send events in parallel batches
  const importedEvents = await sendEventBatch(
    parsed.events,
    options.serverUrl,
    sessionId,
    options.dryRun,
    options.batchSize
  );

  const endPayload: SessionEndPayload = {
    sessionId,
    ...(parsed.summary ? { summary: parsed.summary } : {}),
    defer: true,
    metadata: {
      importedAt: new Date().toISOString(),
      source: 'bulk-import',
      ...(transcriptEnd(parsed) ? { endedAt: transcriptEnd(parsed) } : {})
    }
  };

  await postJson(
    `${options.serverUrl}/v1/ingest/session/end`,
    endPayload as unknown as Record<string, unknown>,
    options.dryRun
  );

  return { events: importedEvents, duplicate: false };
}

// ─── Sensitive-content guard ────────────────────────────────────────
// The hooks hold back any event that matches the client's secret patterns
// (plugins/chum-memory-claude/scripts/sensitive-patterns.txt plus the repo's
// optional .chum-sensitive-patterns); the importer used to store transcripts
// as they are, keys and database URLs included. It now skips matching events
// the same way and reports only how many matched each pattern, never the text.
// --include-sensitive turns the guard off.

interface SensitiveRule {
  name: string;
  re: RegExp;
}

// The pattern files are POSIX extended regexes (grep -E); JS has no [:class:].
const POSIX_CLASSES: Record<string, string> = {
  space: '\\s', alnum: 'A-Za-z0-9', alpha: 'A-Za-z', digit: '0-9', upper: 'A-Z', lower: 'a-z', xdigit: '0-9A-Fa-f'
};

function ereToJs(pattern: string): string {
  return pattern.replace(/\[:([a-z]+):\]/g, (whole, name: string) => {
    const replacement = POSIX_CLASSES[name];
    if (!replacement) throw new Error(`unsupported POSIX class ${whole}`);
    return replacement;
  });
}

function sensitivePatternFiles(): { base: string; repo: string } {
  const scriptDir = typeof __dirname === 'string' ? __dirname : dirname(resolve(process.argv[1] ?? '.'));
  return {
    base: process.env.CHUM_SENSITIVE_PATTERNS_FILE
      || join(scriptDir, '..', 'plugins', 'chum-memory-claude', 'scripts', 'sensitive-patterns.txt'),
    repo: join(process.cwd(), '.chum-sensitive-patterns')
  };
}

/** Loads `name|flags|regex` rules. Fails closed: an unreadable base file or a bad rule stops the import. */
function loadSensitiveRules(): { rules: SensitiveRule[]; sources: string[] } {
  const { base, repo } = sensitivePatternFiles();
  const sources: string[] = [];
  let text: string;
  try {
    text = readFileSync(base, 'utf8');
    sources.push(base);
  } catch {
    throw new Error(`sensitive-content guard: cannot read ${base}; refusing to import unguarded (set CHUM_SENSITIVE_PATTERNS_FILE, or pass --include-sensitive to import secrets as they are)`);
  }
  try {
    text += `\n${readFileSync(repo, 'utf8')}`;
    sources.push(repo);
  } catch {
    // the per-repo extension is optional
  }
  const rules: SensitiveRule[] = [];
  for (const line of text.split('\n')) {
    if (line.length === 0 || line.startsWith('#')) continue;
    const first = line.indexOf('|');
    const second = first < 0 ? -1 : line.indexOf('|', first + 1);
    if (first <= 0 || second < 0) continue;
    const name = line.slice(0, first);
    const flags = line.slice(first + 1, second);
    const pattern = line.slice(second + 1);
    if (pattern.length === 0) continue;
    try {
      rules.push({ name, re: new RegExp(ereToJs(pattern), flags.includes('i') ? 'i' : '') });
    } catch (error) {
      throw new Error(`sensitive-content guard: rule "${name}" does not compile: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (rules.length === 0) {
    throw new Error(`sensitive-content guard: no rules in ${sources.join(', ')}; refusing to import unguarded`);
  }
  return { rules, sources };
}

/**
 * Drops events whose payload or raw payload matches a rule (the hooks scan the
 * same JSON-encoded event) and rebuilds the summary from the events kept.
 */
function applySensitiveGuard(parsed: ParsedSession, rules: SensitiveRule[], stats: ImportStats): void {
  const kept: SessionEventPayload[] = [];
  for (const event of parsed.events) {
    const text = `${JSON.stringify(event.payload)}\n${JSON.stringify(event.rawPayload)}`;
    const matched = rules.filter((rule) => rule.re.test(text)).map((rule) => rule.name);
    if (matched.length === 0) {
      kept.push(event);
      continue;
    }
    stats.eventsHeldSensitive += 1;
    for (const name of matched) {
      stats.heldByPattern[name] = (stats.heldByPattern[name] ?? 0) + 1;
    }
  }
  if (kept.length === parsed.events.length) return;
  parsed.events = kept;
  parsed.summary = kept
    .map((event) => event.payload.message)
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .slice(-5)
    .join('\n')
    .slice(0, 1500);
}

// ─── Session grouping (main transcript + its subagent transcripts) ──

/**
 * Claude Code writes a subagent's transcript next to the session as
 * `<project>/<session-id>/subagents/agent-<id>.jsonl` (older versions:
 * `<project>/agent-<id>.jsonl`), and every line carries the PARENT's sessionId.
 */
function isSubagentTranscript(filePath: string): boolean {
  return /[\\/]subagents[\\/]/.test(filePath) || basename(filePath).startsWith('agent-');
}

/**
 * Groups parsed transcripts by (provider, externalSessionId) and merges each
 * group into one session: the main transcript first (it supplies the summary,
 * metadata and file path), then the subagent transcripts in file-name order,
 * each event exactly once. The session is then started, filled and ended once.
 */
function groupTranscriptsBySession(
  parsed: Array<{ file: string; session: ParsedSession }>
): Array<{ file: string; session: ParsedSession }> {
  const groups = new Map<string, Array<{ file: string; session: ParsedSession }>>();
  for (const entry of parsed) {
    const key = `${entry.session.provider}\u0000${entry.session.externalSessionId}`;
    const list = groups.get(key);
    if (list) list.push(entry); else groups.set(key, [entry]);
  }
  const rank = (entry: { file: string; session: ParsedSession }): number =>
    isSubagentTranscript(entry.file) ? 2 : basename(entry.file, extname(entry.file)) === entry.session.externalSessionId ? 0 : 1;
  const merged: Array<{ file: string; session: ParsedSession }> = [];
  for (const list of groups.values()) {
    if (list.length === 1) {
      merged.push(list[0]!);
      continue;
    }
    list.sort((a, b) => rank(a) - rank(b) || a.file.localeCompare(b.file));
    const main = list[0]!;
    const seen = new Set<string>();
    const events: SessionEventPayload[] = [];
    for (const entry of list) {
      for (const event of entry.session.events) {
        if (seen.has(event.eventId)) continue;
        seen.add(event.eventId);
        events.push(event);
      }
    }
    const subagentFiles = list.filter((entry) => isSubagentTranscript(entry.file)).length;
    const startedAt = list.map((entry) => entry.session.startedAt).filter((t): t is string => !!t).sort()[0];
    merged.push({
      file: main.file,
      session: {
        ...main.session,
        metadata: { ...main.session.metadata, transcriptFiles: list.length, subagentTranscripts: subagentFiles },
        ...(startedAt ? { startedAt } : {}),
        events
      }
    });
  }
  return merged;
}

// ─── Concurrency pool ───────────────────────────────────────────────

async function runWithConcurrency<T>(
  items: T[],
  concurrency: number,
  fn: (item: T, index: number) => Promise<void>
): Promise<void> {
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (nextIndex < items.length) {
      const index = nextIndex++;
      const item = items[index];
      if (item !== undefined) {
        await fn(item, index);
      }
    }
  }

  const workers = Array.from({ length: Math.min(concurrency, items.length) }, () => worker());
  await Promise.all(workers);
}

// ─── Progress display ───────────────────────────────────────────────

function progressLine(stats: ImportStats, total: number, currentFile: string): string {
  const pct = total > 0 ? Math.round((stats.filesProcessed / total) * 100) : 0;
  const rate = stats.elapsedMs > 0 ? Math.round((stats.sessionsImported / stats.elapsedMs) * 1000) : 0;
  const short = basename(currentFile).slice(0, 40);
  return `[${pct}%] ${stats.filesProcessed}/${total} files | ${stats.sessionsImported} sessions | ${stats.eventsImported} events | ${rate} sess/s | ${short}`;
}

// ─── Main ───────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const startTime = Date.now();
  const options = parseArgs(process.argv.slice(2));
  if (!options.allowFolders && !options.allFolders) {
    throw new Error(
      'Refusing to import without an explicit folder allowlist. Pass --allow-folders=<project-folder>[,<project-folder>…] ' +
      '(exact names under each --roots entry), or --all-folders to import everything under the roots.'
    );
  }
  const { files, skippedFolders } = await collectSessionFiles(options.roots, options.allowFolders);
  if (skippedFolders.length > 0) {
    console.log(`Skipped ${skippedFolders.length} folder(s) not in --allow-folders: ${skippedFolders.map((f) => basename(f)).join(', ')}`);
  }
  const stats: ImportStats = {
    filesDiscovered: files.length,
    filesProcessed: 0,
    filesSkippedByDate: 0,
    sessionsImported: 0,
    eventsImported: 0,
    sessionsFailed: 0,
    sessionsDuplicate: 0,
    eventsHeldSensitive: 0,
    heldByPattern: {},
    elapsedMs: 0
  };

  const selected = files.filter((filePath) => {
    const include = inDateRange(filePath, options.from, options.to);
    if (!include) {
      stats.filesSkippedByDate += 1;
    }
    return include;
  });

  const finalFiles = options.maxFiles ? selected.slice(0, options.maxFiles) : selected;

  console.log(
    JSON.stringify(
      {
        mode: options.dryRun ? 'dry-run' : 'execute',
        serverUrl: options.serverUrl,
        projectId: options.projectId,
        roots: options.roots,
        filesDiscovered: stats.filesDiscovered,
        filesSelected: finalFiles.length,
        filesSkippedByDate: stats.filesSkippedByDate,
        concurrency: options.concurrency,
        batchSize: options.batchSize,
        fresh: options.fresh
      },
      null,
      2
    )
  );

  // Load the guard before any parsing, so a missing pattern file stops the run early.
  const guard = options.includeSensitive ? undefined : loadSensitiveRules();
  if (guard) {
    console.log(`Sensitive-content guard: ${guard.rules.length} patterns from ${guard.sources.join(', ')}`);
  } else {
    console.log('Sensitive-content guard OFF (--include-sensitive): events are imported as they are, secrets included');
  }

  // Parse all files first (CPU-bound, fast)
  const parseStart = Date.now();
  const parsedSessions: Array<{ file: string; session: ParsedSession }> = [];

  await runWithConcurrency(finalFiles, options.concurrency, async (filePath) => {
    try {
      const parsed = await parseSessionFile(filePath, options);
      if (parsed && guard) applySensitiveGuard(parsed, guard.rules, stats);
      if (parsed && parsed.events.length > 0) {
        parsedSessions.push({ file: filePath, session: parsed });
      }
    } catch {
      // skip unparseable files
    }
    stats.filesProcessed += 1;
  });

  const parseMs = Date.now() - parseStart;
  console.log(`Parsed ${parsedSessions.length} transcripts from ${stats.filesProcessed} files in ${parseMs}ms`);
  if (guard) {
    const perPattern = Object.entries(stats.heldByPattern).sort((a, b) => b[1] - a[1]).map(([name, n]) => `${name}: ${n}`).join(', ');
    console.log(`Sensitive-content guard: skipped ${stats.eventsHeldSensitive} event(s) matching secret patterns${perPattern ? ` (${perPattern})` : ''}; values are not printed. Re-run with --include-sensitive to import them.`);
  }

  // One import per session, not per file: subagent transcripts carry their
  // parent's session id, and importing them as separate sessions in parse
  // order let a small subagent file end the session first, after which the
  // main transcript was skipped as "already completed" (fresh store: 57k of
  // 74k events lost).
  const sessionGroups = groupTranscriptsBySession(parsedSessions);
  const mergedFiles = parsedSessions.length - sessionGroups.length;
  if (mergedFiles > 0) {
    console.log(`Merged ${mergedFiles} subagent transcript(s) into their parent sessions: ${sessionGroups.length} sessions to import`);
  }

  // Reset for import phase
  stats.filesProcessed = 0;

  // Drop non-unique indexes for bulk import throughput (optimization #6).
  // Only `create-indexes` after a successful drop: an admin-token rejection
  // (401/403) or an older server must not leave the importer thinking it owes
  // a recreate, and a crash mid-import must still recreate (hence `finally`
  // below; FINDINGS F31).
  let indexesDropped = false;
  if (!options.dryRun && sessionGroups.length > 0) {
    try {
      await postJson(`${options.serverUrl}/v1/ingest/bulk/drop-indexes`, {}, false);
      indexesDropped = true;
      console.log('Dropped session_events indexes for bulk import');
    } catch (error) {
      console.error(`Note: bulk drop-indexes skipped (${error instanceof Error ? error.message : String(error)}); importing with indexes in place`);
    }
  }

  // Import sessions concurrently
  const importStart = Date.now();
  try {
  await runWithConcurrency(sessionGroups, options.concurrency, async ({ file, session }, index) => {
    stats.filesProcessed += 1;
    try {
      const result = await importSession(session, options);

      if (result.duplicate) {
        stats.sessionsDuplicate += 1;
      } else {
        stats.sessionsImported += 1;
        stats.eventsImported += result.events;
      }

      stats.elapsedMs = Date.now() - importStart;

      // Log progress every 10 sessions
      if (stats.filesProcessed % 10 === 0 || stats.filesProcessed === sessionGroups.length) {
        process.stderr.write(`\r${progressLine(stats, sessionGroups.length, file)}`);
      }
    } catch (error) {
      stats.sessionsFailed += 1;
      if (stats.sessionsFailed <= 5) {
        console.error(
          JSON.stringify({
            file,
            imported: false,
            error: error instanceof Error ? error.message : String(error)
          })
        );
      }
    }
  });

  } finally {
    // Recreate indexes after bulk import (optimization #6) — also on a crash.
    if (indexesDropped) {
      try {
        await postJson(`${options.serverUrl}/v1/ingest/bulk/create-indexes`, {}, false);
        console.log('Recreated session_events indexes after bulk import');
      } catch {
        console.error('Warning: failed to recreate indexes. Run manually: POST /v1/ingest/bulk/create-indexes');
      }
    }
  }

  stats.elapsedMs = Date.now() - startTime;
  process.stderr.write('\n');

  console.log(JSON.stringify({
    summary: {
      ...stats,
      sessionsPerSecond: stats.elapsedMs > 0 ? Number(((stats.sessionsImported / stats.elapsedMs) * 1000).toFixed(1)) : 0
    }
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
