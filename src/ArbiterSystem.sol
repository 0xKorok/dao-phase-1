// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ITrustlessDisclosure.sol";

/**
 * @title ArbiterSystem
 * @notice Manages dispute resolution for TrustlessDisclosure contracts
 * @dev Implements two-phase process: eligibility then case submission
 */
contract ArbiterSystem is ReentrancyGuard, Ownable {
    /// @notice State tracking for arbitration cases
    enum CaseState { 
        None,           // Initial state
        Eligible,       // Made eligible by paying fee
        PendingReview,  // Case submitted, awaiting initial review
        AwaitingTrial,  // Accepted for trial, awaiting verdict
        Declined,       // Not accepted for trial
        Accepted,       // Final positive verdict
        Rejected        // Final negative verdict
    }
    
    /// @notice Core case information and tracking
    struct Case {
        CaseState state;
        uint256 filingTime;
        address filer;
        uint256 queuePosition;
        bool eligibilityFeePaid;
        bool submissionFeePaid;
    }

    /// @notice Global queue statistics and configuration
    struct QueueInfo {
        uint256 pendingReviewCount;
        uint256 awaitingTrialCount;
        uint256 baseSubmissionFee;
        uint256 nextPosition;
    }

    /// @notice Constants for fee calculations
    uint256 public constant ELIGIBILITY_FEE_PERCENT = 1; // 1% of requested reward
    
    /// @notice Core contract addresses
    IERC20 public immutable trustlessRep;
    address public immutable treasury;

    /// @notice Primary state mappings
    mapping(address => Case) public cases;
    mapping(uint256 => address) public reviewQueue;
    mapping(uint256 => address) public trialQueue;
    
    /// @notice Fee waiver tracking
    mapping(address => bool) public hasEligibilityFeeWaiver;
    mapping(address => bool) public hasSubmissionFeeWaiver;
    
    /// @notice Queue management
    QueueInfo public queueInfo;

    /// @notice Events for tracking system state
    event EligibilityAchieved(address indexed disclosure, uint256 fee);
    event CaseSubmitted(address indexed disclosure, address indexed filer);
    event CaseAcceptedForTrial(address indexed disclosure);
    event CaseDeclined(address indexed disclosure);
    event CaseVerdict(address indexed disclosure, bool accepted);
    event FeeWaiverGranted(address indexed disclosure, bool isEligibilityWaiver);
    event QueueReorganized(uint256 indexed position);

    /// @notice Custom errors for gas optimization
    error NotSignedDisclosure();
    error InvalidCaseState();
    error InsufficientFee();
    error TransferFailed();
    error NotInQueue();
    error InvalidQueueOperation();
    error AlreadyEligible();
    error NotYetEligible();

    constructor(address _trustlessRep, address _treasury) Ownable(msg.sender) {
        trustlessRep = IERC20(_trustlessRep);
        treasury = _treasury;
        queueInfo.baseSubmissionFee = 100 ether; // 100 TDREP base fee
    }

    /**
     * @notice Makes a disclosure eligible for arbitration by paying fee
     * @param disclosure Address of the disclosure contract
     */
    function makeEligible(address disclosure) external nonReentrant {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.None) revert AlreadyEligible();
        
        ITrustlessDisclosure disc = ITrustlessDisclosure(disclosure);
        if (disc.state() != ITrustlessDisclosure.State.Signed) {
            revert NotSignedDisclosure();
        }
        
        // Calculate and collect eligibility fee if not waived
        if (!hasEligibilityFeeWaiver[disclosure]) {
            uint256 fee = (disc.requestedReward() * ELIGIBILITY_FEE_PERCENT) / 100;
            bool success = trustlessRep.transferFrom(msg.sender, treasury, fee);
            if (!success) revert TransferFailed();
            caseData.eligibilityFeePaid = true;
            emit EligibilityAchieved(disclosure, fee);
        }
        
        caseData.state = CaseState.Eligible;
    }

    /**
     * @notice Calculates current submission fee based on queue size
     * @return fee Current required submission fee
     */
    function calculateCurrentFee() public view returns (uint256 fee) {
        if (queueInfo.pendingReviewCount == 0) return queueInfo.baseSubmissionFee;
        return queueInfo.baseSubmissionFee * (2 ** queueInfo.pendingReviewCount);
    }

    /**
     * @notice Grants fee waiver for either eligibility or submission
     * @param disclosure Address of the disclosure contract
     * @param isEligibilityWaiver True for eligibility fee waiver, false for submission fee
     */
    function grantFeeWaiver(address disclosure, bool isEligibilityWaiver) external onlyOwner {
        if (isEligibilityWaiver) {
            hasEligibilityFeeWaiver[disclosure] = true;
        } else {
            hasSubmissionFeeWaiver[disclosure] = true;
        }
        emit FeeWaiverGranted(disclosure, isEligibilityWaiver);
    }

    /**
     * @notice Submits an eligible case for arbitration
     * @param disclosure Address of the disclosure contract
     */
    function submitCase(address disclosure) external nonReentrant {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.Eligible) revert NotYetEligible();
        
        // Handle submission fee unless waived
        if (!hasSubmissionFeeWaiver[disclosure]) {
            uint256 fee = calculateCurrentFee();
            bool success = trustlessRep.transferFrom(msg.sender, treasury, fee);
            if (!success) revert TransferFailed();
            caseData.submissionFeePaid = true;
        }

        // Add to review queue
        uint256 position = queueInfo.nextPosition++;
        reviewQueue[position] = disclosure;
        queueInfo.pendingReviewCount++;

        caseData.state = CaseState.PendingReview;
        caseData.filingTime = block.timestamp;
        caseData.filer = msg.sender;
        caseData.queuePosition = position;

        emit CaseSubmitted(disclosure, msg.sender);
    }

    /**
     * @notice Reviews a case and decides whether to accept for trial
     * @param disclosure Address of the disclosure contract
     * @param acceptForTrial Whether to accept the case for trial
     */
    function reviewCase(address disclosure, bool acceptForTrial) 
        external 
        onlyOwner 
    {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.PendingReview) revert InvalidCaseState();

        if (acceptForTrial) {
            caseData.state = CaseState.AwaitingTrial;
            trialQueue[queueInfo.awaitingTrialCount++] = disclosure;
            emit CaseAcceptedForTrial(disclosure);
        } else {
            caseData.state = CaseState.Declined;
            emit CaseDeclined(disclosure);
        }

        // Remove from review queue
        _reorganizeQueue(caseData.queuePosition);
        queueInfo.pendingReviewCount--;
    }

    /**
     * @notice Makes final verdict on a case
     * @param disclosure Address of the disclosure contract
     * @param accepted Whether the case is accepted or rejected
     */
    function makeVerdict(address disclosure, bool accepted)
        external
        onlyOwner
    {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.AwaitingTrial) revert InvalidCaseState();

        caseData.state = accepted ? CaseState.Accepted : CaseState.Rejected;
        queueInfo.awaitingTrialCount--;

        emit CaseVerdict(disclosure, accepted);
    }

    /**
     * @notice Internal function to reorganize queue after removal
     * @param position Position to remove from queue
     */
    function _reorganizeQueue(uint256 position) internal {
        for (uint256 i = position; i < queueInfo.nextPosition - 1; i++) {
            reviewQueue[i] = reviewQueue[i + 1];
            if (reviewQueue[i] != address(0)) {
                cases[reviewQueue[i]].queuePosition = i;
            }
        }
        delete reviewQueue[queueInfo.nextPosition - 1];
        queueInfo.nextPosition--;
        
        emit QueueReorganized(position);
    }

    /**
     * @notice Returns full case details including queue position
     * @param disclosure Address of the disclosure contract
     * @return state Current case state
     * @return filingTime Time case was filed
     * @return filer Address that filed the case
     * @return queuePosition Current position in queue (if applicable)
     * @return eligibilityFeePaid Whether eligibility fee was paid
     * @return submissionFeePaid Whether submission fee was paid
     */
    function getCaseDetails(address disclosure) 
        external 
        view 
        returns (
            CaseState state,
            uint256 filingTime,
            address filer,
            uint256 queuePosition,
            bool eligibilityFeePaid,
            bool submissionFeePaid
        ) 
    {
        Case storage caseData = cases[disclosure];
        return (
            caseData.state,
            caseData.filingTime,
            caseData.filer,
            caseData.queuePosition,
            caseData.eligibilityFeePaid,
            caseData.submissionFeePaid
        );
    }
}