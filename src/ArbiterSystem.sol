// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ITrustlessDisclosure.sol";

/**
 * @title ArbiterSystem
 * @notice Manages arbitration for TrustlessDisclosure disputes with upgradeable multi-arbiter support
 * @dev Initially single-arbiter, can be upgraded to multi-arbiter system
 */
contract ArbiterSystem is ReentrancyGuard, Ownable {
    /// @notice Tracks the state of arbitration cases
    enum CaseState { 
        None,           // Initial state
        Eligible,       // Made eligible by paying fee
        PendingReview,  // Awaiting initial review
        AwaitingTrial,  // Accepted for trial
        Declined,       // Not accepted for trial
        Accepted,       // Final positive verdict
        Rejected        // Final negative verdict
    }
    
    /// @notice Stores case information
    struct Case {
        CaseState state;
        uint256 filingTime;
        address filer;
        uint256 queuePosition;
        bool eligibilityFeePaid;
        bool submissionFeePaid;
    }

    /// @notice Tracks queue statistics
    struct QueueInfo {
        uint256 pendingReviewCount;
        uint256 awaitingTrialCount;
        uint256 baseSubmissionFee;
        uint256 nextPosition;
    }

    uint256 public constant ELIGIBILITY_FEE_PERCENT = 1; // 1% of requested reward
    
    IERC20 public immutable trustlessRep;
    address public immutable treasury;

    mapping(address => Case) public cases;
    mapping(uint256 => address) public reviewQueue;
    mapping(uint256 => address) public trialQueue;
    mapping(address => bool) public hasEligibilityFeeWaiver;
    mapping(address => bool) public hasSubmissionFeeWaiver;
    
    // Multi-arbiter system state
    bool public isMultiArbiterEnabled;
    mapping(address => bool) public isApprovedArbiter;
    
    QueueInfo public queueInfo;

    event EligibilityAchieved(address indexed disclosure, uint256 fee);
    event CaseSubmitted(address indexed disclosure, address indexed filer);
    event CaseAcceptedForTrial(address indexed disclosure);
    event CaseDeclined(address indexed disclosure);
    event CaseVerdict(address indexed disclosure, bool accepted);
    event FeeWaiverGranted(address indexed disclosure, bool isEligibilityWaiver);
    event QueueReorganized(uint256 indexed position);
    event ArbiterSystemUpgraded(address newSystem);
    event MultiArbiterEnabled();
    event NewArbiterAdded(address indexed arbiter);
    event ArbiterRemoved(address indexed arbiter);

    error NotSignedDisclosure();
    error InvalidCaseState();
    error InsufficientFee();
    error TransferFailed();
    error NotInQueue();
    error InvalidQueueOperation();
    error AlreadyEligible();
    error NotYetEligible();
    error NotAuthorizedArbiter();
    error MultiArbiterNotEnabled();
    error InvalidArbiterAddress();
    error CannotRemoveOwner();

    modifier onlyArbiter() {
        if (!(msg.sender == owner() || (isMultiArbiterEnabled && isApprovedArbiter[msg.sender]))) {
            revert NotAuthorizedArbiter();
        }
        _;
    }

    constructor(address _trustlessRep, address _treasury) Ownable(msg.sender) {
        trustlessRep = IERC20(_trustlessRep);
        treasury = _treasury;
        queueInfo.baseSubmissionFee = 100 ether; // 100 TDREP
    }

    /** @notice Makes disclosure eligible for arbitration with fee
     * @param disclosure Address of the disclosure
     */
    function makeEligible(address disclosure) external nonReentrant {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.None) revert AlreadyEligible();
        
        ITrustlessDisclosure disc = ITrustlessDisclosure(disclosure);
        if (disc.state() != ITrustlessDisclosure.State.Signed) {
            revert NotSignedDisclosure();
        }
        
        if (!hasEligibilityFeeWaiver[disclosure]) {
            uint256 fee = (disc.requestedReward() * ELIGIBILITY_FEE_PERCENT) / 100;
            bool success = trustlessRep.transferFrom(msg.sender, treasury, fee);
            if (!success) revert TransferFailed();
            caseData.eligibilityFeePaid = true;
            emit EligibilityAchieved(disclosure, fee);
        }
        
        caseData.state = CaseState.Eligible;
    }

    /** @notice Calculates submission fee based on queue size
     * @return Current required submission fee
     */
    function calculateCurrentFee() public view returns (uint256) {
        if (queueInfo.pendingReviewCount == 0) return queueInfo.baseSubmissionFee;
        return queueInfo.baseSubmissionFee * (2 ** queueInfo.pendingReviewCount);
    }

    /** @notice Waives fees for eligible cases
     * @param disclosure Address of disclosure
     * @param isEligibilityWaiver True for eligibility fee, false for submission
     */
    function grantFeeWaiver(address disclosure, bool isEligibilityWaiver) external onlyOwner {
        if (isEligibilityWaiver) {
            hasEligibilityFeeWaiver[disclosure] = true;
        } else {
            hasSubmissionFeeWaiver[disclosure] = true;
        }
        emit FeeWaiverGranted(disclosure, isEligibilityWaiver);
    }

    /** @notice Submits case for arbitration
     * @param disclosure Address of disclosure
     */
    function submitCase(address disclosure) external nonReentrant {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.Eligible) revert NotYetEligible();
        
        if (!hasSubmissionFeeWaiver[disclosure]) {
            uint256 fee = calculateCurrentFee();
            bool success = trustlessRep.transferFrom(msg.sender, treasury, fee);
            if (!success) revert TransferFailed();
            caseData.submissionFeePaid = true;
        }

        uint256 position = queueInfo.nextPosition++;
        reviewQueue[position] = disclosure;
        queueInfo.pendingReviewCount++;

        caseData.state = CaseState.PendingReview;
        caseData.filingTime = block.timestamp;
        caseData.filer = msg.sender;
        caseData.queuePosition = position;

        emit CaseSubmitted(disclosure, msg.sender);
    }

    /** @notice Reviews case for trial acceptance
     * @param disclosure Address of disclosure
     * @param acceptForTrial Whether to accept for trial
     */
    function reviewCase(address disclosure, bool acceptForTrial) 
        external 
        onlyArbiter 
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

        _reorganizeQueue(caseData.queuePosition);
        queueInfo.pendingReviewCount--;
    }

    /** @notice Makes final verdict on case
     * @param disclosure Address of disclosure
     * @param accepted Whether case is accepted
     */
    function makeVerdict(address disclosure, bool accepted)
        external
        onlyArbiter
    {
        Case storage caseData = cases[disclosure];
        if (caseData.state != CaseState.AwaitingTrial) revert InvalidCaseState();

        caseData.state = accepted ? CaseState.Accepted : CaseState.Rejected;
        queueInfo.awaitingTrialCount--;

        emit CaseVerdict(disclosure, accepted);
    }

    /** @notice Enables multi-arbiter functionality */
    function upgradeToMultiArbiter() external onlyOwner {
        isMultiArbiterEnabled = true;
        isApprovedArbiter[owner()] = true;
        emit MultiArbiterEnabled();
    }

    /** @notice Upgrades to new arbiter system
     * @param newSystem Address of new system
     */
    function upgradeArbiterSystem(address newSystem) external onlyOwner {
        if (newSystem == address(0)) revert InvalidArbiterAddress();
        emit ArbiterSystemUpgraded(newSystem);
    }

    /** @notice Adds new arbiter after upgrade
     * @param arbiter Address of new arbiter
     */
    function addArbiter(address arbiter) external onlyOwner {
        if (!isMultiArbiterEnabled) revert MultiArbiterNotEnabled();
        if (arbiter == address(0)) revert InvalidArbiterAddress();
        isApprovedArbiter[arbiter] = true;
        emit NewArbiterAdded(arbiter);
    }

    /** @notice Removes arbiter from system
     * @param arbiter Address to remove
     */
    function removeArbiter(address arbiter) external onlyOwner {
        if (!isMultiArbiterEnabled) revert MultiArbiterNotEnabled();
        if (arbiter == owner()) revert CannotRemoveOwner();
        isApprovedArbiter[arbiter] = false;
        emit ArbiterRemoved(arbiter);
    }

    /** @notice Reorganizes queue after case removal
     * @param position Position to remove
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

    /** @notice Gets complete case details
     * @param disclosure Address of disclosure
     * @return Full case information
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