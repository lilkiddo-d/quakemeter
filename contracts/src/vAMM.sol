// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VAMM
/// @notice Virtual constant-product AMM (x * y = k) pricing one QVIX futures expiry. No tokens are held:
///         reserves are virtual. Base = contracts ($1 per vol point), quote = USD, both 18 decimals.
///         Keeps an exponential moving average of the mark used for margin / liquidation checks so a single
///         block cannot be used to push the margin price. Only the owning FuturesMarket can trade.
///         Liquidations bypass the per-trade impact limit (they must always be executable) but not the bounds.
contract VAMM {
    uint256 internal constant WAD = 1e18;

    address public immutable market;
    uint256 public immutable emaWindow; // seconds
    uint256 public immutable maxImpactBps; // max mark move per trade
    uint256 public immutable minPrice;
    uint256 public immutable maxPrice;

    uint256 public baseReserve;
    uint256 public quoteReserve;
    uint256 public emaMark;
    uint256 public lastEmaUpdate;

    event Initialized(uint256 price, uint256 baseReserve, uint256 quoteReserve);
    event Swapped(int256 baseDelta, int256 quoteDelta, uint256 markAfter, uint256 emaMark);

    error OnlyMarket();
    error AlreadyInitialized();
    error NotInitialized();
    error InsufficientLiquidity();
    error PriceImpactTooHigh();
    error PriceOutOfBounds();
    error BadParam();

    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    constructor(address market_, uint256 emaWindow_, uint256 maxImpactBps_, uint256 minPrice_, uint256 maxPrice_) {
        if (market_ == address(0) || emaWindow_ == 0 || maxImpactBps_ == 0 || maxImpactBps_ > 5000) revert BadParam();
        if (minPrice_ == 0 || maxPrice_ <= minPrice_) revert BadParam();
        market = market_;
        emaWindow = emaWindow_;
        maxImpactBps = maxImpactBps_;
        minPrice = minPrice_;
        maxPrice = maxPrice_;
    }

    function initialize(uint256 price, uint256 baseDepth) external onlyMarket {
        if (baseReserve != 0) revert AlreadyInitialized();
        if (price < minPrice || price > maxPrice || baseDepth < WAD) revert BadParam();
        baseReserve = baseDepth;
        quoteReserve = Math.mulDiv(baseDepth, price, WAD);
        emaMark = price;
        lastEmaUpdate = block.timestamp;
        emit Initialized(price, baseReserve, quoteReserve);
    }

    function initialized() public view returns (bool) {
        return baseReserve != 0;
    }

    function markPrice() public view returns (uint256) {
        if (baseReserve == 0) return 0;
        return Math.mulDiv(quoteReserve, WAD, baseReserve);
    }

    /// @notice EMA mark including the decay up to now (view).
    function currentEma() public view returns (uint256) {
        if (baseReserve == 0) return 0;
        uint256 dt = block.timestamp - lastEmaUpdate;
        uint256 spot = markPrice();
        if (dt >= emaWindow) return spot;
        uint256 e = emaMark;
        return spot >= e ? e + ((spot - e) * dt) / emaWindow : e - ((e - spot) * dt) / emaWindow;
    }

    /// @notice Quote for a trade without executing it. Positive baseDelta = buy (long).
    /// @return quoteDelta positive = trader pays quote, negative = trader receives quote
    function quote(int256 baseDelta) public view returns (int256 quoteDelta) {
        (quoteDelta,,) = _compute(baseDelta);
    }

    function swap(int256 baseDelta, bool enforceImpact) external onlyMarket returns (int256 quoteDelta) {
        if (baseReserve == 0) revert NotInitialized();
        uint256 before = markPrice();
        emaMark = currentEma();
        lastEmaUpdate = block.timestamp;

        uint256 newBase;
        uint256 newQuote;
        (quoteDelta, newBase, newQuote) = _compute(baseDelta);
        baseReserve = newBase;
        quoteReserve = newQuote;

        uint256 afterPx = markPrice();
        if (afterPx < minPrice || afterPx > maxPrice) revert PriceOutOfBounds();
        uint256 moved = afterPx > before ? afterPx - before : before - afterPx;
        if (enforceImpact && moved * 10_000 > before * maxImpactBps) revert PriceImpactTooHigh();
        emit Swapped(baseDelta, quoteDelta, afterPx, emaMark);
    }

    function _compute(int256 baseDelta) internal view returns (int256 quoteDelta, uint256 newBase, uint256 newQuote) {
        uint256 b = baseReserve;
        uint256 q = quoteReserve;
        if (b == 0) revert NotInitialized();
        if (baseDelta == 0) return (0, b, q);
        uint256 k = b * q;
        if (baseDelta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 d = uint256(baseDelta);
            if (d >= b) revert InsufficientLiquidity();
            newBase = b - d;
            newQuote = Math.mulDiv(k, 1, newBase, Math.Rounding.Ceil);
            // forge-lint: disable-next-line(unsafe-typecast)
            quoteDelta = int256(newQuote - q);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 d = uint256(-baseDelta);
            newBase = b + d;
            newQuote = Math.mulDiv(k, 1, newBase, Math.Rounding.Ceil);
            // forge-lint: disable-next-line(unsafe-typecast)
            quoteDelta = -int256(q - newQuote);
        }
    }
}
