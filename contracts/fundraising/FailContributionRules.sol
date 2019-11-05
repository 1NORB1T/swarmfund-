pragma solidity ^0.5.0;

import "../interfaces/IContributionRules.sol";

contract FailContributionRules is IContributionRules{
    function checkContribution() external returns (bool) {
        return false;
    }
}