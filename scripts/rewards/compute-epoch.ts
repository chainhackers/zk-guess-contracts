#!/usr/bin/env bun
/**
 * Compute a Rewards epoch recipients CSV from indexer data, per v1 rules.
 *
 * Usage:
 *   bun run scripts/rewards/compute-epoch.ts --epoch <N> [options]
 *
 * Options:
 *   --epoch <N>            epoch number (required)
 *   --window-end <iso>     7-day window end; default = last Monday 00:00 UTC
 *   --rewards-addr <addr>  defaults to Base mainnet 0x3f40...8c1c
 *   --rpc-url <url>        defaults to $BASE_RPC_URL or $BASE_MAINNET_RPC
 *   --indexer-url <url>    defaults to production HyperIndex GraphQL endpoint
 *   --out <path>           output CSV path; default /tmp/epoch-<N>.csv
 *   --dry-run              print CSV to stdout, do not write
 *
 * Rules (spec 2026-04-18, §v1):
 *   - Pool = floor(balance/2). Other half rolls forward.
 *   - 30% active guesser streak: ≥1 Challenge each of 7 window days AND ≥3 total → equal split
 *   - 20% active creator streak: created ≥1 puzzle in window AND 0 forfeited → equal split
 *   - 25% top 3 puzzle creators by Puzzle count in window → 50/30/20
 *   - 25% top 3 correct guessers (solvers) by Challenge.correct in window → 50/30/20
 *   Empty categories are skipped; their share stays in the contract (rolls forward).
 */

import { writeFileSync } from "node:fs";

const DEFAULT_REWARDS_ADDR = "0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c";
const DEFAULT_INDEXER_URL = "https://indexer.hyperindex.xyz/aa21ad1/v1/graphql";
const WINDOW_SECONDS = 7 * 24 * 60 * 60;
const TOP3_WEIGHTS = [50n, 30n, 20n] as const;

interface Challenge {
  guesser: string;
  timestamp: string; // numeric (string in GraphQL)
  correct: boolean;
  puzzleId: string;
}
interface Puzzle {
  id: string;
  creator: string;
  createdAtTimestamp: string;
  forfeited: boolean;
  solved: boolean;
}

type Args = {
  epoch: number;
  windowEnd: number;
  rewardsAddr: string;
  rpcUrl: string;
  indexerUrl: string;
  out: string;
  dryRun: boolean;
};

function die(msg: string): never {
  console.error(`Error: ${msg}`);
  process.exit(1);
}

function lastMondayUtcEpochSeconds(now = new Date()): number {
  const midnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const dow = new Date(midnight).getUTCDay(); // 0=Sun … 6=Sat
  const daysBack = (dow + 6) % 7; // Mon → 0, Tue → 1, …, Sun → 6
  return Math.floor(midnight / 1000) - daysBack * 86400;
}

function parseArgs(argv: string[]): Args {
  let epoch: number | undefined;
  let windowEndIso: string | undefined;
  let rewardsAddr = DEFAULT_REWARDS_ADDR;
  let rpcUrl = process.env.BASE_RPC_URL || process.env.BASE_MAINNET_RPC || "";
  let indexerUrl = DEFAULT_INDEXER_URL;
  let out: string | undefined;
  let dryRun = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (!v) die(`${a} requires a value`);
      return v;
    };
    if (a === "--epoch") epoch = Number(next());
    else if (a === "--window-end") windowEndIso = next();
    else if (a === "--rewards-addr") rewardsAddr = next();
    else if (a === "--rpc-url") rpcUrl = next();
    else if (a === "--indexer-url") indexerUrl = next();
    else if (a === "--out") out = next();
    else if (a === "--dry-run") dryRun = true;
    else die(`unknown flag: ${a}`);
  }

  if (epoch === undefined || !Number.isInteger(epoch) || epoch < 1) {
    die("--epoch must be a positive integer");
  }
  if (!rpcUrl) die("no RPC URL: set --rpc-url or BASE_RPC_URL / BASE_MAINNET_RPC");
  if (!/^0x[0-9a-fA-F]{40}$/.test(rewardsAddr)) die(`invalid --rewards-addr: ${rewardsAddr}`);

  const windowEnd =
    windowEndIso === undefined
      ? lastMondayUtcEpochSeconds()
      : Math.floor(new Date(windowEndIso).getTime() / 1000);
  if (!Number.isFinite(windowEnd) || windowEnd <= 0) die(`invalid --window-end: ${windowEndIso}`);

  return {
    epoch,
    windowEnd,
    rewardsAddr,
    rpcUrl,
    indexerUrl,
    out: out ?? `/tmp/epoch-${epoch}.csv`,
    dryRun,
  };
}

