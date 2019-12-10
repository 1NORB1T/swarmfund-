pragma solidity ^0.5.10;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "../interfaces/IUniswap.sol";
import "../interfaces/IPriceUSD.sol";
import "../interfaces/IIssuerStakeOfferPool.sol";

/**
 * @title The Issuer Stake Offer Pool Contract
 *
 * This contract allows the anyone to register as provider/seller of SWM tokens.
 * While registering, the SWM tokens are transferred from the provider to the
 * contract. The unsold SWM can be withdrawn at any point in time by unregistering.
 */
contract IssuerStakeOfferPool is IIssuerStakeOfferPool, Ownable {

    using SafeMath for uint256;

    // Setup variables that don't change
    uint256 public minTokens;
    uint256 public maxMarkup;
    uint256 public maxProviderCount;
    address public swarmERC20;
    address public uniswapUSDC;
    address public swmPriceOracle;

    // State variables that can change
    address public head;

    // Constant
    uint256 internal markupPrecision = 1000; // support resolution of 1/1000 of a percent

    struct Provider {
        uint256 tokens;
        uint256 markup; // Formatting note: see markupPrecision
                        // If it is 1000 and you want 12.554% markup, pass 12554 to the variable
        address previous;
        address next;
    }

    mapping(address => Provider) public providerList;

    uint256 public providerCount;

    constructor(
        address _swarmERC20,
        address _ethPriceOracle,
        address _swmPriceOracle,
        uint256 _minTokens,
        uint256 _maxMarkup,
        uint256 _maxProviderCount)
    public {
        swmPriceOracle = _swmPriceOracle;
        swarmERC20 = _swarmERC20;
        uniswapUSDC = _ethPriceOracle;
        minTokens = _minTokens;
        maxMarkup = _maxMarkup;
        maxProviderCount = _maxProviderCount;
    }

    function register(uint256 swmAmount, uint256 markup) external returns (bool) {

        require(swmAmount >= minTokens, 'Registration failed: offer more tokens!');
        require(providerCount < maxProviderCount, 'Registration failed: all slots full!');
        require(markup <= maxMarkup, 'Registration failed: offer smaller markup!');

        // Transfer SWM to the ISOP contract. We need to do this to prevent fake postings
        require(IERC20(swarmERC20).transferFrom(msg.sender, address(this), swmAmount),
                'Registration failed: ERC20 transfer failed!');

        _addToList(msg.sender, markup);

        if(providerList[msg.sender].tokens == 0)
            providerCount.add(1);

        providerList[msg.sender].tokens = swmAmount;
        providerList[msg.sender].markup = markup;

        return true;
    }

    // Add an element to the sorted (ascending) linked list of elements
    function _addToList(address provider, uint256 markup) internal returns (bool) {

        // If we don't have any elements set it up as the first one
        if (head == address(0)) {
            head = provider;
            return true;
        }

        if (providerList[head].markup >= markup) {
            if (providerList[provider].next != address(0) || providerList[provider].previous != address(0)) {
                providerList[providerList[provider].previous].next = providerList[provider].next;
            }

            providerList[provider].next = head;
            providerList[providerList[provider].next].previous = provider;
            head = provider;
        } else {
            address current = head;
            while (providerList[current].next != address(0) && providerList[providerList[current].next].markup < markup) {
                current = providerList[current].next;
            }

            if (providerList[current].next != provider) {
                if (providerList[provider].next != address(0) || providerList[provider].previous != address(0)) {
                    providerList[providerList[provider].previous].next = providerList[provider].next;
                }

                providerList[provider].next = providerList[current].next;

                if (providerList[current].next != address(0)) {
                    providerList[providerList[provider].next].previous = provider;
                }

                providerList[current].next = provider;
                providerList[provider].previous = current;
            }
        }

        //        // If we have at least one element, loop through the list, add new element to correct place
        //        address i = head;
        //        while(i != address(0)) {
        //
        //            // If we are smaller or equal than the current element, insert us before it
        //            if (providerList[provider].markup <= providerList[head].markup) {
        //
        //                if (i == head) {
        //                    head = provider;
        //                    providerList[provider].next = i;
        //                    providerList[provider].previous = address(0);
        //                }
        //                else {
        //                    providerList[providerList[provider].previous].next = providerList[provider].next;
        //                    providerList[providerList[provider].next].previous = providerList[provider].previous;
        //                }
        //
        //                return true;
        //            }
        //
        //            providerList[provider].previous = i;
        //            i = providerList[i].next;
        //        }
        //
        //        // If the loop didn't place him, it means he's the last chap
        //        // His .previous has been set above, his .next is 0 (set by default),
        //        // here we just repoint the old last element to this one
        //        providerList[providerList[provider].previous].next = provider; //this line???

        return true;
    }

    function _removeFromList(address provider) internal returns (bool) {
        providerList[providerList[provider].previous].next = providerList[provider].next;
        providerList[providerList[provider].next].previous = providerList[provider].previous;
        delete (providerList[provider]);

        if (provider == head) {
            delete head;
        }

        return true;
    }

    function unRegister() external returns (bool) {
        _removeFromList(msg.sender);

        providerCount.sub(1);
        return true;
    }

    function unRegister(address provider) external onlyOwner returns (bool) {
        _removeFromList(provider);

        providerCount.sub(1);
        return true;
    }

    function updateMinTokens(uint256 _minTokens) external onlyOwner {
        minTokens = _minTokens;
    }

    function isStakeOfferer(address account) external view returns (bool) {
        return providerList[account].tokens > 0;
    }

    // getter for number of tokens
    function getTokens(address account) external view returns (uint256) {
        return providerList[account].tokens;
    }

    // Get how much ETH we need to spend to get numSWM from a specific account
    // Get the market price of SWM and apply the account's markup
    function getSWMPriceETH(address account, uint256 numSWM) public returns (uint256) {
        (uint256 swmPriceUSDnumerator, uint256 swmPriceUSDdenominator) = IPriceUSD(swmPriceOracle).getPrice();
        uint256 requiredUSD = numSWM.mul(swmPriceUSDnumerator).div(swmPriceUSDdenominator);
        uint256 requiredETH = IUniswap(uniswapUSDC).getEthToTokenOutputPrice(requiredUSD);
        return requiredETH.mul(providerList[account].markup).div(markupPrecision*100);
    }

    // Loop to find out how much ETH we have to spend
    function loopGetSWMPriceETH(
        uint256 swmAmount,
        uint256 callerMaxMarkup
    )
        public
        returns (uint256)
    {
        uint256 tokens;
        uint256 tokensValueETH;
        uint256 tokensCollected;
        address i = head;
        while (i != address(0)) {
            // If this one is too expensive, skip to the next
            if (providerList[i].markup > callerMaxMarkup) {
                i = providerList[i].next;
                continue;
            }

            // Take all his tokens, or only a part of them
            tokens = swmAmount.sub(tokensCollected) >= providerList[i].tokens ?
                     providerList[i].tokens : swmAmount.sub(tokensCollected);

            tokensCollected = tokensCollected.add(tokens);
            tokensValueETH = tokensValueETH.add(getSWMPriceETH(i, tokens));
            i = providerList[i].next;
        }

        require(
            tokensCollected == swmAmount, 
            'Not enough SWM on the ISOP contract match your criteria!'
        );
        return tokensValueETH;
    }

    // Loop through the linked list of providers, buy SWM tokens from them until we have enough
    // NOTE: this function needs to be called with a sufficient number of ETH forwarded to it
    //       to find out how many, loopGetSWMPriceETH() is called first
    function loopBuySWMTokens(
        uint256 swmAmount,
        uint256 callerMaxMarkup
    )
        public
        payable
        returns (bool)
    {
        uint256 tokens;
        uint256 tokensCollected;
        uint256 tokensValueETH;
        address i = head;
        while (i != address(0)) {

            // If this one is too expensive, skip to the next
            if (providerList[i].markup > callerMaxMarkup) {
                i = providerList[i].next;
                continue;
            }

            // Take all his tokens, or only a part of them
            tokens = swmAmount.sub(tokensCollected) >= providerList[i].tokens ?
                     providerList[i].tokens : swmAmount.sub(tokensCollected);

            tokensValueETH = getSWMPriceETH(i, tokens);

            require(IERC20(swarmERC20).transfer(msg.sender, tokens), 'SWM transfer failed!');
            address(uint160(i)).transfer(tokensValueETH); // will blow up if insufficient funds

            tokensCollected = tokensCollected.add(tokens);
            // we need a temp variable because in the next step we delete 
            // the struct providerList[i]
            address next = providerList[i].next;

            providerList[i].tokens = providerList[i].tokens.sub(tokens);
            if (providerList[i].tokens == 0) {
                _removeFromList(i);
                providerCount.sub(1);
            }

            i = next;
        }

        return true;
    }

    // Get tokens from one specific account
    // NOTE: this is not used
    function buySWMTokens(
        address account,
        uint256 numSWM
    )
        public
        payable
        returns (bool)
    {

        require(numSWM <= providerList[account].tokens, 'Purchase failed: offerer lacks tokens!');
        require(IERC20(swarmERC20).allowance(account, msg.sender) >= numSWM, 'Purchase failed: allowance not set!');

        // Calculate whether the price is good
        (uint256 swmPriceUSDnumerator, uint256 swmPriceUSDdenominator) = IPriceUSD(swmPriceOracle).getPrice();
        uint256 requiredUSD = numSWM.mul(swmPriceUSDnumerator.div(swmPriceUSDdenominator));

        // Not the same as on a deep market
        uint256 receivedUSD = IUniswap(uniswapUSDC).getTokenToEthOutputPrice(msg.value);

        uint256 markup = receivedUSD.div(requiredUSD).mul(markupPrecision*100);
        require(markup >= providerList[account].markup, 'Purchase failed: offered price too low!');

        require(IERC20(swarmERC20).transfer(msg.sender, numSWM), "Purchase failed: SWM token transfer failed!");

        return true;
    }

}
