// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceSampler} from "../../src/PriceSampler.sol";
import {VolIndex} from "../../src/VolIndex.sol";
import {IPriceOracle, IMarketClock} from "../../src/interfaces/IQuake.sol";
import {MockOracle, MockClock} from "../mocks/Mocks.sol";

/// @notice Compares the on-chain QVIX against the TypeScript reference implementation
///         (scripts/reference/qvix.ts) on random price paths, invalid prices, multi-period gaps and re-bases.
contract VolIndexReferenceTest is Test {
    uint256 constant N = 5;
    uint256 constant WINDOW = 20;
    uint256 constant PPY = 1764;
    uint256 constant MAX_ABS = 0.25e18;
    uint256 constant QUORUM = 4;

    MockOracle oracle;
    MockClock clock;
    PriceSampler sampler;
    VolIndex index;
    address[] assets;

    function setUp() public {
        oracle = new MockOracle();
        clock = new MockClock();
        for (uint256 i; i < N; ++i) {
            assets.push(address(uint160(0x1000 + i)));
        }
        sampler = new PriceSampler(address(this), assets, WINDOW, MAX_ABS, QUORUM);
        index = new VolIndex(address(this), sampler, IPriceOracle(address(oracle)), IMarketClock(address(clock)), PPY);
        sampler.grantRole(sampler.SAMPLER_ROLE(), address(index));
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_matchesTypeScriptReference(uint256 seed, uint8 nSamplesRaw, uint8 volRaw) public {
        uint256 nSamples = 25 + (uint256(nSamplesRaw) % 40);
        uint256 volBps = 10 + (uint256(volRaw) % 1500); // per-step move up to 15%, exercises clamping
        uint256[] memory prices = new uint256[](N);
        for (uint256 i; i < N; ++i) {
            prices[i] = (50 + i * 13) * 1e18;
        }
        string memory body;
        for (uint256 s; s < nSamples; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, s)));
            uint256 periods = 1 + (r % 3);
            bool gap = s > 0 && (r >> 8) % 40 == 0;
            string memory row;
            uint256 invalidLeft = N - QUORUM;
            for (uint256 i; i < N; ++i) {
                uint256 ri = uint256(keccak256(abi.encode(seed, s, i)));
                int256 step = int256(ri % (2 * volBps + 1)) - int256(volBps);
                prices[i] = uint256(int256(prices[i]) + (int256(prices[i]) * step) / 10_000);
                if (prices[i] < 1e15) prices[i] = 1e15;
                bool invalid = invalidLeft > 0 && (ri >> 16) % 12 == 0;
                if (invalid) invalidLeft--;
                oracle.set(assets[i], prices[i], invalid);
                row = string.concat(row, i == 0 ? "" : ",", invalid ? "0" : vm.toString(prices[i]));
            }
            clock.next(gap ? type(uint256).max : periods);
            index.sample();
            body = string.concat(body, s == 0 ? "" : "|", (s == 0 || gap) ? "max" : vm.toString(periods), ":", row);
        }

        string memory enc = string.concat(
            vm.toString(WINDOW), ";", vm.toString(PPY), ";", vm.toString(MAX_ABS), ";", vm.toString(QUORUM), ";", body
        );
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "../scripts/reference/qvix.ts";
        cmd[2] = enc;
        uint256 expected = abi.decode(vm.ffi(cmd), (uint256));
        (uint256 onchain,) = index.currentIndex();
        if (expected == 0) {
            assertEq(onchain, 0);
        } else {
            assertApproxEqRel(onchain, expected, 1e9, "QVIX differs from reference"); // 1e-9 relative
        }
    }
}
