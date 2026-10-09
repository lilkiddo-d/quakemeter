// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VolIndex} from "../src/VolIndex.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {QuakeTimelock} from "../src/Timelock.sol";
import {FuturesMarket} from "../src/FuturesMarket.sol";
import {MarginAccount} from "../src/MarginAccount.sol";
import {LPVault} from "../src/LPVault.sol";
import {ConfigReader} from "./ConfigReader.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Liquidator} from "../src/Liquidator.sol";

/// @notice Reads ../deployments/<chainId>.json.
abstract contract DeploymentReader is Script {
    function _addr(string memory key) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), ".json");
        return vm.parseJsonAddress(vm.readFile(path), string.concat(".", key));
    }
}

/// @title Sample — one keeper tick. Used by scripts/keeper (signs with --account quakemeter-keeper).
///   forge script script/Ops.s.sol:Sample --rpc-url robinhood --account quakemeter-keeper --sender <KEEPER_ADDRESS> --broadcast
contract Sample is DeploymentReader {
    function run() external {
        VolIndex vi = VolIndex(_addr("VolIndex"));
        if (!vi.canSample()) {
            console2.log("nothing to do: market closed or slot already sampled");
            return;
        }
        vm.startBroadcast();
        uint256 id = vi.sample();
        vm.stopBroadcast();
        (uint256 q,) = vi.latestIndex();
        console2.log("sampled round", id, "QVIX (1e18)", q);
    }
}

/// @title SetProjectToken — wires the externally launched $QUAK through the 48h Timelock (two steps).
///   1) forge script script/Ops.s.sol:SetProjectToken --sig "schedule(address)" <TOKEN> --rpc-url robinhood --account quakemeter-deployer --broadcast
///   2) after 48h: same with --sig "execute(address)"
contract SetProjectToken is DeploymentReader {
    function _call(address token) internal view returns (address target, bytes memory data, bytes32 salt) {
        target = _addr("ProjectTokenHooks");
        data = abi.encodeCall(ProjectTokenHooks.setProjectToken, (token));
        salt = keccak256(abi.encode("QUAK", token));
    }

    function schedule(address token) external {
        QuakeTimelock tl = QuakeTimelock(payable(_addr("Timelock")));
        (address target, bytes memory data, bytes32 salt) = _call(token);
        vm.startBroadcast();
        tl.schedule(target, 0, data, bytes32(0), salt, tl.getMinDelay());
        vm.stopBroadcast();
        console2.log("scheduled; executable at", block.timestamp + tl.getMinDelay());
    }

    function execute(address token) external {
        QuakeTimelock tl = QuakeTimelock(payable(_addr("Timelock")));
        (address target, bytes memory data, bytes32 salt) = _call(token);
        vm.startBroadcast();
        tl.execute(target, 0, data, bytes32(0), salt);
        vm.stopBroadcast();
        console2.log("project token set:", token, ProjectTokenHooks(target).isActive());
    }
}

/// @title NewExpiry — deploys the next monthly FuturesMarket and schedules its registration via the Timelock.
///   forge script script/Ops.s.sol:NewExpiry --sig "deploy(uint256,uint256)" <year> <month> --rpc-url robinhood --account quakemeter-deployer --broadcast
///   then after 48h: --sig "register(address)" <market>
contract NewExpiry is DeploymentReader, ConfigReader {
    function deploy(uint256 year, uint256 month) external returns (FuturesMarket m) {
        Deployment memory d;
        d.clock = MarketClock(_addr("MarketClock"));
        d.volIndex = VolIndex(_addr("VolIndex"));
        d.marginAccount = MarginAccount(_addr("MarginAccount"));
        d.vault = LPVault(_addr("LPVault"));
        d.insurance = InsuranceFund(_addr("InsuranceFund"));
        d.feeCollector = FeeCollector(_addr("FeeCollector"));
        d.compliance = ComplianceRegistry(_addr("ComplianceRegistry"));
        d.liquidator = Liquidator(_addr("Liquidator"));
        address tl = _addr("Timelock");
        address guardian = vm.envOr("GUARDIAN_ADDRESS", msg.sender);
        uint256 expiry = d.clock.monthlyExpiry(year, month);
        vm.startBroadcast();
        m = _deployMarket(d, expiry, msg.sender);
        m.grantRole(m.GUARDIAN_ROLE(), guardian);
        m.grantRole(m.DEFAULT_ADMIN_ROLE(), tl);
        m.renounceRole(m.DEFAULT_ADMIN_ROLE(), msg.sender);
        QuakeTimelock(payable(tl)).schedule(
            address(d.marginAccount), 0, abi.encodeCall(MarginAccount.addMarket, (address(m))), bytes32(0), bytes32(0), 48 hours
        );
        vm.stopBroadcast();
        console2.log("market", address(m), "expiry", expiry);
    }

    function register(address market) external {
        address tl = _addr("Timelock");
        vm.startBroadcast();
        QuakeTimelock(payable(tl)).execute(
            _addr("MarginAccount"), 0, abi.encodeCall(MarginAccount.addMarket, (market)), bytes32(0), bytes32(0)
        );
        vm.stopBroadcast();
    }
}
