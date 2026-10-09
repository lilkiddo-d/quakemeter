// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPriceOracle, IMarketClock} from "../../src/interfaces/IQuake.sol";

/// @notice Test-only ERC-20 (used for the stablecoin and as the stand-in $QUAK project token). Never deployed.
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    bool public reverts;
    string public description = "mock";

    constructor(uint8 d, int256 a) {
        decimals = d;
        answer = a;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
        roundId++;
        answeredInRound = roundId;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function setRounds(uint80 r, uint80 a) external {
        roundId = r;
        answeredInRound = a;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "feed down");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice Oracle with directly settable prices (for reference-implementation comparisons).
contract MockOracle is IPriceOracle {
    mapping(address => uint256) public price;
    mapping(address => bool) public bad;

    function set(address a, uint256 p, bool isBad) external {
        price[a] = p;
        bad[a] = isBad;
    }

    function tryGetPrice(address a) external view returns (bool, uint256, uint256) {
        if (bad[a] || price[a] == 0) return (false, 0, 0);
        return (true, price[a], block.timestamp);
    }
}

/// @notice Clock that is always open, with a fresh slot every call to `next` and scripted period counts.
contract MockClock is IMarketClock {
    uint256 public slot;
    uint256 public periods = 1;

    function next(uint256 p) external {
        slot++;
        periods = p;
    }

    function isOpen(uint256) external pure returns (bool) {
        return true;
    }

    function slotId(uint256) external view returns (uint256) {
        return slot;
    }

    function periodsBetween(uint256, uint256) external view returns (uint256) {
        return periods;
    }
}
