// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ITrustlessDisclosure.sol";

/**
 * @title ArbiterSystem
 * @notice Initial implementation with single arbiter, designed for future expansion
 * @dev Currently owner-only arbitration, prepared for future multi-arbiter system
 */
contract ArbiterSystem is ReentrancyGuard, Ownable {
    IERC20 public immutable trustlessRep;
    address public immutable treasury;
    
    enum CaseState { None, Pending, Accepted, Declined }
    
    struct Case {
        CaseState state;
        uint256 filingTime;
        address filer;
        bool feePaid;
    }
    
    struct QueueInfo {
        uint256 pendingCases;
        uint256 baseFee;
        mapping(uint256 => address) caseQueue; // position => disclosure
        mapping(address => bool) hasFeeWaiver;
    }
    
    QueueInfo public queue;
    uint256 public constant BASE_CASE_FEE = 100 ether; // Base fee in TDREP

    // Disclosure => Case details
    mapping(address => Case) public cases;
    
    uint256 public constant CASE_FILING_FEE = 100 ether; // 100 TDREP
    uint256 public constant ELIGIBILITY_FEE_PERCENT = 1; // 1% of requestedReward
    uint256 public constant COOLING_PERIOD = 3 days;
    
    event EligibilityAchieved(address disclosure);
    event CaseFiled(address disclosure, address filer);
    event CaseAccepted(address disclosure);
    event CaseDeclined(address disclosure);
    
    // Events for future multi-arbiter system
    event ArbiterSystemUpgraded(address newSystem);
    event MultiArbiterEnabled();
    
    error NotEligible();
    error CaseAlreadyExists();
    error InvalidCaseState();
    error CoolingPeriodActive();
    error NotAuthorized();
    error TransferFailed();

    constructor(address _trustlessRep, address _treasury) Ownable(msg.sender) {
        trustlessRep = IERC20(_trustlessRep);
        treasury = _treasury;
    }

    /**
     * @notice Makes a disclosure eligible for arbitration
     * @param disclosure Address of the disclosure contract
     */
    function makeEligible(address disclosure) external nonReentrant {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.None) revert CaseAlreadyExists();
        
        ITrustlessDisclosure disc = ITrustlessDisclosure(disclosure);
        require(disc.state() == ITrustlessDisclosure.State.Signed, "Not signed");
        
        uint256 fee = (disc.requestedReward() * ELIGIBILITY_FEE_PERCENT) / 100;
        bool success = trustlessRep.transferFrom(msg.sender, treasury, fee);
        if (!success) revert TransferFailed();
        
        caseData.feePaid = true;
        emit EligibilityAchieved(disclosure);
    }

    /**
     * @notice Files a case for arbitration
     * @param disclosure Address of the disclosure contract
     */
    function fileCase(address disclosure) external nonReentrant {
        Case storage caseData = cases[disclosure];
        if (!caseData.feePaid) revert NotEligible();
        if (caseData.state != CaseState.None) revert InvalidCaseState();
        if (block.timestamp < caseData.filingTime + COOLING_PERIOD) {
            revert CoolingPeriodActive();
        }
        
        bool success = trustlessRep.transferFrom(
            msg.sender,
            address(this),
            CASE_FILING_FEE
        );
        if (!success) revert TransferFailed();
        
        caseData.state = CaseState.Pending;
        caseData.filingTime = block.timestamp;
        caseData.filer = msg.sender;
        
        emit CaseFiled(disclosure, msg.sender);
    }
    
    /**
     * @notice Allows owner (single arbiter) to make decision on case
     * @param disclosure Address of the disclosure contract
     * @param accepted Whether the case is accepted or declined
     */
    function arbiterDecision(address disclosure, bool accepted) 
        external 
        onlyOwner 
    {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.Pending) revert InvalidCaseState();
        
        if (accepted) {
            bool success = trustlessRep.transfer(treasury, CASE_FILING_FEE);
            if (!success) revert TransferFailed();
            caseData.state = CaseState.Accepted;
            emit CaseAccepted(disclosure);
        } else {
            bool success = trustlessRep.transfer(caseData.filer, CASE_FILING_FEE);
            if (!success) revert TransferFailed();
            caseData.state = CaseState.Declined;
            emit CaseDeclined(disclosure);
        }
    }

    /**
     * @notice Reserved function for future upgrade to multi-arbiter system
     * @dev Will be implemented in future upgrade
     */
    function upgradeToMultiArbiter() external onlyOwner {
        // To be implemented in future upgrade
        emit MultiArbiterEnabled();
    }

    /**
     * @notice Allows future upgrade path to new arbiter system
     * @param newSystem Address of new arbiter system
     * @dev Will be implemented in future upgrade
     */
    function upgradeArbiterSystem(address newSystem) external onlyOwner {
        // To be implemented in future upgrade
        emit ArbiterSystemUpgraded(newSystem);
    }
}