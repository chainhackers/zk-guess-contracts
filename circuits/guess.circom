pragma circom 2.1.6;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

template GuessNumber() {
    signal input number;
    signal input salt;
    signal input guess;
    
    signal output commitment;
    signal output isCorrect;
    
    // Range constraints: ensure number is between 1 and 100
    // Check number >= 1
    component geq1 = GreaterEqThan(8); // 8 bits is enough for numbers up to 255
    geq1.in[0] <== number;
    geq1.in[1] <== 1;
    geq1.out === 1;
    
    // Check number <= 100
    component leq100 = LessEqThan(8);
    leq100.in[0] <== number;
    leq100.in[1] <== 100;
    leq100.out === 1;
    
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
