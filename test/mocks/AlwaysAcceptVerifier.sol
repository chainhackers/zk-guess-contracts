// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Always-accept Groth16 verifier mock supporting both the v1 ([4]) and v2 ([6])
/// public-signal shapes. Lets a single deployment serve a v1 mock pre-upgrade and the
/// new GuessGame post-upgrade through the same proxy storage slot.
contract AlwaysAcceptVerifier {
    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[4] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function verifyProof(uint256[2] calldata, uint256[2][2] calldata, uint256[2] calldata, uint256[6] calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }
}
