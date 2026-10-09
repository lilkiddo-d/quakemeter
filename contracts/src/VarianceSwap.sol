// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {ICompliance} from "./interfaces/IQuake.sol";

interface IVolIndexHistory {
    function latestRoundId() external view returns (uint256);

    function isLastRoundBefore(uint256 cutoff, uint256 hintRoundId) external view returns (bool);

    function realizedVarianceBetween(uint256 startRound, uint256 endRound) external view returns (uint256);
}

/// @title VarianceSwap
/// @notice Optional peer-to-peer variance swaps on the QVIX basket. A maker posts an offer (side, volatility
///         strike, variance notional, tenor); a taker fills it. Both sides are fully collateralized:
///           long  pays at most  N * K              (realized variance = 0)
///           short pays at most  N * (capVar - K)   (realized variance capped at (2.5 * strike vol)^2)
///         Payoff to long = N * (RV - K), RV = annualized realized variance (vol points^2) of the returns that
///         start at or after the fill and end at or before maturity. Settlement is permissionless; proceeds
///         are credited and withdrawn with `claim` (pull payments: a frozen account cannot block the other side).
contract VarianceSwap is QuakeBase {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant CAP_VOL_MULTIPLE_BPS = 25_000; // realized vol capped at 2.5x strike vol
    uint256 public constant MIN_TENOR = 1 days;
    uint256 public constant MAX_TENOR = 180 days;
    uint256 public constant REFUND_GRACE = 30 days;

    enum Status {
        None,
        Open,
        Active,
        Settled,
        Cancelled,
        Refunded
    }

    struct Swap {
        address maker;
        address taker;
        bool makerIsLong;
        Status status;
        uint64 tenor;
        uint64 offerDeadline;
        uint64 start;
        uint64 end;
        uint256 strikeVar; // vol points^2, 18 decimals (20 vol => 400e18)
        uint256 notional; // collateral token units per 1 variance point
        uint256 longCollateral;
        uint256 shortCollateral;
        uint256 realizedVar; // set at settlement
    }

    IERC20 public immutable token;
    IVolIndexHistory public immutable volIndex;
    ICompliance public compliance;

    uint256 public nextSwapId = 1;
    mapping(uint256 => Swap) internal _swaps;
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;
    uint256 public totalEscrowed;

    event OfferCreated(
        uint256 indexed id, address indexed maker, bool makerIsLong, uint256 strikeVol, uint256 notional, uint256 tenor
    );
    event OfferCancelled(uint256 indexed id);
    event OfferTaken(uint256 indexed id, address indexed taker, uint256 start, uint256 end);
    event SwapSettled(uint256 indexed id, uint256 realizedVar, int256 longPayoff, uint256 toLong, uint256 toShort);
    event SwapRefunded(uint256 indexed id);
    event Claimed(address indexed user, uint256 amount);
    event ComplianceSet(address compliance);

    error BadParams();
    error WrongStatus();
    error NotMaker();
    error NotAllowed();
    error OfferExpired();
    error NotMatured();
    error BadHint();
    error TooEarly();

    constructor(address admin, IERC20 token_, IVolIndexHistory volIndex_) QuakeBase(admin) {
        if (address(token_) == address(0) || address(volIndex_) == address(0)) revert ZeroAddress();
        token = token_;
        volIndex = volIndex_;
    }

    function setCompliance(ICompliance c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = c;
        emit ComplianceSet(address(c));
    }

    // ------------------------------------------------------------------ helpers

    function capVariance(uint256 strikeVar) public pure returns (uint256) {
        return (strikeVar * CAP_VOL_MULTIPLE_BPS * CAP_VOL_MULTIPLE_BPS) / (BPS * BPS);
    }

    function collateralFor(uint256 strikeVar, uint256 notional) public pure returns (uint256 longColl, uint256 shortColl) {
        longColl = Math.mulDiv(notional, strikeVar, WAD, Math.Rounding.Ceil);
        shortColl = Math.mulDiv(notional, capVariance(strikeVar) - strikeVar, WAD, Math.Rounding.Ceil);
    }

    function getSwap(uint256 id) external view returns (Swap memory) {
        return _swaps[id];
    }

    // ------------------------------------------------------------------ lifecycle

    /// @param strikeVol strike in vol points (18 decimals), e.g. 20e18
    /// @param notional  collateral token units paid per variance point of (RV - K)
    function createOffer(bool makerIsLong, uint256 strikeVol, uint256 notional, uint256 tenor, uint256 offerDeadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 id)
    {
        _checkAllowed(msg.sender);
        if (strikeVol < 1e18 || strikeVol > 500e18 || notional == 0) revert BadParams();
        if (tenor < MIN_TENOR || tenor > MAX_TENOR || offerDeadline <= block.timestamp) revert BadParams();
        uint256 strikeVar = (strikeVol * strikeVol) / WAD;
        (uint256 longColl, uint256 shortColl) = collateralFor(strikeVar, notional);
        id = nextSwapId++;
        _swaps[id] = Swap({
            maker: msg.sender,
            taker: address(0),
            makerIsLong: makerIsLong,
            status: Status.Open,
            tenor: uint64(tenor),
            offerDeadline: uint64(offerDeadline),
            start: 0,
            end: 0,
            strikeVar: strikeVar,
            notional: notional,
            longCollateral: longColl,
            shortCollateral: shortColl,
            realizedVar: 0
        });
        uint256 deposit = makerIsLong ? longColl : shortColl;
        totalEscrowed += deposit;
        emit OfferCreated(id, msg.sender, makerIsLong, strikeVol, notional, tenor);
        token.safeTransferFrom(msg.sender, address(this), deposit);
    }

    function cancelOffer(uint256 id) external nonReentrant {
        Swap storage s = _swaps[id];
        if (s.status != Status.Open) revert WrongStatus();
        if (s.maker != msg.sender) revert NotMaker();
        s.status = Status.Cancelled;
        uint256 back = s.makerIsLong ? s.longCollateral : s.shortCollateral;
        _credit(s.maker, back);
        emit OfferCancelled(id);
    }

    function takeOffer(uint256 id) external whenNotPaused nonReentrant {
        _checkAllowed(msg.sender);
        Swap storage s = _swaps[id];
        if (s.status != Status.Open) revert WrongStatus();
        if (block.timestamp > s.offerDeadline) revert OfferExpired();
        if (msg.sender == s.maker) revert NotAllowed();
        s.status = Status.Active;
        s.taker = msg.sender;
        s.start = uint64(block.timestamp);
        s.end = uint64(block.timestamp + s.tenor);
        uint256 deposit = s.makerIsLong ? s.shortCollateral : s.longCollateral;
        totalEscrowed += deposit;
        emit OfferTaken(id, msg.sender, s.start, s.end);
        token.safeTransferFrom(msg.sender, address(this), deposit);
    }

    /// @notice Permissionless settlement after maturity.
    /// @param startHint first QVIX round with timestamp >= start (returns after it are counted)
    /// @param endHint   last QVIX round with timestamp <= end
    function settle(uint256 id, uint256 startHint, uint256 endHint) external whenNotPaused nonReentrant {
        Swap storage s = _swaps[id];
        if (s.status != Status.Active) revert WrongStatus();
        if (block.timestamp <= s.end) revert NotMatured();
        if (startHint == 0 || !volIndex.isLastRoundBefore(s.end, endHint)) revert BadHint();
        // startHint - 1 must be the last round strictly before start
        if (startHint > 1 && !volIndex.isLastRoundBefore(s.start - 1, startHint - 1)) revert BadHint();

        uint256 rv;
        if (endHint > startHint) {
            rv = volIndex.realizedVarianceBetween(startHint, endHint) * 1e4; // fraction -> vol points^2
        } else {
            rv = s.strikeVar; // no complete return inside the period: neutral outcome
        }
        uint256 cap = capVariance(s.strikeVar);
        if (rv > cap) rv = cap;
        s.realizedVar = rv;
        s.status = Status.Settled;

        uint256 toLong;
        uint256 toShort;
        int256 longPayoff;
        if (rv >= s.strikeVar) {
            uint256 gain = Math.mulDiv(s.notional, rv - s.strikeVar, WAD);
            if (gain > s.shortCollateral) gain = s.shortCollateral;
            toLong = s.longCollateral + gain;
            toShort = s.shortCollateral - gain;
            // forge-lint: disable-next-line(unsafe-typecast)
            longPayoff = int256(gain);
        } else {
            uint256 loss = Math.mulDiv(s.notional, s.strikeVar - rv, WAD, Math.Rounding.Ceil);
            if (loss > s.longCollateral) loss = s.longCollateral;
            toLong = s.longCollateral - loss;
            toShort = s.shortCollateral + loss;
            // forge-lint: disable-next-line(unsafe-typecast)
            longPayoff = -int256(loss);
        }
        (address longParty, address shortParty) = s.makerIsLong ? (s.maker, s.taker) : (s.taker, s.maker);
        _credit(longParty, toLong);
        _credit(shortParty, toShort);
        emit SwapSettled(id, rv, longPayoff, toLong, toShort);
    }

    /// @notice If a matured swap cannot be settled (index unavailable), anyone can refund both sides after a grace period.
    function refund(uint256 id) external nonReentrant {
        Swap storage s = _swaps[id];
        if (s.status != Status.Active) revert WrongStatus();
        if (block.timestamp <= uint256(s.end) + REFUND_GRACE) revert TooEarly();
        s.status = Status.Refunded;
        (address longParty, address shortParty) = s.makerIsLong ? (s.maker, s.taker) : (s.taker, s.maker);
        _credit(longParty, s.longCollateral);
        _credit(shortParty, s.shortCollateral);
        emit SwapRefunded(id);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) return 0;
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _credit(address user, uint256 amount) internal {
        if (amount == 0) return;
        totalEscrowed -= amount;
        claimable[user] += amount;
        totalClaimable += amount;
    }

    function _checkAllowed(address a) internal view {
        if (address(compliance) != address(0) && !compliance.isAllowed(a)) revert NotAllowed();
    }
}
