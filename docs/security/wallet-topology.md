# Wallet topology — three-role separation

Three distinct keypairs control the v2 deployment. None of them ever creates a puzzle,
submits a guess, or claims a reward. This document records each address, its provenance
(where its ETH came from), and what it is allowed to do.

The split exists to break the v1 deployer/owner/funder monolith that drew Blockaid
clustering attention. New deployer, new owner, new funder — all distinct, all disclosed.

## Roles

| Role | What it does | What it never does |
|---|---|---|
| **Deployer** | One-shot: deploys `GuessVerifier`, `Rewards`, `GuessGame` impl, `ERC1967Proxy`, calls `initialize` with the operator as owner. Retired forever after the deploy tx batch. | Never owns the contracts. Never plays. Never funds. Never receives admin txs. |
| **Funding** | Receives ETH from a single, disclosed CEX withdrawal (the exchange name and tx hash are recorded below and in the Blockaid submission). Tops up the rewards pool via `Rewards.fundRewards("donation")`. Pays operator gas. Sends exact-gas to deployer for the one-shot deploy. Seeds external incentive campaigns (boost.xyz, Farcaster mini-app boosts) with single-hop transfers to the campaign contract — boost.xyz pays winners directly from its own escrow, funding never routes per-user rewards itself. | Never deploys. Never plays. Never owns anything. No DEX swaps, no contract intermediaries on the inbound path, no per-user payouts on the outbound path. |
| **Operator** | Owner of `GuessGame` proxy and `Rewards`. Calls `pause()`, `publishRoot()`, `settleNext()`, `settleAll()`. | Never deploys. Never plays. Never receives ETH from any non-funding source. |

**Operational rule:** any of the three operators wanting to play uses a separate
disclosed wallet, never linked to the operator funding graph.

## Address registry (v2)

| Role | Address | Funded from | First tx | Notes |
|---|---|---|---|---|
| Deployer | [`0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d`](https://basescan.org/address/0x5A089E9Ca9AB8259d024CFBEe697B975cAea861d) | Funding (exact gas, ≤0.01 ETH) | <!-- TODO: deploy tx hash --> | Retired after deploy. Public attestation: "this address only ever deploys." |
| Funding | [`0x0eE9931E50aaD6fB6Fb42BB61B8c2fCA6d757865`](https://basescan.org/address/0x0eE9931E50aaD6fB6Fb42BB61B8c2fCA6d757865) | <!-- TODO: exchange name + tx hash; single CEX withdrawal, no DEX/contract intermediaries --> | <!-- TODO: CEX hot wallet → funding tx hash --> | No DEX swaps, no contract intermediaries, no chain-hop on the funding path. The exchange is named explicitly to make the actor graph auditable end-to-end. |
| Operator | [`0xa3369e05999eC082f54817a0a991916780F8bdC4`](https://basescan.org/address/0xa3369e05999eC082f54817a0a991916780F8bdC4) | Funding (operator gas) | <!-- TODO: first inbound tx hash --> | `owner()` of `Rewards` and `GuessGame` proxy. |

Phase B keygen complete (2026-05-03). Outstanding TODOs above are filled in
post-funding (CEX withdrawal trace) and post-deploy (deploy tx hash). Keystores live
locally at `~/.zkguess-keystores/zkg-{deployer,funding,operator}` (not in git;
backed up to offline cold storage with separate passwords).

## v1 (legacy, do not interact)

The v1 deployment used a single monolithic EOA for deployer / owner / funding / playtest.
That address is documented here for transparency; it is **not** a v2 role.

| What | Address |
|---|---|
| v1 monolithic EOA (deployer + owner + funder + playtest) | [`0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A`](https://basescan.org/address/0x4c7AE65565a8DF70cbAB1b8a504c56E39da59B7A) |
| v1 `GuessGame` proxy | [`0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590`](https://basescan.org/address/0xa05ebcf0f9aab5194c8a3ec8571a1d85d0a7f590) |
| v1 `Rewards` | [`0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c`](https://basescan.org/address/0x3f403b992a4b0a2a8820e8818cac17e6f7cd8c1c) |
| v1 `GuessVerifier` | [`0xface0e73719e78e3bb020001fd10b62af9b3b6b8`](https://basescan.org/address/0xface0e73719e78e3bb020001fd10b62af9b3b6b8) |
| Pre-v1 settled proxy | [`0xfa37cdcff862114c88c8e19b10b362d611a2c45f`](https://basescan.org/address/0xfa37cdcff862114c88c8e19b10b362d611a2c45f) — settled and renounced 2026-04-16 |

The v1 contracts will be permanently sealed via `settleAll(...)` as part of the v2 cutover
(Phase F of the redeploy plan). The v1 monolithic EOA is *not* used as a v2 role and has
no admin authority on the v2 stack.

## Why three roles, not one

A clustering heuristic (Blockaid's, others) cannot read the circuit and will judge by
the actor graph. v1 collapsed every role into a single EOA that also played the game,
making the contract day-zero-taintable via the creation graph alone. v2 separates the
roles so:

- Deployer is provably one-shot (only ever deploys; no other history before or after).
- Funding's provenance starts at a named, regulated CEX, not a DEX or another contract.
- Operator's surface is small (`pause`, `publishRoot`, `settleNext`/`settleAll`) and
  every admin tx it sends is to a contract that emits structured events.

The graph is auditable. None of the three roles ever appears as a `creator` in
`PuzzleCreated`, a `guesser` in `ChallengeCreated`, or a recipient in `ForfeitClaimed` /
`SettledPaid`.

## Auditing the rule

A simple subgraph query confirms compliance:

```
PuzzleCreated.creator     ∩ {Deployer, Funding, Operator} = ∅
ChallengeCreated.guesser  ∩ {Deployer, Funding, Operator} = ∅
ForfeitClaimed.guesser    ∩ {Deployer, Funding, Operator} = ∅
SettledPaid.recipient     ∩ {Deployer, Funding, Operator} = ∅
```

If any of those intersections is ever non-empty, the rule has been violated and should
be disclosed and remediated.

## Future: multisig

Operator is currently an EOA. Migrating to a Safe multisig is tracked as Phase G in the
[clean-redeploy spec](../superpowers/specs/2026-04-23-clean-redeploy-antimixer-design.md);
the current admin surface (three functions, two of which are time-gated by `canSettle`)
doesn't justify multisig friction yet, but this will be revisited once v2 is stable.
