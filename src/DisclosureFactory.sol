// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./TimelockTreasury.sol";
import "./TrustlessDisclosure.sol";

/**
 * @title DisclosureFactory
 * @notice Factory contract for permissionless deployment of TrustlessDisclosure instances
 */
contract DisclosureFactory is Ownable {
     TimelockTreasury public immutable treasury;
    IERC20 public immutable trustlessRep; // TDREP token 
    uint256 public deploymentFee = 1 ether; // 1 TDREP (18 decimals) (placeholder)
    
    // Mapping to track all deployments
    mapping(address => bool) public isDisclosure;
    
    event DisclosureDeployed(
        address indexed disclosure,
        address indexed owner,
        address indexed participant,
        uint256 initialPayment,
        uint256 participantClaimDays,
        uint256 ownerClaimDays
    );
    event DeploymentFeeUpdated(uint256 oldFee, uint256 newFee);
    
    error InsufficientFee();
    error FeeTransferFailed();
    
    constructor(address _trustlessRep, address _owner) Ownable(_owner) {
        trustlessRep = IERC20(_trustlessRep);
    }
    
    /**
     * @notice Deploys a new TrustlessDisclosure contract
     * @param participant Address of the participant
     * @param initialPayment Initial good faith payment amount
     * @param participantClaimDays Days until participant can claim
     * @param ownerClaimDays Days until owner can claim
     * @param gasReserve Amount to reserve for gas
     * @return disclosure Address of the deployed contract
     */
    function deployDisclosure(
        address participant,
        uint256 initialPayment,
        uint256 participantClaimDays,
        uint256 ownerClaimDays,
        uint256 gasReserve
    ) external returns (address disclosure) {
        // Check and collect deployment fee
        if (trustlessRep.balanceOf(msg.sender) < deploymentFee) {
            revert InsufficientFee();
        }
        
        bool success = trustlessRep.transferFrom(
            msg.sender, 
            address(treasury),
            deploymentFee
        );
        if (!success) {
            revert FeeTransferFailed();
        }
        
        // Deploy new disclosure contract
        disclosure = address(new TrustlessDisclosure(
            participant,
            initialPayment,
            participantClaimDays,
            ownerClaimDays,
            gasReserve
        ));
        
        // Record deployment
        isDisclosure[disclosure] = true;
        
        emit DisclosureDeployed(
            disclosure,
            msg.sender,
            participant,
            initialPayment,
            participantClaimDays,
            ownerClaimDays
        );
    }
    
    /**
     * @notice Updates the deployment fee
     * @param newFee New fee amount in TDREP tokens
     */
    function setDeploymentFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = deploymentFee;
        deploymentFee = newFee;
        emit DeploymentFeeUpdated(oldFee, newFee);
    }
    
    /**
     * @notice Checks if an address is a disclosure deployed by this factory
     * @param query Address to check
     * @return bool True if address is a deployed disclosure
     */
    function isDeployedDisclosure(address query) external view returns (bool) {
        return isDisclosure[query];
    }
}