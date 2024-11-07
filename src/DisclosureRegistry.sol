// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./DisclosureFactory.sol";

/**
 * @title DisclosureRegistry
 * @notice Registry for tracking official protocol addresses and their disclosures
 */
contract DisclosureRegistry is Ownable {
    DisclosureFactory public immutable factory;
    
    // Protocol address => is registered
    mapping(address => bool) public isRegisteredProtocol;
    
    // Protocol address => array of their disclosure contracts
    mapping(address => address[]) public protocolDisclosures;
    
    event ProtocolRegistered(address indexed protocol);
    event ProtocolUnregistered(address indexed protocol);
    event DisclosureLinked(address indexed protocol, address indexed disclosure);
    
    error NotDeployedDisclosure();
    error AlreadyRegistered();
    error NotRegistered();
    
    constructor(address _factory, address _owner) Ownable(_owner) {
        factory = DisclosureFactory(_factory);
    }
    
    /**
     * @notice Registers a protocol address
     * @param protocol Address to register
     */
     //@audit so we control this, when would we call it? 
    function registerProtocol(address protocol) external onlyOwner {
        if (isRegisteredProtocol[protocol]) {
            revert AlreadyRegistered();
        }
        isRegisteredProtocol[protocol] = true;
        emit ProtocolRegistered(protocol);
    }
    
    /**
     * @notice Unregisters a protocol address
     * @param protocol Address to unregister
     */
    function unregisterProtocol(address protocol) external onlyOwner {
        if (!isRegisteredProtocol[protocol]) {
            revert NotRegistered();
        }
        isRegisteredProtocol[protocol] = false;
        emit ProtocolUnregistered(protocol);
    }
    
    /**
     * @notice Links a disclosure contract to a registered protocol
     * @param protocol Protocol address
     * @param disclosure Disclosure contract address
     */
    function linkDisclosure(address protocol, address disclosure) external {
        // Check disclosure was deployed by our factory
        if (!factory.isDeployedDisclosure(disclosure)) {
            revert NotDeployedDisclosure();
        }
        
        // Only allow linking to registered protocols
        if (!isRegisteredProtocol[protocol]) {
            revert NotRegistered();
        }
        
        protocolDisclosures[protocol].push(disclosure);
        emit DisclosureLinked(protocol, disclosure);
    }
    
    /**
     * @notice Gets all disclosures for a protocol
     * @param protocol Protocol address to query
     * @return Array of disclosure addresses
     */
    function getProtocolDisclosures(address protocol) 
        external 
        view 
        returns (address[] memory) 
    {
        return protocolDisclosures[protocol];
    }
}