async function fetchBalanceWei(rpcUrl: string, addr: string): Promise<bigint> {
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getBalance", params: [addr, "latest"] }),
  });
  if (!res.ok) die(`RPC error ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { result?: string; error?: { message: string } };
  if (json.error) die(`RPC error: ${json.error.message}`);
  if (!json.result) die(`RPC returned no result`);
  return BigInt(json.result);
}

async function gql<T>(url: string, query: string, variables: Record<string, unknown>): Promise<T> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  if (!res.ok) die(`GraphQL HTTP ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
  if (json.errors?.length) die(`GraphQL errors: ${json.errors.map((e) => e.message).join("; ")}`);
  if (!json.data) die(`GraphQL returned no data`);
  return json.data;
}

async function fetchChallenges(url: string, start: number, end: number): Promise<Challenge[]> {
  // Hasura pagination: page through by timestamp+id (stable lexical order).
  const pageSize = 1000;
  const all: Challenge[] = [];
  let offset = 0;
  while (true) {
    const data = await gql<{ Challenge: Challenge[] }>(
      url,
      `query($start: numeric!, $end: numeric!, $limit: Int!, $offset: Int!) {
        Challenge(
          where: {timestamp: {_gte: $start, _lt: $end}},
          order_by: [{timestamp: asc}, {id: asc}],
          limit: $limit, offset: $offset
        ) { guesser timestamp correct puzzleId }
      }`,
      { start, end, limit: pageSize, offset },
    );
    all.push(...data.Challenge);
    if (data.Challenge.length < pageSize) break;
    offset += pageSize;
  }
  return all;
}

async function fetchPuzzles(url: string, start: number, end: number): Promise<Puzzle[]> {
  const pageSize = 1000;
  const all: Puzzle[] = [];
  let offset = 0;
  while (true) {
    const data = await gql<{ Puzzle: Puzzle[] }>(
      url,
      `query($start: numeric!, $end: numeric!, $limit: Int!, $offset: Int!) {
        Puzzle(
          where: {createdAtTimestamp: {_gte: $start, _lt: $end}},
          order_by: [{createdAtTimestamp: asc}, {id: asc}],
          limit: $limit, offset: $offset
        ) { id creator createdAtTimestamp forfeited solved }
      }`,
      { start, end, limit: pageSize, offset },
    );
    all.push(...data.Puzzle);
    if (data.Puzzle.length < pageSize) break;
    offset += pageSize;
  }
  return all;
}

function utcDayOf(tsSec: number): number {
  return Math.floor(tsSec / 86400);
}

function computeGuesserStreaks(challenges: Challenge[]): Set<string> {
  const byGuesser = new Map<string, { total: number; days: Set<number> }>();
  for (const c of challenges) {
    const addr = c.guesser.toLowerCase();
    const entry = byGuesser.get(addr) ?? { total: 0, days: new Set<number>() };
    entry.total++;
    entry.days.add(utcDayOf(Number(c.timestamp)));
    byGuesser.set(addr, entry);
  }
  const eligible = new Set<string>();
  for (const [addr, { total, days }] of byGuesser) {
    if (total >= 3 && days.size >= 7) eligible.add(addr);
  }
  return eligible;
}

function computeCreatorStreaks(puzzles: Puzzle[]): Set<string> {
  const byCreator = new Map<string, { created: number; forfeited: number }>();
  for (const p of puzzles) {
    const addr = p.creator.toLowerCase();
    const entry = byCreator.get(addr) ?? { created: 0, forfeited: 0 };
    entry.created++;
    if (p.forfeited) entry.forfeited++;
    byCreator.set(addr, entry);
  }
  const eligible = new Set<string>();
  for (const [addr, { created, forfeited }] of byCreator) {
    if (created >= 1 && forfeited === 0) eligible.add(addr);
  }
  return eligible;
}

function topN<T>(entries: Array<[string, number]>, n: number): Array<[string, number]> {
  return [...entries].sort((a, b) => (b[1] !== a[1] ? b[1] - a[1] : a[0].localeCompare(b[0]))).slice(0, n);
}

function topCreators(puzzles: Puzzle[]): Array<[string, number]> {
  const counts = new Map<string, number>();
  for (const p of puzzles) {
    const addr = p.creator.toLowerCase();
    counts.set(addr, (counts.get(addr) ?? 0) + 1);
  }
  return topN([...counts.entries()], 3);
}

