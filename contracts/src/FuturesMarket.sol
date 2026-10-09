// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {VAMM} from "./vAMM.sol";
import {
    IVolIndex, IMarginAccount, ILPVault, ICompliance, IFeeCollector, IFuturesMarketView
} from "./interfaces/IQuake.sol";

/// @title FuturesMarket
/// @notice One cash-settled QVIX futures expiry. Long/short positions with isolated margin (max 5x by
///         default), priced by a dedicated vAMM, with funding toward the spot QVIX, partial permissionless
///         liquidations (through the Liquidator) and settlement against the average of the last QVIX prints at
///         or before expiry. The LPVault is the counterparty for all PnL. 1 contract = $1 per QVIX point.
contract FuturesMarket is QuakeBase, IFuturesMarketView {
    using SignedMath for int256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    /// @notice Funding pauses if the latest QVIX print is older than this (covers weekends + a holiday).
    uint256 public constant MAX_INDEX_AGE = 4 days;

    enum Status {
        Pending,
        Trading,
        Settled
    }

    struct Params {
        uint256 initialMarginBps; // 2000 = 20% => 5x max leverage
        uint256 maintenanceMarginBps; // 1000 = 10%
        uint256 tradingFeeBps; // 10 = 0.10% of notional
        uint256 liquidationPenaltyBps; // 200 = 2% of liquidated notional
        uint256 liquidatorShareBps; // 5000 = half of the penalty to the liquidator, rest to insurance
        uint256 maxNetOiBps; // net open notional cap, bps of vault assets
        uint256 maxGrossOiBps; // per-side open notional cap, bps of vault assets
        uint256 reserveBps; // vault reserve held against net open notional
        uint256 fundingPeriod; // seconds over which a premium is paid in full (1 day)
        uint256 maxFundingPremiumBps; // clamp |mark - index| / index
        uint256 minPositionNotional; // USD 18 decimals
        uint256 partialLiquidationNotional; // above this notional, liquidations close half
        uint256 baseDepth; // vAMM base reserve at open
        uint256 settlementRounds; // QVIX prints averaged for settlement
        uint256 maxSettlementPrice; // cap, QVIX points 18 decimals
        uint256 maxSettlementStaleness; // last print must be within this of expiry
    }

    struct Position {
        address owner;
        bool settled;
        int256 size; // + long / - short, contracts 18 decimals
        uint256 openNotional; // USD 18 decimals
        uint256 margin; // collateral token units
        int256 entryCumFunding; // cumulative funding at last realization
    }

    struct Deps {
        IVolIndex volIndex;
        IMarginAccount marginAccount;
        ILPVault vault;
        address insurance;
        IFeeCollector feeCollector;
        ICompliance compliance;
    }

    // ------------------------------------------------------------------ immutables / config
    uint256 public immutable expiry;
    VAMM public immutable vamm;
    IVolIndex public immutable volIndex;
    IMarginAccount public immutable marginAccount;
    ILPVault public immutable vault;
    address public immutable insurance;
    IFeeCollector public immutable feeCollector;
    uint256 internal immutable _scale; // 10**(18 - collateral decimals)
    ICompliance public compliance;
    Params internal params;

    // ------------------------------------------------------------------ state
    Status public status;
    uint256 public settlementPrice;
    int256 public cumFunding; // USD per contract, 18 decimals
    uint256 public lastFundingTs;

    uint256 public nextPositionId = 1;
    mapping(uint256 => Position) internal _positions;
    mapping(address => uint256[]) internal _positionsOf;

    // aggregates (for vault liability accounting)
    uint256 public longSize;
    uint256 public shortSize;
    uint256 public longOpenNotional;
    uint256 public shortOpenNotional;
    int256 public aggSizeEntryFunding; // sum(size * entryCumFunding) / WAD

    // ------------------------------------------------------------------ events
    event TradingOpened(uint256 price, uint256 baseDepth);
    event PositionOpened(
        uint256 indexed id, address indexed owner, int256 size, uint256 notional, uint256 margin, uint256 fee
    );
    event PositionReduced(uint256 indexed id, uint256 closedSize, int256 realizedPnl, uint256 fee, int256 remainingSize);
    event PositionClosed(uint256 indexed id, address indexed owner, uint256 marginReturned);
    event MarginChanged(uint256 indexed id, int256 delta, uint256 newMargin);
    event FundingUpdated(int256 cumFunding, int256 premium, uint256 timestamp);
    event Liquidated(uint256 indexed id, address indexed liquidator, uint256 closedSize, uint256 penalty, uint256 reward);
    event BadDebt(uint256 indexed id, uint256 amount);
    event BadDebtCovered(uint256 amount, uint256 covered);
    event MarketSettled(uint256 price, uint256 hintRound, bool emergency);
    event PositionSettled(uint256 indexed id, address indexed owner, int256 pnl, uint256 payout);
    event ParamsSet(uint256 initialMarginBps, uint256 maintenanceMarginBps, uint256 tradingFeeBps, bytes32 paramsHash);
    event ComplianceSet(address compliance);

    // ------------------------------------------------------------------ errors
    error WrongStatus();
    error Expired();
    error NotExpired();
    error NotReady();
    error NotOwner();
    error NotAllowed();
    error ZeroSize();
    error SlippageExceeded();
    error BelowMinNotional();
    error InsufficientMargin();
    error OiCapExceeded();
    error NotLiquidatable();
    error AlreadySettled();
    error StaleSettlement();
    error TooEarly();
    error ProfitShortfall();
    error QuoteMismatch();
    error StaleIndex();

    constructor(address admin, uint256 expiry_, Deps memory deps, Params memory params_, uint256[4] memory vammCfg)
        QuakeBase(admin)
    {
        if (expiry_ <= block.timestamp) revert InvalidParam();
        if (
            address(deps.volIndex) == address(0) || address(deps.marginAccount) == address(0)
                || address(deps.vault) == address(0) || deps.insurance == address(0)
                || address(deps.feeCollector) == address(0)
        ) revert ZeroAddress();
        expiry = expiry_;
        volIndex = deps.volIndex;
        marginAccount = deps.marginAccount;
        vault = deps.vault;
        insurance = deps.insurance;
        feeCollector = deps.feeCollector;
        compliance = deps.compliance;
        uint8 dec = IERC20Metadata(deps.marginAccount.collateral()).decimals();
        if (dec > 18) revert InvalidParam();
        _scale = 10 ** (18 - dec);
        _setParams(params_);
        // vammCfg: [emaWindow, maxImpactBps, minPrice, maxPrice]
        vamm = new VAMM(address(this), vammCfg[0], vammCfg[1], vammCfg[2], vammCfg[3]);
    }

    // ------------------------------------------------------------------ admin

    function setParams(Params calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setParams(p);
    }

    function setCompliance(ICompliance c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = c;
        emit ComplianceSet(address(c));
    }

    function _setParams(Params memory p) internal {
        if (
            p.initialMarginBps < 1000 || p.initialMarginBps > BPS || p.maintenanceMarginBps == 0
                || p.maintenanceMarginBps >= p.initialMarginBps || p.tradingFeeBps > 100
                || p.liquidationPenaltyBps > 1000 || p.liquidatorShareBps > BPS || p.maxNetOiBps > BPS
                || p.maxGrossOiBps > 5 * BPS || p.reserveBps > BPS || p.fundingPeriod < 1 hours
                || p.maxFundingPremiumBps > BPS || p.baseDepth < WAD || p.settlementRounds == 0
                || p.settlementRounds > 64 || p.maxSettlementPrice == 0 || p.maxSettlementStaleness == 0
        ) revert InvalidParam();
        params = p;
        emit ParamsSet(p.initialMarginBps, p.maintenanceMarginBps, p.tradingFeeBps, keccak256(abi.encode(p)));
    }

    // ------------------------------------------------------------------ lifecycle

    /// @notice Permissionless: opens trading once QVIX has a full window. vAMM starts at spot QVIX.
    function openTrading() external whenNotPaused nonReentrant {
        if (status != Status.Pending) revert WrongStatus();
        if (block.timestamp + 1 days >= expiry) revert Expired();
        if (!volIndex.isReady()) revert NotReady();
        (uint256 index, uint256 indexTs) = volIndex.latestIndex();
        if (indexTs + MAX_INDEX_AGE < block.timestamp) revert StaleIndex();
        status = Status.Trading;
        lastFundingTs = block.timestamp;
        vamm.initialize(index, params.baseDepth);
        emit TradingOpened(index, params.baseDepth);
    }

    /// @notice Permissionless settlement after expiry. `hintRound` must be the last QVIX round at or before expiry.
    function settle(uint256 hintRound) external whenNotPaused nonReentrant {
        if (status == Status.Settled) revert AlreadySettled();
        if (block.timestamp <= expiry) revert NotExpired();
        IVolIndex.Round memory r = volIndex.getRound(hintRound);
        if (r.timestamp + params.maxSettlementStaleness < expiry) revert StaleSettlement();
        uint256 price = volIndex.averageIndexAt(expiry, hintRound, params.settlementRounds);
        _finalize(price, hintRound, false);
    }

    /// @notice Timelock fallback if the index cannot produce a valid settlement within 7 days of expiry.
    function emergencySettle(uint256 price) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (status == Status.Settled) revert AlreadySettled();
        if (block.timestamp <= expiry + 7 days) revert TooEarly();
        _finalize(price, 0, true);
    }

    function _finalize(uint256 price, uint256 hint, bool emergency) internal {
        _updateFunding();
        if (price > params.maxSettlementPrice) price = params.maxSettlementPrice;
        settlementPrice = price;
        status = Status.Settled;
        emit MarketSettled(price, hint, emergency);
    }

    // ------------------------------------------------------------------ trading

    function openPosition(bool isLong, uint256 size, uint256 marginAmount, uint256 priceLimit)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 id)
    {
        _requireTrading();
        if (address(compliance) != address(0) && !compliance.isAllowed(msg.sender)) revert NotAllowed();
        if (size == 0 || size > uint256(type(int256).max)) revert ZeroSize();
        _updateFunding();

        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedSize = isLong ? int256(size) : -int256(size);
        // slither-disable-next-line reentrancy-no-eth
        int256 q = vamm.swap(signedSize, true); // trusted: immutable vAMM created by this market, no callbacks
        uint256 notional = q.abs();
        _checkLimit(isLong, notional, size, priceLimit);
        if (notional < params.minPositionNotional) revert BelowMinNotional();

        uint256 fee = _fee(msg.sender, notional);
        if (marginAmount <= fee) revert InsufficientMargin();
        uint256 margin = marginAmount - fee;
        if (margin * _scale * BPS < notional * params.initialMarginBps) revert InsufficientMargin();

        id = nextPositionId++;
        _positions[id] = Position({
            owner: msg.sender, settled: false, size: signedSize, openNotional: notional, margin: margin, entryCumFunding: cumFunding
        });
        _positionsOf[msg.sender].push(id);
        _addAggregates(signedSize, notional, cumFunding);
        _checkOiCaps();
        if (_isLiquidatable(_positions[id])) revert InsufficientMargin();
        emit PositionOpened(id, msg.sender, signedSize, notional, margin, fee);

        Flows memory f = _newFlows(msg.sender);
        f.lockAmount = marginAmount;
        f.fee = fee;
        _execute(f);
    }

    /// @notice Close `closeSize` contracts of a position (pass the full size, or type(uint256).max, to close).
    function closePosition(uint256 id, uint256 closeSize, uint256 priceLimit) external whenNotPaused nonReentrant {
        _requireTrading();
        Position storage p = _ownedOpen(id);
        _updateFunding();
        uint256 absSize = p.size.abs();
        if (closeSize > absSize) closeSize = absSize;
        if (closeSize == 0) revert ZeroSize();
        bool isLong = p.size > 0;

        Flows memory f = _newFlows(p.owner);
        (uint256 exitQuote, int256 pnl) = _reduce(id, p, closeSize, true, f);
        // closing a long sells; closing a short buys
        _checkLimit(!isLong, exitQuote, closeSize, priceLimit);
        uint256 fee = _fee(p.owner, exitQuote);
        f.fee += _takeFromMargin(p, fee);
        emit PositionReduced(id, closeSize, pnl, fee, p.size);

        if (p.size == 0) {
            f.unlock += _closeOut(id, p);
        } else if (_isLiquidatable(p)) {
            revert InsufficientMargin();
        }
        _execute(f);
    }

    function addMargin(uint256 id, uint256 amount) external whenNotPaused nonReentrant {
        _requireTrading();
        Position storage p = _ownedOpen(id);
        if (amount == 0) revert ZeroSize();
        p.margin += amount;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit MarginChanged(id, int256(amount), p.margin);
        Flows memory f = _newFlows(msg.sender);
        f.lockAmount = amount;
        _execute(f);
    }

    function removeMargin(uint256 id, uint256 amount) external whenNotPaused nonReentrant {
        _requireTrading();
        Position storage p = _ownedOpen(id);
        _updateFunding();
        Flows memory f = _newFlows(msg.sender);
        _applyPnl(id, p, -_resetFunding(p), f);
        if (amount == 0 || amount > p.margin) revert InsufficientMargin();
        p.margin -= amount;
        uint256 mark = vamm.currentEma();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 required = int256(Math.mulDiv(p.size.abs() * mark, params.initialMarginBps, WAD * BPS));
        if (_equity(p, mark) < required) revert InsufficientMargin();
        // forge-lint: disable-next-line(unsafe-typecast)
        emit MarginChanged(id, -int256(amount), p.margin);
        f.unlock = amount;
        _execute(f);
    }

    // ------------------------------------------------------------------ liquidation

    /// @notice Called by the Liquidator. Closes half (large positions) or all of an unhealthy position at the
    ///         vAMM, charges a penalty split between `beneficiary` and the insurance fund.
    function liquidate(uint256 id, address beneficiary)
        external
        whenNotPaused
        nonReentrant
        onlyRole(LIQUIDATOR_ROLE)
        returns (uint256 reward)
    {
        if (status != Status.Trading) revert WrongStatus();
        if (block.timestamp >= expiry) revert Expired();
        Position storage p = _positions[id];
        if (p.owner == address(0) || p.size == 0 || p.settled) revert NotLiquidatable();
        _updateFunding();
        if (!_isLiquidatable(p)) revert NotLiquidatable();

        uint256 mark = vamm.currentEma();
        uint256 absSize = p.size.abs();
        uint256 closeSize = absSize;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 maint = int256(Math.mulDiv(absSize * mark, params.maintenanceMarginBps, WAD * BPS));
        if ((absSize * mark) / WAD > params.partialLiquidationNotional && _equity(p, mark) * 2 >= maint) {
            closeSize = absSize / 2;
        }

        Flows memory f = _newFlows(p.owner);
        (uint256 exitQuote,) = _reduce(id, p, closeSize, false, f);
        uint256 penalty = _takeFromMargin(p, _toTokenUp((exitQuote * params.liquidationPenaltyBps) / BPS));
        reward = (penalty * params.liquidatorShareBps) / BPS;
        f.toLiquidator = reward;
        f.liquidator = beneficiary;
        f.toInsurance = penalty - reward;
        emit Liquidated(id, beneficiary, closeSize, penalty, reward);

        if (p.size == 0) f.unlock += _closeOut(id, p);
        _execute(f);
    }

    // ------------------------------------------------------------------ settlement of positions

    /// @notice Permissionless once the market is settled; proceeds always go to the position owner.
    function settlePosition(uint256 id) external whenNotPaused nonReentrant returns (uint256 payout) {
        if (status != Status.Settled) revert WrongStatus();
        Position storage p = _positions[id];
        if (p.owner == address(0)) revert NotOwner();
        if (p.settled) revert AlreadySettled();
        p.settled = true; // each position settles exactly once

        Flows memory f = _newFlows(p.owner);
        if (p.size != 0) {
            int256 owed = _resetFunding(p);
            uint256 value = (p.size.abs() * settlementPrice) / WAD;
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 pnl = p.size > 0 ? int256(value) - int256(p.openNotional) : int256(p.openNotional) - int256(value);
            _removeAggregates(p.size, p.openNotional, p.entryCumFunding);
            p.size = 0;
            p.openNotional = 0;
            _applyPnl(id, p, pnl - owed, f);
            emit PositionSettled(id, p.owner, pnl - owed, p.margin);
        }
        payout = p.margin;
        p.margin = 0;
        f.unlock = payout;
        _execute(f);
    }

    // ------------------------------------------------------------------ internals: position math
    //
    // All position state is updated first; token movements are accumulated in a `Flows` struct and executed
    // once at the end of each external function (checks-effects-interactions).

    struct Flows {
        address owner;
        uint256 capacity; // profit the vault + insurance fund can still pay in this tx
        uint256 lockAmount; // free -> locked for owner
        uint256 profit; // vault -> locked
        uint256 toVault; // locked -> vault (trader losses)
        uint256 badDebt; // insurance -> vault
        uint256 fee; // locked -> fee collector
        uint256 toLiquidator;
        address liquidator;
        uint256 toInsurance;
        uint256 unlock; // locked -> owner's free balance
        int256 swapDelta; // vAMM trade to execute (quoted beforehand)
        int256 swapQuote;
        bool enforceImpact;
    }

    function _newFlows(address owner) internal view returns (Flows memory f) {
        f.owner = owner;
        f.capacity = marginAccount.profitCapacity();
    }

    function _execute(Flows memory f) internal {
        if (f.swapDelta != 0) {
            // executes exactly the trade that was quoted and booked above
            if (vamm.swap(f.swapDelta, f.enforceImpact) != f.swapQuote) revert QuoteMismatch();
        }
        if (f.lockAmount != 0) marginAccount.lock(f.owner, f.lockAmount);
        if (f.profit != 0) {
            uint256 paid = marginAccount.pullProfit(f.profit);
            if (paid != f.profit) revert ProfitShortfall();
        }
        if (f.toVault != 0) marginAccount.payFromLocked(address(vault), f.toVault);
        if (f.badDebt != 0) {
            uint256 covered = marginAccount.coverBadDebt(f.badDebt);
            emit BadDebtCovered(f.badDebt, covered);
        }
        if (f.fee != 0) marginAccount.payFromLocked(address(feeCollector), f.fee);
        if (f.toLiquidator != 0) marginAccount.payFromLocked(f.liquidator, f.toLiquidator);
        if (f.toInsurance != 0) marginAccount.payFromLocked(insurance, f.toInsurance);
        if (f.unlock != 0) marginAccount.unlock(f.owner, f.unlock);
    }

    /// @dev Closes `closeSize` contracts through the vAMM; funding and trade PnL are netted into margin.
    function _reduce(uint256 id, Position storage p, uint256 closeSize, bool enforceImpact, Flows memory f)
        internal
        returns (uint256 exitQuote, int256 pnl)
    {
        bool isLong = p.size > 0;
        uint256 absSize = p.size.abs();
        uint256 entryPart = Math.mulDiv(p.openNotional, closeSize, absSize);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 delta = isLong ? -int256(closeSize) : int256(closeSize);
        int256 q = vamm.quote(delta); // the swap itself runs last, in _execute
        f.swapDelta = delta;
        f.swapQuote = q;
        f.enforceImpact = enforceImpact;
        exitQuote = q.abs();
        // forge-lint: disable-next-line(unsafe-typecast)
        pnl = isLong ? int256(exitQuote) - int256(entryPart) : int256(entryPart) - int256(exitQuote);

        int256 owed = _resetFunding(p);
        _removeAggregates(p.size, p.openNotional, p.entryCumFunding);
        // forge-lint: disable-next-line(unsafe-typecast)
        p.size -= isLong ? int256(closeSize) : -int256(closeSize);
        p.openNotional -= entryPart;
        _addAggregates(p.size, p.openNotional, p.entryCumFunding);
        _applyPnl(id, p, pnl - owed, f);
    }

    /// @dev Resets the position's funding index to the current one and returns the funding it owed.
    function _resetFunding(Position storage p) internal returns (int256 owed) {
        owed = _fundingOwed(p);
        if (p.entryCumFunding != cumFunding) {
            _removeAggregates(p.size, p.openNotional, p.entryCumFunding);
            p.entryCumFunding = cumFunding;
            _addAggregates(p.size, p.openNotional, p.entryCumFunding);
        }
    }

    /// @dev Books a USD PnL (18 decimals) into margin and the pending flows. Profit is capped at what the vault
    ///      and insurance fund can pay (so the later pull is always paid in full); losses beyond margin are bad debt.
    function _applyPnl(uint256 id, Position storage p, int256 pnl, Flows memory f) internal {
        if (pnl > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 want = uint256(pnl) / _scale;
            if (want > f.capacity) want = f.capacity;
            f.capacity -= want;
            p.margin += want;
            f.profit += want;
        } else if (pnl < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 loss = _toTokenUp(uint256(-pnl));
            uint256 m = p.margin;
            if (loss <= m) {
                p.margin = m - loss;
                f.toVault += loss;
            } else {
                p.margin = 0;
                f.toVault += m;
                f.badDebt += loss - m;
                emit BadDebt(id, loss - m);
            }
        }
    }

    function _takeFromMargin(Position storage p, uint256 amount) internal returns (uint256 taken) {
        taken = amount > p.margin ? p.margin : amount;
        p.margin -= taken;
    }

    function _closeOut(uint256 id, Position storage p) internal returns (uint256 m) {
        m = p.margin;
        p.margin = 0;
        p.settled = true;
        emit PositionClosed(id, p.owner, m);
    }

    function _fundingOwed(Position storage p) internal view returns (int256) {
        return (p.size * (cumFunding - p.entryCumFunding)) / int256(WAD);
    }

    function _equity(Position storage p, uint256 mark) internal view returns (int256) {
        return int256(p.margin * _scale) + _unrealizedPnl(p.size, p.openNotional, mark) - _fundingOwed(p);
    }

    function _unrealizedPnl(int256 size, uint256 openNotional, uint256 mark) internal pure returns (int256) {
        if (size == 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 value = int256((size.abs() * mark) / WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        return size > 0 ? value - int256(openNotional) : int256(openNotional) - value;
    }

    function _isLiquidatable(Position storage p) internal view returns (bool) {
        if (p.size == 0) return false;
        uint256 mark = vamm.currentEma();
        // forge-lint: disable-next-line(unsafe-typecast)
        return _equity(p, mark) < int256(Math.mulDiv(p.size.abs() * mark, params.maintenanceMarginBps, WAD * BPS));
    }

    function _updateFunding() internal {
        uint256 t = block.timestamp < expiry ? block.timestamp : expiry;
        uint256 last = lastFundingTs;
        if (status != Status.Trading || t <= last) return;
        lastFundingTs = t;
        (uint256 index, uint256 indexTs) = volIndex.latestIndex();
        // a stale or empty index never drives funding
        if (index == 0 || indexTs + MAX_INDEX_AGE < t) return;
        uint256 mark = vamm.currentEma();
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 premium = int256(mark) - int256(index);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 cap = int256((index * params.maxFundingPremiumBps) / BPS);
        if (premium > cap) premium = cap;
        if (premium < -cap) premium = -cap;
        // forge-lint: disable-next-line(unsafe-typecast)
        cumFunding += (premium * int256(t - last)) / int256(params.fundingPeriod);
        emit FundingUpdated(cumFunding, premium, t);
    }

    function _addAggregates(int256 size, uint256 openNotional, int256 entryCum) internal {
        if (size > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            longSize += uint256(size);
            longOpenNotional += openNotional;
        } else if (size < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            shortSize += uint256(-size);
            shortOpenNotional += openNotional;
        }
        aggSizeEntryFunding += (size * entryCum) / int256(WAD);
    }

    function _removeAggregates(int256 size, uint256 openNotional, int256 entryCum) internal {
        if (size > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            longSize -= uint256(size);
            longOpenNotional -= openNotional;
        } else if (size < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            shortSize -= uint256(-size);
            shortOpenNotional -= openNotional;
        }
        aggSizeEntryFunding -= (size * entryCum) / int256(WAD);
    }

    function _checkOiCaps() internal view {
        uint256 mark = vamm.markPrice();
        // compare size * mark * BPS against vaultAssets(1e18) * cap * WAD: no intermediate division
        uint256 vaultScaled = vault.totalAssets() * _scale * WAD;
        uint256 net = longSize > shortSize ? longSize - shortSize : shortSize - longSize;
        if (net * mark * BPS > vaultScaled * params.maxNetOiBps) revert OiCapExceeded();
        uint256 gross = longSize > shortSize ? longSize : shortSize;
        if (gross * mark * BPS > vaultScaled * params.maxGrossOiBps) revert OiCapExceeded();
    }

    function _checkLimit(bool buying, uint256 quoteAmt, uint256 size, uint256 priceLimit) internal pure {
        if (priceLimit == 0) return;
        uint256 avg = Math.mulDiv(quoteAmt, WAD, size);
        if (buying ? avg > priceLimit : avg < priceLimit) revert SlippageExceeded();
    }

    function _fee(address user, uint256 notional) internal view returns (uint256) {
        uint256 discount = feeCollector.feeDiscountBps(user);
        uint256 feeWad = (notional * params.tradingFeeBps * (BPS - discount)) / (BPS * BPS);
        return _toTokenUp(feeWad);
    }

    function _toTokenUp(uint256 wad) internal view returns (uint256) {
        return Math.ceilDiv(wad, _scale);
    }

    function _requireTrading() internal view {
        if (status != Status.Trading) revert WrongStatus();
        if (block.timestamp >= expiry) revert Expired();
    }

    function _ownedOpen(uint256 id) internal view returns (Position storage p) {
        p = _positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (p.settled || p.size == 0) revert AlreadySettled();
    }

    // ------------------------------------------------------------------ views

    function _currentMark() internal view returns (uint256) {
        if (status == Status.Settled) return settlementPrice;
        return vamm.currentEma();
    }

    /// @inheritdoc IFuturesMarketView
    function aggregateTraderPnl() external view override returns (int256) {
        uint256 mark = _currentMark();
        if (mark == 0) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 longPnl = int256((longSize * mark) / WAD) - int256(longOpenNotional);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 shortPnl = int256(shortOpenNotional) - int256((shortSize * mark) / WAD);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 netSize = int256(longSize) - int256(shortSize);
        int256 fundingOwed = (netSize * _projectedCumFunding()) / int256(WAD) - aggSizeEntryFunding;
        return longPnl + shortPnl - fundingOwed;
    }

    /// @inheritdoc IFuturesMarketView
    function requiredReserve() external view override returns (uint256) {
        if (status != Status.Trading) return 0;
        uint256 mark = vamm.markPrice();
        uint256 longN = (longSize * mark) / WAD;
        uint256 shortN = (shortSize * mark) / WAD;
        uint256 net = longN > shortN ? longN - shortN : shortN - longN;
        return (net * params.reserveBps) / BPS;
    }

    /// @dev cumFunding including accrual since the last update (view only).
    function _projectedCumFunding() internal view returns (int256 c) {
        c = cumFunding;
        uint256 t = block.timestamp < expiry ? block.timestamp : expiry;
        if (status != Status.Trading || t <= lastFundingTs) return c;
        (uint256 index, uint256 indexTs) = volIndex.latestIndex();
        if (index == 0 || indexTs + MAX_INDEX_AGE < t) return c;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 premium = int256(vamm.currentEma()) - int256(index);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 cap = int256((index * params.maxFundingPremiumBps) / BPS);
        if (premium > cap) premium = cap;
        if (premium < -cap) premium = -cap;
        // forge-lint: disable-next-line(unsafe-typecast)
        c += (premium * int256(t - lastFundingTs)) / int256(params.fundingPeriod);
    }

    function getParams() external view returns (Params memory) {
        return params;
    }

    function getPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function positionsOf(address owner) external view returns (uint256[] memory) {
        return _positionsOf[owner];
    }

    struct PositionView {
        int256 size;
        uint256 openNotional;
        uint256 margin;
        uint256 entryPrice;
        uint256 markPrice;
        int256 unrealizedPnl;
        int256 fundingOwed;
        int256 equity;
        uint256 liquidationPrice;
        bool liquidatable;
        bool settled;
    }

    function positionView(uint256 id) external view returns (PositionView memory v) {
        Position storage p = _positions[id];
        v.size = p.size;
        v.openNotional = p.openNotional;
        v.margin = p.margin;
        v.settled = p.settled;
        if (p.size == 0) return v;
        uint256 absSize = p.size.abs();
        v.entryPrice = Math.mulDiv(p.openNotional, WAD, absSize);
        v.markPrice = _currentMark();
        v.unrealizedPnl = _unrealizedPnl(p.size, p.openNotional, v.markPrice);
        v.fundingOwed = (p.size * (_projectedCumFunding() - p.entryCumFunding)) / int256(WAD);
        v.equity = int256(p.margin * _scale) + v.unrealizedPnl - v.fundingOwed;
        v.liquidatable = status == Status.Trading && block.timestamp < expiry && _isLiquidatable(p);
        v.liquidationPrice = _liquidationPrice(p.size, p.openNotional, p.margin * _scale, v.fundingOwed);
    }

    /// @dev Long:  M + s*P - N - F = mmr*s*P  =>  P = (N + F - M) / (s * (1 - mmr))
    ///      Short: M + N - s*P - F = mmr*s*P  =>  P = (M + N - F) / (s * (1 + mmr))
    function _liquidationPrice(int256 size, uint256 n, uint256 m, int256 f) internal view returns (uint256) {
        uint256 s = size.abs();
        uint256 mmr = params.maintenanceMarginBps;
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 num = size > 0 ? int256(n) + f - int256(m) : int256(m) + int256(n) - f;
        if (num <= 0) return 0;
        uint256 denomBps = size > 0 ? BPS - mmr : BPS + mmr;
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(uint256(num), WAD * BPS, s * denomBps);
    }

    function isLiquidatable(uint256 id) external view returns (bool) {
        Position storage p = _positions[id];
        if (status != Status.Trading || block.timestamp >= expiry || p.settled) return false;
        return _isLiquidatable(p);
    }

    function markPrice() external view returns (uint256) {
        return vamm.markPrice();
    }

    function emaMarkPrice() external view returns (uint256) {
        return vamm.currentEma();
    }

    function collateralScale() external view returns (uint256) {
        return _scale;
    }
}
