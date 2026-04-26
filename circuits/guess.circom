pragma circom 2.1.6;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

template GuessNumber() {
    // keccak256("zkguess.v2") mod p(BN254). Domain-separates v2 commitments
    // from v1 Poseidon(2) commitments and from any future version. If this value
    // is mirrored in application code, update both definitions together so the
    // circuit and off-chain commitment logic cannot drift.
    var DOMAIN_TAG = 6000605569458108169701754207643449997818461959397281845176039583157698733685;

    signal input number;
    signal input salt;
    signal input guess;
    signal input maxNumber; // Creator-defined max (1-65535)
    signal input puzzleId;  // Binds the proof to a specific puzzle
    signal input guesser;   // Binds the proof to a specific Ethereum address (uint160)

    signal output commitment;
    signal output isCorrect;

    // Force puzzleId and guesser into the constraint system so the proof cannot
    // be replayed on another puzzle or front-run under a different msg.sender
    // even if the witness would otherwise be identical.
    signal puzzleIdSquared;
    puzzleIdSquared <== puzzleId * puzzleId;
    signal guesserSquared;
    guesserSquared <== guesser * guesser;

    // Range constraints: ensure number is between 1 and maxNumber
    // Check number >= 1
    component geq1 = GreaterEqThan(16); // 16 bits for numbers up to 65535
    geq1.in[0] <== number;
    geq1.in[1] <== 1;
    geq1.out === 1;

    // Check number <= maxNumber (creator's custom range)
    component leqMax = LessEqThan(16);
    leqMax.in[0] <== number;
    leqMax.in[1] <== maxNumber;
    leqMax.out === 1;

    // Check maxNumber <= 65535 (enforce upper bound)
    component leq65535 = LessEqThan(16);
    leq65535.in[0] <== maxNumber;
    leq65535.in[1] <== 65535;
    leq65535.out === 1;

    // Check maxNumber >= 1 (enforce lower bound)
    component maxGeq1 = GreaterEqThan(16);
    maxGeq1.in[0] <== maxNumber;
    maxGeq1.in[1] <== 1;
    maxGeq1.out === 1;

    // Range-check guess: 1 <= guess <= maxNumber
    // Symmetric with the constraints on `number` so the proof layer, not the UI,
    // guarantees well-formed guesses.
    component guessGeq1 = GreaterEqThan(16);
    guessGeq1.in[0] <== guess;
    guessGeq1.in[1] <== 1;
    guessGeq1.out === 1;

    component guessLeqMax = LessEqThan(16);
    guessLeqMax.in[0] <== guess;
    guessLeqMax.in[1] <== maxNumber;
    guessLeqMax.out === 1;

    component hasher = Poseidon(3);
    hasher.inputs[0] <== DOMAIN_TAG;
    hasher.inputs[1] <== number;
    hasher.inputs[2] <== salt;
    commitment <== hasher.out;

    component eq = IsEqual();
    eq.in[0] <== guess;
    eq.in[1] <== number;
    isCorrect <== eq.out;
}

component main {public [guess, maxNumber, puzzleId, guesser]} = GuessNumber();
