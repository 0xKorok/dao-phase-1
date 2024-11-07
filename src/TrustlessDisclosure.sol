// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract TrustlessDisclosure {
    address public immutable owner;
    address public immutable participant;
    uint256 public goodFaithAmount;
    uint256 public immutable participantClaimDelay;
    uint256 public immutable ownerClaimDelay;
    uint256 public immutable deploymentTime;
    uint256 public immutable gasReserve; // Amount reserved for gas fees
    
    enum Vote {
        None,
        Refund,
        Split,
        PayFull
    }
    
    struct Balance {
        uint256 total;
        uint256 claimed;
    }
    
    mapping(address => Vote) public votes;
    mapping(address => Balance) public balances;
    bool public isResolved;
    uint256 public totalReceived;
    
    event AmountUpdated(uint256 oldValue, uint256 newValue);
    event VoteCast(address indexed voter, Vote vote);
    event ConsensusReached(Vote consensus);
    event FundsClaimed(address indexed claimer, uint256 amount);
    event FundsReceived(address indexed sender, uint256 amount, uint256 newTotal);
    event TimebasedClaim(address indexed claimer, uint256 amount);
    
    error NotAuthorized();
    error NotOwner();
    error AlreadyResolved();
    error NoClaimableAmount();
    error InsufficientContractBalance();
    error TooEarlyToClaim();
    error AlreadyClaimed();
    error InsufficientGasReserve();
    
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }
    
    modifier onlyAuthorizedVoter() {
        if (msg.sender != owner && msg.sender != participant) {
            revert NotAuthorized();
        }
        _;
    }
    
    modifier notResolved() {
        if (isResolved) {
            revert AlreadyResolved();
        }
        _;
    }
    
    constructor(
        address _participant,
        uint256 _initialPayment,
        uint256 _participantClaimDays,
        uint256 _ownerClaimDays,
        uint256 _gasReserve // Amount in wei to reserve for gas
    ) {
        require(_participant != address(0), "Invalid participant address");
        require(_participantClaimDays < _ownerClaimDays, "Invalid claim delays");
        require(_gasReserve > 0, "Gas reserve must be positive");
        
        owner = msg.sender;
        participant = _participant;
        goodFaithAmount = _initialPayment;
        participantClaimDelay = _participantClaimDays * 1 days;
        ownerClaimDelay = _ownerClaimDays * 1 days;
        deploymentTime = block.timestamp;
        gasReserve = _gasReserve;
    }
    
    function vote(Vote _vote) external onlyAuthorizedVoter notResolved {
        require(_vote != Vote.None, "Invalid vote option");
        votes[msg.sender] = _vote;
        emit VoteCast(msg.sender, _vote);
        
        // Check if consensus is reached
        if (votes[owner] == votes[participant] && votes[owner] != Vote.None) {
            _resolveConsensus(votes[owner]);
        }
    }
    
    function _resolveConsensus(Vote consensusVote) private {
        isResolved = true;
        emit ConsensusReached(consensusVote);
        
        // Calculate claimable amounts based on consensus
        uint256 availableBalance = address(this).balance - (2 * gasReserve); // Reserve gas for both claims
        
        if (consensusVote == Vote.Refund) {
            balances[participant].total = availableBalance;
        } else if (consensusVote == Vote.Split) {
            uint256 half = availableBalance / 2;
            // Give extra wei to participant if odd amount
            if (availableBalance % 2 == 1) {
                balances[participant].total = half + 1;
                balances[owner].total = half;
            } else {
                balances[participant].total = half;
                balances[owner].total = half;
            }
        } else if (consensusVote == Vote.PayFull) {
            balances[owner].total = availableBalance;
        }
    }
    
    function claim() external {
        if (!isResolved) {
            _handleTimebasedClaim();
            return;
        }
        
        Balance storage userBalance = balances[msg.sender];
        uint256 claimable = userBalance.total - userBalance.claimed;
        
        if (claimable == 0) {
            revert NoClaimableAmount();
        }
        
        // Ensure enough balance including gas reserve
        if (address(this).balance < claimable + gasReserve) {
            revert InsufficientContractBalance();
        }
        
        userBalance.claimed += claimable;
        emit FundsClaimed(msg.sender, claimable);
        
        (bool success, ) = payable(msg.sender).call{value: claimable}("");
        require(success, "Transfer failed");
    }
    
    function _handleTimebasedClaim() private {
        uint256 timePassed = block.timestamp - deploymentTime;
        uint256 availableBalance = address(this).balance - gasReserve; // Reserve gas for one claim
        
        if (msg.sender == participant) {
            if (timePassed < participantClaimDelay) {
                revert TooEarlyToClaim();
            }
            if (balances[participant].claimed > 0) {
                revert AlreadyClaimed();
            }
            balances[participant].total = availableBalance;
            balances[participant].claimed = availableBalance;
            emit TimebasedClaim(participant, availableBalance);
            (bool success, ) = payable(participant).call{value: availableBalance}("");
            require(success, "Transfer failed");
        } else if (msg.sender == owner) {
            if (timePassed < ownerClaimDelay) {
                revert TooEarlyToClaim();
            }
            if (balances[owner].claimed > 0) {
                revert AlreadyClaimed();
            }
            balances[owner].total = availableBalance;
            balances[owner].claimed = availableBalance;
            emit TimebasedClaim(owner, availableBalance);
            (bool success, ) = payable(owner).call{value: availableBalance}("");
            require(success, "Transfer failed");
        } else {
            revert NotAuthorized();
        }
    }
    
    receive() external payable {
        totalReceived += msg.value;
        // Credit received funds to participant's running total
        if (!isResolved) {
            balances[participant].total += msg.value;
        }
        emit FundsReceived(msg.sender, msg.value, totalReceived);
    }
    
    // View functions
    function getParticipantBalance() external view returns (uint256 total, uint256 claimed) {
        Balance memory bal = balances[participant];
        return (bal.total, bal.claimed);
    }
    
    function getAvailableBalance() external view returns (uint256) {
        return address(this).balance - gasReserve;
    }

    function getTimeUntilParticipantClaim() external view returns (uint256) {
        uint256 timePassed = block.timestamp - deploymentTime;
        if (timePassed >= participantClaimDelay) return 0;
        return participantClaimDelay - timePassed;
    }
    
    function getTimeUntilOwnerClaim() external view returns (uint256) {
        uint256 timePassed = block.timestamp - deploymentTime;
        if (timePassed >= ownerClaimDelay) return 0;
        return ownerClaimDelay - timePassed;
    }
}