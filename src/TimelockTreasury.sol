// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TimelockTreasury
 * @notice Treasury with timelock protection for significant actions
 * @dev Designed to be upgradeable to multisig in the future
 */
contract TimelockTreasury is Ownable, ReentrancyGuard {
    uint256 public constant TIMELOCK_DURATION = 2 days;
    uint256 public constant EMERGENCY_THRESHOLD = 1 ether; // Amounts above this require timelock

    struct TimelockOperation {
        bytes32 operationHash;
        uint256 timestamp;
        bool executed;
    }

    mapping(bytes32 => TimelockOperation) public timelockOperations;
    
    event OperationQueued(bytes32 indexed operationHash, uint256 timestamp);
    event OperationExecuted(bytes32 indexed operationHash);
    event EmergencyWithdrawal(address token, uint256 amount);
    
    error TimelockNotExpired();
    error OperationNotQueued();
    error OperationAlreadyExecuted();
    error TransferFailed();

    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Queue a large withdrawal for timelock
     * @param token Token address (use address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function queueWithdrawal(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(amount > EMERGENCY_THRESHOLD, "Use emergency withdrawal");
        
        bytes32 operationHash = keccak256(
            abi.encode(token, to, amount)
        );
        
        timelockOperations[operationHash] = TimelockOperation({
            operationHash: operationHash,
            timestamp: block.timestamp + TIMELOCK_DURATION,
            executed: false
        });
        
        emit OperationQueued(operationHash, block.timestamp + TIMELOCK_DURATION);
    }

    /**
     * @notice Execute a queued withdrawal after timelock expires
     * @param token Token address (use address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function executeWithdrawal(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        bytes32 operationHash = keccak256(
            abi.encode(token, to, amount)
        );
        
        TimelockOperation storage operation = timelockOperations[operationHash];
        
        if (operation.timestamp == 0) revert OperationNotQueued();
        if (operation.executed) revert OperationAlreadyExecuted();
        if (block.timestamp < operation.timestamp) revert TimelockNotExpired();
        
        operation.executed = true;
        
        _executeTransfer(token, to, amount);
        emit OperationExecuted(operationHash);
    }

    /**
     * @notice Emergency withdrawal for small amounts (no timelock)
     * @param token Token address (use address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(amount <= EMERGENCY_THRESHOLD, "Amount exceeds emergency threshold");
        _executeTransfer(token, to, amount);
        emit EmergencyWithdrawal(token, amount);
    }

    function _executeTransfer(
        address token,
        address to,
        uint256 amount
    ) private {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(token).transfer(to, amount);
            if (!success) revert TransferFailed();
        }
    }

    receive() external payable {}
}