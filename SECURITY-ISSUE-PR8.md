# ZK Proof Public Input Manipulation Vulnerability

**Related:** [PR #8](https://github.com/chainhackers/zk-guess-contracts/pull/8), [Issue #5](https://github.com/chainhackers/zk-guess-contracts/issues/5)

## Summary

The `guess` input in the ZK circuit is private, allowing creators to generate proofs for arbitrary guess values and use them to respond to challenges with different guesses.

## Vulnerable Code

**Circuit** (`circuits/guess.circom:40`):
```circom
component main = GuessNumber();  // guess is PRIVATE
```

**Contract** (`src/GuessGame.sol:75-94`):
```solidity
function respondToChallenge(
    uint256 challengeId,
    uint[2] calldata _pA,
    uint[2][2] calldata _pB,
    uint[2] calldata _pC,
    uint[2] calldata _pubSignals  // only [commitment, isCorrect]
) external {
    // ...
    if (!verifier.verifyProof(_pA, _pB, _pC, _pubSignals)) revert InvalidProof();

    bytes32 commitment = bytes32(_pubSignals[0]);
    bool isCorrect = _pubSignals[1] == 1;

    if (commitment != puzzle.commitment) revert InvalidProof();
    // NO CHECK: proof's guess == challenge.guess
}
```

## Attack Vector

1. Player submits challenge with `guess = 42` (correct answer)
2. Creator generates proof using `guess = 99` instead
3. Proof outputs `isCorrect = 0` (since 99 ≠ secret)
4. Contract accepts proof — commitment matches, proof is valid
5. Creator steals player's stake by claiming correct guesses are wrong

## Fix (PR #8)

1. **Circuit**: Expose `guess` as public signal
   ```circom
   component main {public [guess]} = GuessNumber();
   ```

2. **Contract**: Verify proof's guess matches challenge
   ```solidity
   uint[3] calldata _pubSignals  // [commitment, isCorrect, guess]
   // ...
   if (proofGuess != challenge.guess) revert InvalidProofForChallengeGuess();
   ```

## Impact

- **Severity**: Critical
- **Type**: Proof substitution / public input manipulation
- **Affected**: All challenges where creator is dishonest
