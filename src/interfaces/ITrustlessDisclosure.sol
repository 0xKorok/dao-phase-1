// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITrustlessDisclosure {
    enum State { Created, Signed }
    
    function state() external view returns (State);
    function requestedReward() external view returns (uint256);
}