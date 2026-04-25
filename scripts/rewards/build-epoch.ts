#!/usr/bin/env bun
/**
 * Build a Rewards epoch from a recipients CSV.
 *
 * Usage:
 *   bun run scripts/rewards/build-epoch.ts <recipients.csv> --epoch <N> [--out <dir>]
 *
 * Output (under <out>/<epoch>/):
 *   - recipients.csv          archived copy of input
 *   - root.txt                bytes32 hex root, single line, no newline
 *   - tree.json               StandardMerkleTree.dump() for audit / re-derivation
 *   - manifest.json           {epoch, root, totalWei, recipientCount, generatedAt}
 *   - <addr-lower>.json       per-recipient { amount: <wei-decimal>, proof: [hex,...] }
 *
 * The leaf hash matches Rewards.sol exactly:
 *   keccak256(bytes.concat(keccak256(abi.encode(address, uint256))))
 *
 * Safety:
 *   --out must be a clone of chainhackers/zk-guess-rewards (verified via .git/config)
 *   <out>/<epoch>/ must not already exist (operator deletes manually if re-running)
 */

import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

interface Recipient {
  address: `0x${string}`;
  amountWei: bigint;
}

const REWARDS_REMOTE = "chainhackers/zk-guess-rewards";

function die(msg: string): never {
  console.error(`Error: ${msg}`);
  process.exit(1);
}

function parseArgs(argv: string[]): { csv: string; epoch: number; out: string } {
  const positional: string[] = [];
  let epoch: number | undefined;
  let out: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--epoch") {
      const v = argv[++i];
      if (!v) die("--epoch requires a value");
      epoch = Number(v);
    } else if (a === "--out") {
      out = argv[++i];
      if (!out) die("--out requires a value");
    } else if (a.startsWith("--")) {
      die(`unknown flag: ${a}`);
    } else {
      positional.push(a);
    }
  }
  if (positional.length !== 1) die("expected exactly one positional <recipients.csv>");
  if (epoch === undefined || !Number.isInteger(epoch) || epoch < 1) {
    die("--epoch must be a positive integer");
  }
  return {
    csv: resolve(positional[0]),
    epoch,
    out: resolve(out ?? join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "zk-guess-rewards")),
  };
}

function parseCsv(path: string): Recipient[] {
  const raw = readFileSync(path, "utf8");
  const lines = raw.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) die("CSV is empty");

  const firstLineLooksLikeAddress = /^0x[0-9a-fA-F]{40}\s*,/.test(lines[0]);
  const dataLines = firstLineLooksLikeAddress ? lines : lines.slice(1);
  if (dataLines.length === 0) die("CSV has no data rows");

  const seen = new Set<string>();
  const out: Recipient[] = [];
  for (const [i, line] of dataLines.entries()) {
    const parts = line.split(",").map((s) => s.trim());
    if (parts.length !== 2) die(`row ${i + 1}: expected exactly two columns, got ${parts.length}`);
    const [addr, amountStr] = parts;
    if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) die(`row ${i + 1}: not a valid address: ${addr}`);
    const lower = addr.toLowerCase();
    if (seen.has(lower)) die(`row ${i + 1}: duplicate address ${lower}`);
    seen.add(lower);
    let amount: bigint;
    try {
      amount = BigInt(amountStr);
    } catch {
      die(`row ${i + 1}: amount is not an integer: ${amountStr}`);
    }
    if (amount <= 0n) die(`row ${i + 1}: amount must be positive, got ${amountStr}`);
    out.push({ address: addr as `0x${string}`, amountWei: amount });
  }
  return out;
}

function assertOutIsRewardsRepo(outDir: string) {
  let remotes: string;
  try {
    remotes = execFileSync("git", ["-C", outDir, "remote", "-v"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch {
    die(`--out ${outDir} is not a git repo. Clone ${REWARDS_REMOTE} first.`);
  }
  // Match the exact org/repo path on a remote URL boundary so siblings like
  // "zk-guess-rewards-backup" are rejected. The path must be preceded by ":" or "/"
  // (URL boundary) and followed by optional ".git" then whitespace/EOL (end of URL token).
  const escaped = REWARDS_REMOTE.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`[:/]${escaped}(\\.git)?(?=\\s|$)`);
  if (!re.test(remotes)) {
    die(`--out ${outDir} does not have ${REWARDS_REMOTE} as a remote. Refusing to write.`);
  }
}

function main() {
  const { csv, epoch, out } = parseArgs(process.argv.slice(2));
  if (!existsSync(csv)) die(`CSV not found: ${csv}`);
  assertOutIsRewardsRepo(out);

  const epochDir = join(out, String(epoch));
  if (existsSync(epochDir)) {
    die(`epoch directory already exists: ${epochDir}. Delete it manually before rebuilding.`);
  }

  const recipients = parseCsv(csv);
  const totalWei = recipients.reduce((sum, r) => sum + r.amountWei, 0n);

  const tree = StandardMerkleTree.of(
    recipients.map((r) => [r.address, r.amountWei]),
    ["address", "uint256"],
  );

  mkdirSync(epochDir, { recursive: true });
  copyFileSync(csv, join(epochDir, "recipients.csv"));
  writeFileSync(join(epochDir, "root.txt"), tree.root);
  const bigIntReplacer = (_: string, v: unknown) => (typeof v === "bigint" ? v.toString() : v);
  writeFileSync(join(epochDir, "tree.json"), JSON.stringify(tree.dump(), bigIntReplacer, 2));

  for (const [i, [addr, amt]] of tree.entries()) {
    const proof = tree.getProof(i);
    const payload = {
      amount: (amt as bigint).toString(),
      proof,
    };
    writeFileSync(
      join(epochDir, `${(addr as string).toLowerCase()}.json`),
      JSON.stringify(payload, null, 2),
    );
  }

  const manifest = {
    epoch,
    root: tree.root,
    totalWei: totalWei.toString(),
    recipientCount: recipients.length,
    generatedAt: new Date().toISOString(),
  };
  writeFileSync(join(epochDir, "manifest.json"), JSON.stringify(manifest, null, 2));

  console.log(`epoch ${epoch}: ${recipients.length} recipients, totalWei=${totalWei}`);
  console.log(`root: ${tree.root}`);
  console.log(`written to: ${epochDir}`);
  console.log("");
  console.log("Next: publish the root on-chain, then `git push` from the rewards repo.");
}

main();
