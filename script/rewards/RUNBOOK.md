# Rewards epoch publishing runbook

How to publish a new `Rewards` epoch on Base mainnet so users can claim from `/rewards` on the frontend.

The Rewards contract (`src/Rewards.sol`) holds ETH and pays out per-epoch via merkle proofs. Eligibility is decided off-chain (currently a hand-edited CSV; future task will automate). This runbook is the manual operator loop until the rules engine lands.

## Topology

- **Tooling** (this repo, `chainhackers/zk-guess-contracts`): merkle builder + on-chain publisher.
- **Archive + feed** (`chainhackers/zk-guess-rewards`, GitHub Pages): every epoch's CSV, merkle tree dump, root, manifest, and per-recipient proof JSONs. The frontend fetches `https://chainhackers.github.io/zk-guess-rewards/<N>/<addr-lower>.json`.
- **Indexer** (`chainhackers/zk-guess-indexer`): subscribes to `RootPublished` and `Claimed`; the frontend's epoch list comes from its GraphQL endpoint.
- **Frontend** (`chainhackers/zk-guess`): `/rewards` page reads epochs from indexer, fetches proof from Pages, calls `Rewards.claim`.

## One-time setup

Clone the rewards archive as a sibling of this repo:

```bash
git clone git@github.com:chainhackers/zk-guess-rewards.git ../zk-guess-rewards
```

Confirm GitHub Pages is enabled on `main` / root for `chainhackers/zk-guess-rewards` and serves at <https://chainhackers.github.io/zk-guess-rewards/>. Confirm the frontend's `VITE_REWARDS_EPOCH_FEED_URL` env var (preview + production scopes on Vercel) matches.

Install deps once:

```bash
bun install
```

## Per-epoch loop

### 1. Prepare recipients CSV

Two columns, no quoting, one recipient per line. Header optional. Amounts in wei (decimal integers).

```csv
address,amount_wei
0x4c7ae65565a8df70cbab1b8a504c56e39da59b7a,100000000000000
0x95c5...da0d,100000000000000
```

Keep the CSV out of git history (the builder copies it into the archive automatically). One way: edit `/tmp/epoch-<N>.csv`.

### 2. Build the epoch artifacts

```bash
bun run scripts/rewards/build-epoch.ts /tmp/epoch-1.csv --epoch 1
```

Writes `../zk-guess-rewards/1/`:

- `recipients.csv` — archived copy of the input
- `root.txt` — single-line bytes32 root, no trailing newline
- `tree.json` — full `StandardMerkleTree.dump()` for re-derivation / audit
- `<addr-lower>.json` — one per recipient: `{"amount": "<wei-decimal>", "proof": ["0x…", …]}`
- `manifest.json` — `{epoch, root, totalWei, recipientCount, generatedAt}`

The builder refuses to overwrite an existing `<out>/<N>/`. Delete it manually if you need to rebuild before publishing.

### 3. Confirm contract balance

Sum of payouts must be ≤ contract balance (the contract auto-funds from forfeit collateral but seed it manually for the first epoch):

```bash
source .env  # exports BASE_MAINNET_RPC, etc.
TOTAL=$(jq -r .totalWei ../zk-guess-rewards/1/manifest.json)
BAL=$(cast balance 0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c --rpc-url $BASE_MAINNET_RPC | sed 's/ \[.*//g')
echo "needed=$TOTAL  have=$BAL"
```

If short:

```bash
DIFF=$(echo "$TOTAL - $BAL" | bc)
cast send 0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c --value $DIFF --account deployer --rpc-url $BASE_MAINNET_RPC
```

### 4. Publish the root on-chain

```bash
ROOT=$(cat ../zk-guess-rewards/1/root.txt) \
REWARDS_ADDR=0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c \
forge script script/rewards/PublishRoot.s.sol \
  --rpc-url $BASE_MAINNET_RPC \
  --account deployer \
  --broadcast
```

Run this with the account that owns `Rewards`; ownership is enforced on-chain by `publishRoot`'s `onlyOwner`, so a wrong `--account` reverts the tx. Optionally pass `EXPECTED_EPOCH=<N>` to guard against races — the script asserts `prevEpoch + 1 == EXPECTED_EPOCH` before broadcasting. Logs the assigned epoch number.

### 5. Push the feed

```bash
cd ../zk-guess-rewards
git add 1/
git commit -m "feat: epoch 1"
git push origin main
```

GitHub Pages redeploys within ~30s.

### 6. Smoke test

Verify the feed serves the proof:

```bash
ADDR=0x4c7ae65565a8df70cbab1b8a504c56e39da59b7a
curl -s "https://chainhackers.github.io/zk-guess-rewards/1/$(printf '%s' "$ADDR" | tr '[:upper:]' '[:lower:]').json" | jq .
```

Verify the indexer ingested `RootPublished`:

```bash
curl -s -X POST https://indexer.hyperindex.xyz/aa21ad1/v1/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ RewardEpoch(order_by: {epoch: desc}, limit: 1) { epoch root } }"}'
```

Open <https://zk-guess.chainhackers.xyz/rewards> with the recipient wallet connected. You should see an `EPOCH_1` card with a `[CLAIM]` button. Click → wallet signs → tx confirms → ETH arrives → card flips to a `CLAIM_TX` link. Within ~60s the indexer's `RewardClaim` entity is populated and the page would re-render the same card as `CLAIMED` on a fresh load.

## Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Builder errors `--out … does not have chainhackers/zk-guess-rewards as a remote` | Pointed `--out` at the wrong dir | Pass the correct path or omit (defaults to `../zk-guess-rewards`) |
| Builder errors `epoch directory already exists` | Re-running on the same epoch number | `rm -rf ../zk-guess-rewards/<N>/`, then re-run |
| `publishRoot` reverts with `OwnableUnauthorizedAccount` | Deployer keystore doesn't match the contract owner | Use the right `--account` |
| Forge script reverts with `InvalidRoot` | `root.txt` is `0x000…` | Builder bug; report. Do not publish. |
| Frontend shows `NO_REWARDS_AVAILABLE` for a known recipient | Pages hasn't redeployed yet, or addr case mismatch | Wait 60s; verify `<addr-lower>.json` exists in the repo (lowercase) |
| `Rewards.claim` reverts with `InvalidProof` | Wrong proof JSON for the published root | Hard-refresh; if still broken, the feed is out of sync with the on-chain root — investigate before announcing |
| `Rewards.claim` reverts with `TransferFailed` | Contract balance < amount | Top up via `cast send` and let the user retry |

## Rollback

`publishRoot` is monotonic — no on-chain undo. But funds only move on `claim`, and `claim` requires the proof. If the root hashes a bad amount or recipient list, just don't publish the per-user JSONs (no one can claim without them) and publish a corrected root at epoch `N+1`. Communicate the abandoned epoch transparently.
