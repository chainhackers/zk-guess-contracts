pragma circom 2.1.6;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

template GuessNumber() {
    signal input number;
    signal input salt;
    signal input guess;
    
    signal output commitment;
    signal output isCorrect;
    
    // Range constraints: ensure number is between 1 and 65535
    // Check number >= 1
    component geq1 = GreaterEqThan(16); // 16 bits for numbers up to 65535
    geq1.in[0] <== number;
    geq1.in[1] <== 1;
    geq1.out === 1;

    // Check number <= 65535
    component leq65535 = LessEqThan(16);
    leq65535.in[0] <== number;
    leq65535.in[1] <== 65535;
    leq65535.out === 1;
    
    // Generate commitment using Poseidon hash
    component hasher = Poseidon(2);
    hasher.inputs[0] <== number;
    hasher.inputs[1] <== salt;
    commitment <== hasher.out;
    
    // Check if guess matches number
    component eq = IsEqual();
    eq.in[0] <== guess;
    eq.in[1] <== number;
    isCorrect <== eq.out;
}

component main {public [guess]} = GuessNumber();
