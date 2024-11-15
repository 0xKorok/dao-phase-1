// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDisclosureFactory {
    function onDisclosureAccepted(address researcher, uint256 finalReward) external;
}

/**
 * @title TrustlessDisclosure
 * @notice Manages vulnerability disclosure negotiations between researchers and protocols
 * @dev Implements a two-phase acceptance process: initial terms for disclosure access,
 *      followed by negotiation and final terms acceptance
 */
contract TrustlessDisclosure {
    /// @notice Represents the severity level of the vulnerability
    enum Severity { Medium, High, Critical }
    
    /// @notice Represents the current state of the disclosure process
    /// @dev Created: Initial state
    ///      InitiallyAccepted: Protocol has accepted initial terms and received disclosure
    ///      FinallyAccepted: Final negotiated terms have been accepted
    enum State { Created, InitiallyAccepted, FinallyAccepted }
    
    // Immutable state
    /// @notice Address of the researcher who deployed the contract
    address public immutable owner;           
    /// @notice Address of the protocol participating in the disclosure
    address public immutable participant;     
    /// @notice Hash of the vulnerability details (stored off-chain)
    bytes32 public immutable commitHash;      
    /// @notice Address of the factory that deployed this contract
    address public immutable factory;
    
    // Mutable state
    /// @notice Current state of the disclosure process
    State public state;
    /// @notice Initial severity assessment
    Severity public initialSeverity;
    /// @notice Final agreed severity (set during negotiation)
    Severity public finalSeverity;
    /// @notice Initial reward requested
    uint256 public initialReward;
    /// @notice Final agreed reward amount
    uint256 public finalReward;
    
    // Events
    event InitialTermsAccepted(address indexed participant, uint256 reward, Severity severity);
    event TermsUpdated(Severity severity, uint256 requestedReward);
    event FinalTermsAccepted(
        address indexed participant,
        uint256 finalReward,
        Severity finalSeverity,
        bytes32 commitHash
    );
    event PaymentReceived(uint256 amount);
    event PaymentClaimed(uint256 amount);
    event TokensRecovered(address indexed token, uint256 amount);
    
    // Errors
    error Unauthorized(address caller);
    error InvalidState();
    error OnlyDuringNegotiation();
    error NegotiationNotComplete();
    error TransferFailed();
    error NoPaymentToWithdraw();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyParticipant() {
        if (msg.sender != participant) revert Unauthorized(msg.sender);
        _;
    }

    /**
     * @notice Creates a new disclosure agreement
     * @param _participant Address of the protocol participating in the disclosure
     * @param _severity Initial severity rating of the vulnerability
     * @param _requestedReward Initial reward amount requested
     * @param _commitHash Hash of the vulnerability details
     * @dev Sets initial terms and stores factory address for callback
     */
    constructor(
        address _participant,
        Severity _severity,
        uint256 _requestedReward,
        bytes32 _commitHash
    ) {
        require(_participant != address(0), "Invalid participant");
        require(_commitHash != bytes32(0), "Invalid commit hash");
        
        owner = msg.sender;
        factory = msg.sender;  // During construction, msg.sender is the factory
        participant = _participant;
        initialSeverity = _severity;
        finalSeverity = _severity;  // Initialize final terms with initial values
        initialReward = _requestedReward;
        finalReward = _requestedReward;  // Initialize final terms with initial values
        commitHash = _commitHash;
        state = State.Created;
    }

    /**
     * @notice Allows participant to accept initial terms to receive disclosure details
     * @dev Moves contract to InitiallyAccepted state, enabling negotiation
     */
    function acceptInitialTerms() external onlyParticipant {
        if (state != State.Created) revert InvalidState();
        
        state = State.InitiallyAccepted;
        emit InitialTermsAccepted(msg.sender, initialReward, initialSeverity);
    }

    /**
     * @notice Updates terms during negotiation phase
     * @param _severity New severity assessment
     * @param _requestedReward New reward amount
     * @dev Only callable by owner during negotiation phase
     */
    function updateTerms(Severity _severity, uint256 _requestedReward) 
        external 
        onlyOwner 
    {
        if (state != State.InitiallyAccepted) revert OnlyDuringNegotiation();
        
        finalSeverity = _severity;
        finalReward = _requestedReward;
        
        emit TermsUpdated(_severity, _requestedReward);
    }

    /**
     * @notice Allows participant to accept final negotiated terms
     * @dev Moves contract to FinallyAccepted state and notifies factory
     */
    function acceptFinalTerms() external onlyParticipant {
        if (state != State.InitiallyAccepted) revert InvalidState();
        
        state = State.FinallyAccepted;
        
        // Notify factory of successful disclosure
        IDisclosureFactory(factory).onDisclosureAccepted(owner, finalReward);
        
        emit FinalTermsAccepted(msg.sender, finalReward, finalSeverity, commitHash);
    }

    /**
     * @notice Allows owner to withdraw accumulated ETH payments after final acceptance
     * @dev Transfers entire contract balance to owner
     */
    function claimPayment() external onlyOwner {
        if (state != State.FinallyAccepted) revert InvalidState();
        
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoPaymentToWithdraw();
        
        (bool success, ) = owner.call{value: balance}("");
        if (!success) revert TransferFailed();
        
        emit PaymentClaimed(balance);
    }

    /**
     * @notice Recovers ERC20 tokens accidentally sent to contract
     * @param token Address of the ERC20 token to recover
     * @dev Transfers entire token balance to owner
     */
    function recoverTokens(address token) external onlyOwner {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        require(balance > 0, "No tokens to recover");
        
        bool success = tokenContract.transfer(owner, balance);
        if (!success) revert TransferFailed();
        
        emit TokensRecovered(token, balance);
    }

    /**
     * @notice Handles incoming ETH payments
     * @dev Emits event for payment tracking
     */
    receive() external payable {
        emit PaymentReceived(msg.value);
    }
}