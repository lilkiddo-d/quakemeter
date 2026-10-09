// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {DeployCore} from "./DeployCore.sol";

/// @notice Reads ../config/chains.json (the same file the frontend and keeper import via config/chains.ts).
abstract contract ConfigReader is CommonBase, DeployCore {
    function _readConfig(uint256 chainId) internal view returns (Config memory c, string[] memory symbols) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/chains.json"));
        string memory k = string.concat(".", vm.toString(chainId));
        c.stablecoin = vm.parseJsonAddress(json, string.concat(k, ".stablecoin.address"));
        c.feedMaxStaleness = uint32(vm.parseJsonUint(json, string.concat(k, ".feedMaxStaleness")));
        c.sequencerUptimeFeed = vm.parseJsonAddress(json, string.concat(k, ".sequencerUptimeFeed"));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(k, ".basket[", vm.toString(n), "]"))) {
            ++n;
        }
        require(n > 0, "empty basket");
        c.assets = new address[](n);
        c.feeds = new address[](n);
        symbols = new string[](n);
        for (uint256 i; i < n; ++i) {
            string memory b = string.concat(k, ".basket[", vm.toString(i), "]");
            c.assets[i] = vm.parseJsonAddress(json, string.concat(b, ".token"));
            c.feeds[i] = vm.parseJsonAddress(json, string.concat(b, ".feed"));
            symbols[i] = vm.parseJsonString(json, string.concat(b, ".symbol"));
        }
        c.minQuorum = n - n / 4; // 7 assets -> quorum 6
    }
}
