// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./TrustlessDisclosure.sol";

/**
 * @title DisclosureFactory
 * @notice Factory contract for permissionless deployment of TrustlessDisclosure instances
 * @dev Includes basic analytics tracking and input validation
 */
contract DisclosureFactory is Ownable {
    address public immutable treasury;
    IERC20 public immutable trustlessRep;
    
    uint256 public feePercentage;
    uint256 public minReward;

    // Core deployment tracking
    mapping(address => bool) public isDisclosure;
    mapping(address => bool) public hasDeploymentFeeWaiver;
    
    // Analytics tracking
    mapping(address => uint256) public researcherTotalRequested;
    mapping(address => uint256) public researcherSuccessfulDisclosures;
    
    event FeePercentageUpdated(uint256 oldFee, uint256 newFee);
    event MinRewardUpdated(uint256 oldMin, uint256 newMin);
    event FeeWaiverGranted(address indexed user, bool deploymentWaiver);
    event DisclosureDeployed(
        address indexed disclosure,
        address indexed owner,
        address indexed participant,
        TrustlessDisclosure.Severity severity,
        uint256 requestedReward,
        bytes32 commitHash
    );
    event DisclosureAccepted(
        address indexed disclosure,
        address indexed researcher,
        uint256 requestedReward
    );
    
    error FeePercentageTooHigh();
    error InvalidMinReward();
    error InsufficientFee();
    error FeeTransferFailed();
    error RewardTooLow();
    error InvalidCommitHash();
    error InvalidParticipant();
    error SelfDealingNotAllowed();

    constructor(
        address _trustlessRep, 
        address _treasury
    ) Ownable(msg.sender) {
        trustlessRep = IERC20(_trustlessRep);
        treasury = _treasury;
        feePercentage = 5; // 5% initial fee
        minReward = 0.1 ether; // Initial minimum reward
    }

    function setFeePercentage(uint256 newFeePercentage) external onlyOwner {
        if (newFeePercentage > 10) revert FeePercentageTooHigh(); // Cap at 10%
        uint256 oldFee = feePercentage;
        feePercentage = newFeePercentage;
        emit FeePercentageUpdated(oldFee, newFeePercentage);
    }

    function setMinReward(uint256 newMinReward) external onlyOwner {
        if (newMinReward == 0) revert InvalidMinReward();
        uint256 oldMin = minReward;
        minReward = newMinReward;
        emit MinRewardUpdated(oldMin, newMinReward);
    }

    function calculateDeploymentFee(uint256 requestedReward) public view returns (uint256) {
        return (requestedReward * feePercentage) / 100;
    }
    
    function grantDeploymentFeeWaiver(address user, bool waiver) external onlyOwner {
        hasDeploymentFeeWaiver[user] = waiver;
        emit FeeWaiverGranted(user, waiver);
    }

    /**
     * @notice Validates input parameters for disclosure deployment
     * @param participant Address of the participant
     * @param requestedReward Requested reward amount
     * @param commitHash Hash of the vulnerability details
     */
    function _validateInputs(
        address participant,
        uint256 requestedReward,
        bytes32 commitHash
    ) internal view {
        // Validate minimum reward
        if (requestedReward < minReward) {
            revert RewardTooLow();
        }

        // Validate commit hash format
        if (commitHash == bytes32(0)) {
            revert InvalidCommitHash();
        }

        // Validate participant address
        if (participant == address(0)) {
            revert InvalidParticipant();
        }

        // Prevent self-dealing
        if (participant == msg.sender) {
            revert SelfDealingNotAllowed();
        }
    }
    
    /**
     * @notice Deploys a new TrustlessDisclosure contract
     * @param participant Address of the participant (protocol)
     * @param severity Initial severity assessment
     * @param requestedReward Initial requested reward amount
     * @param commitHash Hash of the vulnerability details
     * @return disclosure Address of the deployed contract
     */
    function deployDisclosure(
        address participant,
        TrustlessDisclosure.Severity severity,
        uint256 requestedReward,
        bytes32 commitHash
    ) external returns (address disclosure) {
        // Validate inputs
        _validateInputs(participant, requestedReward, commitHash);
        
        uint256 requiredFee = calculateDeploymentFee(requestedReward);
        
        // Handle fee payment
        if (!hasDeploymentFeeWaiver[msg.sender]) {
            if (trustlessRep.balanceOf(msg.sender) < requiredFee) {
                revert InsufficientFee();
            }
            
            bool success = trustlessRep.transferFrom(
                msg.sender, 
                treasury,
                requiredFee
            );
            if (!success) {
                revert FeeTransferFailed();
            }
        }
        
        // Deploy contract
        disclosure = address(new TrustlessDisclosure(
            participant,
            severity,
            requestedReward,
            commitHash
        ));
        
        // Update tracking
        isDisclosure[disclosure] = true;
        researcherTotalRequested[msg.sender] += requestedReward;
        
        emit DisclosureDeployed(
            disclosure,
            msg.sender,
            participant,
            severity,
            requestedReward,
            commitHash
        );
    }

    /**
     * @notice Callback function for tracking successful disclosures
     * @dev Called by TrustlessDisclosure when state changes to Accepted
     * @param researcher Address of the researcher
     * @param requestedReward Amount requested for the disclosure
     */
    function onDisclosureAccepted(address researcher, uint256 requestedReward) external {
        // Ensure caller is a valid disclosure contract
        require(isDisclosure[msg.sender], "Unauthorized");
        
        researcherSuccessfulDisclosures[researcher] += 1;
        
        emit DisclosureAccepted(
            msg.sender,
            researcher,
            requestedReward
        );
    }
    
    /**
     * @notice Returns analytics for a researcher
     * @param researcher Address of the researcher
     * @return totalRequested Total value of rewards requested
     * @return successfulDisclosures Number of accepted disclosures
     */
    function getResearcherStats(address researcher) 
        external 
        view 
        returns (
            uint256 totalRequested,
            uint256 successfulDisclosures
        ) 
    {
        return (
            researcherTotalRequested[researcher],
            researcherSuccessfulDisclosures[researcher]
        );
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