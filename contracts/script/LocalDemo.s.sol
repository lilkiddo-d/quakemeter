// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VolIndex} from "../src/VolIndex.sol";
import {QuakeTimelock} from "../src/Timelock.sol";
import {PriceSampler} from "../src/PriceSampler.sol";
import {IPriceOracle} from "../src/interfaces/IQuake.sol";

/// @notice LOCAL FORK ONLY (chain id 31337). Settable oracle so a fork — where real Chainlink feeds are frozen —
///         can simulate weeks of market moves to exercise the full UI (warm-up → trading → settlement).
contract DemoOracle is IPriceOracle {
    address public immutable owner;
    mapping(address => uint256) public price;

    constructor() {
        owner = msg.sender;
    }

    function set(address[] calldata assets, uint256[] calldata prices) external {
        require(msg.sender == owner, "owner");
        for (uint256 i; i < assets.length; ++i) {
            price[assets[i]] = prices[i];
        }
    }

    function tryGetPrice(address a) external view returns (bool, uint256, uint256) {
        uint256 p = price[a];
        return (p != 0, p, block.timestamp);
    }
}

/// Phase 1: forge script script/LocalDemo.s.sol:LocalDemo --sig "schedule()" --rpc-url http://127.0.0.1:8555 --broadcast --unlocked --sender 0xf39F...
/// (advance time 48h via RPC) Phase 2: --sig "execute(address)" <demoOracle>
contract LocalDemo is Script {
    function _addr(string memory key) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), string.concat(".", key));
    }

    function schedule() external returns (DemoOracle o) {
        require(block.chainid == 31337, "local fork only");
        VolIndex vi = VolIndex(_addr("VolIndex"));
        PriceSampler sampler = vi.sampler();
        address[] memory assets = sampler.assets();
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            (bool ok, uint256 p,) = vi.oracle().tryGetPrice(assets[i]);
            prices[i] = ok ? p : 100e18;
        }
        QuakeTimelock tl = QuakeTimelock(payable(_addr("Timelock")));
        vm.startBroadcast();
        o = new DemoOracle();
        o.set(assets, prices);
        tl.schedule(address(vi), 0, abi.encodeCall(VolIndex.setOracle, (IPriceOracle(address(o)))), 0, 0, 48 hours);
        vm.stopBroadcast();
        console2.log("DemoOracle", address(o));
    }

    function execute(address demoOracle) external {
        require(block.chainid == 31337, "local fork only");
        VolIndex vi = VolIndex(_addr("VolIndex"));
        QuakeTimelock tl = QuakeTimelock(payable(_addr("Timelock")));
        vm.startBroadcast();
        tl.execute(address(vi), 0, abi.encodeCall(VolIndex.setOracle, (IPriceOracle(demoOracle))), 0, 0);
        vm.stopBroadcast();
        console2.log("VolIndex oracle now", address(vi.oracle()));
    }
}
