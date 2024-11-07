// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./TimelockTreasury.sol";

contract TrustlessRep is ERC20, ERC20Burnable, Ownable {
    constructor(address initialOwner) 
        ERC20("TrustlessDAO Reputation", "TDREP") 
        Ownable(initialOwner)
    {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}

contract TrustlessDAO is Ownable, ReentrancyGuard {
    TimelockTreasury public immutable treasury;
    TrustlessRep public immutable trustlessRep;
    uint256 public tokenPrice;
    
    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event TokensPurchased(address indexed buyer, uint256 amount, uint256 cost);
    event TokensMinted(address indexed receiver, uint256 amount);
    
    error InsufficientPayment();
    error InvalidAmount();
    error WithdrawFailed();

    constructor(uint256 initialPrice, address _treasuryOwner) Ownable(msg.sender) {
        treasury = new TimelockTreasury(_treasuryOwner);
        trustlessRep = new TrustlessRep(address(this));

        tokenPrice = initialPrice;
    }

    /**
     * @dev Allows anyone to purchase TDREP tokens by sending ETH
     * @param amount The number of tokens to purchase
     */
    function purchaseTokens(uint256 amount) external payable nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        uint256 cost = amount * tokenPrice;
        if (msg.value < cost) revert InsufficientPayment();
        
        // Mint tokens to the buyer
        trustlessRep.mint(msg.sender, amount);
        
        // Refund excess payment if any
        uint256 excess = msg.value - cost;
        if (excess > 0) {
            (bool success, ) = msg.sender.call{value: excess}("");
            if (!success) revert WithdrawFailed();
        }
        
        emit TokensPurchased(msg.sender, amount, cost);
    }

    /**
     * @dev Allows owner to mint tokens for free to any address
     * @param to The address to receive the tokens
     * @param amount The number of tokens to mint
     */
    function mintTokens(address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidAmount();
        trustlessRep.mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @dev Updates the price per token
     * @param newPrice The new price in wei per token
     */
    function setTokenPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = tokenPrice;
        tokenPrice = newPrice;
        emit TokenPriceUpdated(oldPrice, newPrice);
    }

    /**
    * @dev Withdraws all ETH from the contract to the timelock treasury
    */
    function withdrawToTreasury() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = address(treasury).call{value: balance}("");
        if (!success) revert WithdrawFailed();
    }

    /**
     * @dev Required to receive ETH payments
     */
    receive() external payable {}
}