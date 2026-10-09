// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MarketClock} from "../src/MarketClock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {PriceSampler} from "../src/PriceSampler.sol";
import {VolIndex} from "../src/VolIndex.sol";
import {MarginAccount} from "../src/MarginAccount.sol";
import {LPVault} from "../src/LPVault.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Liquidator} from "../src/Liquidator.sol";
import {VarianceSwap, IVolIndexHistory} from "../src/VarianceSwap.sol";
import {FuturesMarket} from "../src/FuturesMarket.sol";
import {QuakeTimelock} from "../src/Timelock.sol";
import {DateTimeLib} from "../src/libraries/DateTimeLib.sol";
import {
    IVolIndex, IMarginAccount, ILPVault, IFeeCollector, ICompliance, IPriceOracle, IMarketClock, IProjectTokenHooks
} from "../src/interfaces/IQuake.sol";

/// @notice Deterministic deploy + wiring of the whole protocol. Used by script/Deploy.s.sol and by the tests,
///         so tests exercise exactly the production wiring.
abstract contract DeployCore {
    uint256 internal constant WINDOW = 147; // 21 trading days x 7 hourly slots ~= 30 calendar days
    uint256 internal constant PERIODS_PER_YEAR = 1764; // 252 trading days x 7 slots
    uint256 internal constant MAX_ABS_LOG_RETURN = 0.25e18;
    uint256 internal constant EXPIRY_COUNT = 3;

    struct Config {
        address stablecoin;
        address[] assets;
        address[] feeds;
        uint32 feedMaxStaleness;
        address sequencerUptimeFeed;
        address guardian;
        address proposer;
        address treasury; // address(0) => timelock
        uint256 minQuorum;
        uint256 firstExpiryMinLead; // seconds between now and first expiry
    }

    struct Deployment {
        QuakeTimelock timelock;
        MarketClock clock;
        OracleAdapter oracle;
        PriceSampler sampler;
        VolIndex volIndex;
        MarginAccount marginAccount;
        LPVault vault;
        InsuranceFund insurance;
        FeeCollector feeCollector;
        ProjectTokenHooks tokenHooks;
        ComplianceRegistry compliance;
        Liquidator liquidator;
        VarianceSwap varianceSwap;
        FuturesMarket[] markets;
        uint256[] expiries;
    }

    function defaultParams() public pure returns (FuturesMarket.Params memory p) {
        p = FuturesMarket.Params({
            initialMarginBps: 2000,
            maintenanceMarginBps: 1000,
            tradingFeeBps: 10,
            liquidationPenaltyBps: 200,
            liquidatorShareBps: 5000,
            maxNetOiBps: 2000,
            maxGrossOiBps: 5000,
            reserveBps: 5000,
            fundingPeriod: 1 days,
            maxFundingPremiumBps: 1000,
            minPositionNotional: 10e18,
            partialLiquidationNotional: 10_000e18,
            baseDepth: 1_000_000e18,
            settlementRounds: 7,
            maxSettlementPrice: 400e18,
            maxSettlementStaleness: 4 days
        });
    }

    function defaultVammCfg() public pure returns (uint256[4] memory c) {
        c = [uint256(15 minutes), 1000, 1e18, 500e18];
    }

    function _deploy(address deployer, Config memory c) internal returns (Deployment memory d) {
        // ---- governance
        address[] memory proposers = new address[](1);
        proposers[0] = c.proposer;
        d.timelock = new QuakeTimelock(proposers, proposers);
        address tl = address(d.timelock);
        address treasury = c.treasury == address(0) ? tl : c.treasury;

        // ---- index
        d.clock = new MarketClock(deployer);
        _seedCalendar(d.clock);
        d.oracle = new OracleAdapter(deployer);
        for (uint256 i; i < c.assets.length; ++i) {
            d.oracle.setFeed(c.assets[i], c.feeds[i], c.feedMaxStaleness);
        }
        if (c.sequencerUptimeFeed != address(0)) d.oracle.setSequencerUptimeFeed(c.sequencerUptimeFeed, 1 hours);
        d.sampler = new PriceSampler(deployer, c.assets, WINDOW, MAX_ABS_LOG_RETURN, c.minQuorum);
        d.volIndex = new VolIndex(
            deployer, d.sampler, IPriceOracle(address(d.oracle)), IMarketClock(address(d.clock)), PERIODS_PER_YEAR
        );
        d.sampler.grantRole(d.sampler.SAMPLER_ROLE(), address(d.volIndex));

        // ---- money
        IERC20 usd = IERC20(c.stablecoin);
        d.marginAccount = new MarginAccount(deployer, usd);
        d.vault = new LPVault(deployer, usd, IMarginAccount(address(d.marginAccount)), "Quakemeter LP", "qLP");
        d.insurance = new InsuranceFund(deployer, usd);
        d.tokenHooks = new ProjectTokenHooks(deployer, usd);
        d.feeCollector =
            new FeeCollector(deployer, usd, address(d.vault), address(d.insurance), treasury, IProjectTokenHooks(address(d.tokenHooks)));
        d.compliance = new ComplianceRegistry(deployer);
        d.liquidator = new Liquidator(deployer, IMarginAccount(address(d.marginAccount)));
        d.varianceSwap = new VarianceSwap(deployer, usd, IVolIndexHistory(address(d.volIndex)));

        d.marginAccount.setVault(ILPVault(address(d.vault)));
        d.marginAccount.setInsurance(d.insurance);
        d.marginAccount.setCompliance(ICompliance(address(d.compliance)));
        d.vault.setCompliance(ICompliance(address(d.compliance)));
        d.varianceSwap.setCompliance(ICompliance(address(d.compliance)));
        d.insurance.grantRole(d.insurance.COVER_ROLE(), address(d.marginAccount));
        d.tokenHooks.grantRole(d.tokenHooks.NOTIFIER_ROLE(), address(d.feeCollector));

        // ---- futures: next monthly expiries
        d.expiries = _nextExpiries(d.clock, block.timestamp + c.firstExpiryMinLead, EXPIRY_COUNT);
        d.markets = new FuturesMarket[](EXPIRY_COUNT);
        for (uint256 i; i < EXPIRY_COUNT; ++i) {
            d.markets[i] = _deployMarket(d, d.expiries[i], deployer);
            d.marginAccount.addMarket(address(d.markets[i]));
        }

        // ---- hand over: guardian can pause, Timelock is the only admin
        _handOver(d, deployer, tl, c.guardian);
    }

    /// @dev Deploys a market with `admin` as temporary admin and grants the Liquidator its role. The caller
    ///      registers it in the MarginAccount (directly during the initial deploy, via Timelock afterwards).
    function _deployMarket(Deployment memory d, uint256 expiry, address admin) internal returns (FuturesMarket m) {
        m = new FuturesMarket(
            admin,
            expiry,
            FuturesMarket.Deps({
                volIndex: IVolIndex(address(d.volIndex)),
                marginAccount: IMarginAccount(address(d.marginAccount)),
                vault: ILPVault(address(d.vault)),
                insurance: address(d.insurance),
                feeCollector: IFeeCollector(address(d.feeCollector)),
                compliance: ICompliance(address(d.compliance))
            }),
            defaultParams(),
            defaultVammCfg()
        );
        m.grantRole(m.LIQUIDATOR_ROLE(), address(d.liquidator));
    }

    function _handOver(Deployment memory d, address deployer, address tl, address guardian) internal {
        bytes32 admin = 0x00;
        address[] memory pausables = new address[](8 + d.markets.length);
        pausables[0] = address(d.volIndex);
        pausables[1] = address(d.marginAccount);
        pausables[2] = address(d.vault);
        pausables[3] = address(d.insurance);
        pausables[4] = address(d.feeCollector);
        pausables[5] = address(d.tokenHooks);
        pausables[6] = address(d.liquidator);
        pausables[7] = address(d.varianceSwap);
        for (uint256 i; i < d.markets.length; ++i) {
            pausables[8 + i] = address(d.markets[i]);
        }
        bytes32 guardianRole = d.volIndex.GUARDIAN_ROLE();
        for (uint256 i; i < pausables.length; ++i) {
            IAccessControl(pausables[i]).grantRole(guardianRole, guardian);
            IAccessControl(pausables[i]).grantRole(admin, tl);
            IAccessControl(pausables[i]).renounceRole(admin, deployer);
        }
        // non-pausable admin contracts
        d.clock.grantRole(d.clock.CALENDAR_ROLE(), tl);
        d.clock.grantRole(admin, tl);
        d.clock.renounceRole(d.clock.CALENDAR_ROLE(), deployer);
        d.clock.renounceRole(admin, deployer);
        d.oracle.grantRole(admin, tl);
        d.oracle.renounceRole(admin, deployer);
        d.sampler.grantRole(admin, tl);
        d.sampler.renounceRole(admin, deployer);
        d.compliance.grantRole(d.compliance.COMPLIANCE_ROLE(), tl);
        d.compliance.grantRole(admin, tl);
        d.compliance.renounceRole(d.compliance.COMPLIANCE_ROLE(), deployer);
        d.compliance.renounceRole(admin, deployer);
    }

    function _nextExpiries(MarketClock clock, uint256 notBefore, uint256 count)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](count);
        (uint256 y, uint256 m,) = DateTimeLib.civilFromDays(notBefore / 1 days);
        uint256 found;
        for (uint256 guard; found < count && guard < 24; ++guard) {
            uint256 e = clock.monthlyExpiry(y, m);
            if (e >= notBefore) out[found++] = e;
            if (++m == 13) {
                m = 1;
                ++y;
            }
        }
    }

    /// @dev NYSE full-day holidays and 13:00 early closes for 2026-2027 (source: nyse.com/markets/hours-calendars).
    function _seedCalendar(MarketClock clock) internal {
        uint256[20] memory h = [
            DateTimeLib.daysFromCivil(2026, 1, 1),
            DateTimeLib.daysFromCivil(2026, 1, 19),
            DateTimeLib.daysFromCivil(2026, 2, 16),
            DateTimeLib.daysFromCivil(2026, 4, 3),
            DateTimeLib.daysFromCivil(2026, 5, 25),
            DateTimeLib.daysFromCivil(2026, 6, 19),
            DateTimeLib.daysFromCivil(2026, 7, 3),
            DateTimeLib.daysFromCivil(2026, 9, 7),
            DateTimeLib.daysFromCivil(2026, 11, 26),
            DateTimeLib.daysFromCivil(2026, 12, 25),
            DateTimeLib.daysFromCivil(2027, 1, 1),
            DateTimeLib.daysFromCivil(2027, 1, 18),
            DateTimeLib.daysFromCivil(2027, 2, 15),
            DateTimeLib.daysFromCivil(2027, 3, 26),
            DateTimeLib.daysFromCivil(2027, 5, 31),
            DateTimeLib.daysFromCivil(2027, 6, 18),
            DateTimeLib.daysFromCivil(2027, 7, 5),
            DateTimeLib.daysFromCivil(2027, 9, 6),
            DateTimeLib.daysFromCivil(2027, 11, 25),
            DateTimeLib.daysFromCivil(2027, 12, 24)
        ];
        uint256[] memory days_ = new uint256[](20);
        for (uint256 i; i < 20; ++i) {
            days_[i] = h[i];
        }
        clock.setHolidays(days_, true);
        clock.setEarlyClose(DateTimeLib.daysFromCivil(2026, 11, 27), 780);
        clock.setEarlyClose(DateTimeLib.daysFromCivil(2026, 12, 24), 780);
        clock.setEarlyClose(DateTimeLib.daysFromCivil(2027, 11, 26), 780);
    }
}