function topSolvers(challenges: Challenge[]): Array<[string, number]> {
  const counts = new Map<string, number>();
  for (const c of challenges) {
    if (!c.correct) continue;
    const addr = c.guesser.toLowerCase();
    counts.set(addr, (counts.get(addr) ?? 0) + 1);
  }
  return topN([...counts.entries()], 3);
}

function addAmount(map: Map<string, bigint>, addr: string, wei: bigint): void {
  if (wei <= 0n) return;
  map.set(addr, (map.get(addr) ?? 0n) + wei);
}

function formatDate(sec: number): string {
  return new Date(sec * 1000).toISOString();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const windowStart = args.windowEnd - WINDOW_SECONDS;

  console.error(`Epoch ${args.epoch} window: [${formatDate(windowStart)}, ${formatDate(args.windowEnd)})`);
  console.error(`Rewards: ${args.rewardsAddr}`);
  console.error(`RPC:     ${args.rpcUrl.replace(/\/[^/]+$/, "/***")}`);
  console.error(`Indexer: ${args.indexerUrl}`);

  const [balance, challenges, puzzles] = await Promise.all([
    fetchBalanceWei(args.rpcUrl, args.rewardsAddr),
    fetchChallenges(args.indexerUrl, windowStart, args.windowEnd),
    fetchPuzzles(args.indexerUrl, windowStart, args.windowEnd),
  ]);

  console.error(`Balance: ${balance} wei  (pool = ${balance / 2n})`);
  console.error(`Window activity: ${challenges.length} challenges, ${puzzles.length} puzzles`);

  const pool = balance / 2n;
  if (pool === 0n) die("pool is zero (contract balance = 0); nothing to distribute");

  const guesserStreakPool = (pool * 30n) / 100n;
  const creatorStreakPool = (pool * 20n) / 100n;
  const topCreatorPool = (pool * 25n) / 100n;
  const topSolverPool = (pool * 25n) / 100n;

  const guesserStreaks = computeGuesserStreaks(challenges);
  const creatorStreaks = computeCreatorStreaks(puzzles);
  const creators = topCreators(puzzles);
  const solvers = topSolvers(challenges);

  const amounts = new Map<string, bigint>();

  if (guesserStreaks.size > 0) {
    const share = guesserStreakPool / BigInt(guesserStreaks.size);
    for (const addr of guesserStreaks) addAmount(amounts, addr, share);
    console.error(`Guesser streak: ${guesserStreaks.size} eligible × ${share} wei`);
  } else {
    console.error(`Guesser streak: 0 eligible (pool ${guesserStreakPool} rolls forward)`);
  }

  if (creatorStreaks.size > 0) {
    const share = creatorStreakPool / BigInt(creatorStreaks.size);
    for (const addr of creatorStreaks) addAmount(amounts, addr, share);
    console.error(`Creator streak: ${creatorStreaks.size} eligible × ${share} wei`);
  } else {
    console.error(`Creator streak: 0 eligible (pool ${creatorStreakPool} rolls forward)`);
  }

  if (creators.length > 0) {
    for (let i = 0; i < creators.length; i++) {
      const share = (topCreatorPool * TOP3_WEIGHTS[i]!) / 100n;
      addAmount(amounts, creators[i]![0], share);
    }
    console.error(`Top creators: ${creators.map(([a, n]) => `${a} (${n})`).join(", ")}`);
  } else {
    console.error(`Top creators: 0 (pool ${topCreatorPool} rolls forward)`);
  }

  if (solvers.length > 0) {
    for (let i = 0; i < solvers.length; i++) {
      const share = (topSolverPool * TOP3_WEIGHTS[i]!) / 100n;
      addAmount(amounts, solvers[i]![0], share);
    }
    console.error(`Top solvers: ${solvers.map(([a, n]) => `${a} (${n})`).join(", ")}`);
  } else {
    console.error(`Top solvers: 0 (pool ${topSolverPool} rolls forward)`);
  }

  if (amounts.size === 0) die("no eligible recipients across all categories; skip this epoch");

  const total = [...amounts.values()].reduce((a, b) => a + b, 0n);
  if (total > pool) die(`sanity check failed: total ${total} > pool ${pool}`);

  console.error(`Recipients: ${amounts.size}, total payout: ${total} wei (dust to contract: ${pool - total})`);

  const rows = [...amounts.entries()].sort(([a], [b]) => a.localeCompare(b));
  const csv = ["address,amount_wei", ...rows.map(([addr, wei]) => `${addr},${wei}`)].join("\n") + "\n";

  if (args.dryRun) {
    process.stdout.write(csv);
  } else {
    writeFileSync(args.out, csv);
    console.error(`Wrote ${args.out}`);
  }
}

main().catch((e) => die(e instanceof Error ? e.message : String(e)));
