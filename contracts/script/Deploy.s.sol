// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ConfigReader} from "./ConfigReader.sol";

/// @title Deploy
/// @notice One-shot deploy + wiring of Quakemeter. Reads chain addresses from ../config/chains.json, hands every
///         admin role to the 48h Timelock and writes ../deployments/<chainId>.json plus the frontend config.
///         Signing happens only through the Foundry keystore passed on the CLI (--account quakemeter-deployer);
///         this script never touches a private key.
///
///   Optional env: GUARDIAN_ADDRESS, TIMELOCK_PROPOSER, TREASURY_ADDRESS (default: deployer / deployer / Timelock),
///                 CONFIG_CHAIN_ID (default: block.chainid, or 4663 when running on a local fork with chain id 31337),
///                 FIRST_EXPIRY_MIN_LEAD_DAYS (default 45: first expiry after the 30-day index warm-up).
contract Deploy is Script, ConfigReader {
    function run() external returns (Deployment memory d) {
        uint256 cfgChain = vm.envOr("CONFIG_CHAIN_ID", block.chainid == 31337 ? uint256(4663) : block.chainid);
        (Config memory c,) = _readConfig(cfgChain);
        address deployer = msg.sender;
        c.guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);
        c.proposer = vm.envOr("TIMELOCK_PROPOSER", deployer);
        c.treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        c.firstExpiryMinLead = vm.envOr("FIRST_EXPIRY_MIN_LEAD_DAYS", uint256(45)) * 1 days;

        console2.log("Deploying Quakemeter on chain", block.chainid, "config", cfgChain);
        console2.log("deployer", deployer);

        vm.startBroadcast(deployer);
        d = _deploy(deployer, c);
        vm.stopBroadcast();

        _write(d, deployer, cfgChain);
    }

    function _write(Deployment memory d, address deployer, uint256 cfgChain) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "configChainId", cfgChain);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeUint(o, "deployedAtBlock", block.number);
        vm.serializeUint(o, "deployedAt", block.timestamp);
        vm.serializeAddress(o, "Timelock", address(d.timelock));
        vm.serializeAddress(o, "MarketClock", address(d.clock));
        vm.serializeAddress(o, "OracleAdapter", address(d.oracle));
        vm.serializeAddress(o, "PriceSampler", address(d.sampler));
        vm.serializeAddress(o, "VolIndex", address(d.volIndex));
        vm.serializeAddress(o, "MarginAccount", address(d.marginAccount));
        vm.serializeAddress(o, "LPVault", address(d.vault));
        vm.serializeAddress(o, "InsuranceFund", address(d.insurance));
        vm.serializeAddress(o, "FeeCollector", address(d.feeCollector));
        vm.serializeAddress(o, "ProjectTokenHooks", address(d.tokenHooks));
        vm.serializeAddress(o, "ComplianceRegistry", address(d.compliance));
        vm.serializeAddress(o, "Liquidator", address(d.liquidator));
        vm.serializeAddress(o, "VarianceSwap", address(d.varianceSwap));
        vm.serializeAddress(o, "Collateral", address(d.marginAccount.collateralToken()));
        address[] memory mk = new address[](d.markets.length);
        address[] memory amms = new address[](d.markets.length);
        for (uint256 i; i < d.markets.length; ++i) {
            mk[i] = address(d.markets[i]);
            amms[i] = address(d.markets[i].vamm());
        }
        vm.serializeAddress(o, "FuturesMarkets", mk);
        vm.serializeAddress(o, "VAMMs", amms);
        string memory out = vm.serializeUint(o, "expiries", d.expiries);

        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        string memory root = vm.projectRoot();
        string memory id = vm.toString(block.chainid);
        if (broadcast) {
            vm.writeJson(out, string.concat(root, "/../deployments/", id, ".json"));
            vm.writeJson(out, string.concat(root, "/../app/src/config/generated/deployments.", id, ".json"));
            console2.log("Wrote deployments/%s.json and app/src/config/generated/deployments.%s.json", id, id);
        } else {
            vm.writeJson(out, string.concat(root, "/../deployments/", id, ".dry-run.json"));
            console2.log("Dry run: wrote deployments/%s.dry-run.json", id);
        }
    }
}
