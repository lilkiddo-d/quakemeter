// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20, IERC20Metadata, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {ICompliance, IMarginAccount, IFuturesMarketView, ILPVault} from "./interfaces/IQuake.sol";

/// @title LPVault
/// @notice ERC-4626 vault of stablecoin that is the counterparty to all QVIX futures. LPs earn trader losses,
///         their share of trading fees and funding; they pay trader profits. Share price marks open trader
///         profits as a liability (conservative: open trader losses are not counted until realized).
///         Withdrawals are capped by the reserve each market requires against open interest, and fresh
///         deposits are locked for `depositLock` to stop just-in-time LPing around fee drops or settlements.
contract LPVault is ERC4626, QuakeBase, ILPVault {
    using SafeERC20 for IERC20;

    IMarginAccount public immutable marginAccount;
    ICompliance public compliance;
    uint256 public depositLock = 1 days;
    uint256 internal immutable _scale; // 10**(18 - assetDecimals)

    mapping(address => uint256) public lastDepositAt;

    event ProfitPaid(uint256 requested, uint256 paid);
    event ComplianceSet(address indexed compliance);
    event DepositLockSet(uint256 seconds_);

    error OnlyMarginAccount();
    error NotAllowed();
    error Locked(uint256 until);

    constructor(address admin, IERC20 asset_, IMarginAccount marginAccount_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        QuakeBase(admin)
    {
        if (address(marginAccount_) == address(0)) revert ZeroAddress();
        marginAccount = marginAccount_;
        uint8 dec = IERC20Metadata(address(asset_)).decimals();
        if (dec > 18) revert InvalidParam();
        _scale = 10 ** (18 - dec);
    }

    // ------------------------------------------------------------------ admin

    function setCompliance(ICompliance compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = compliance_;
        emit ComplianceSet(address(compliance_));
    }

    function setDepositLock(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seconds_ > 30 days) revert InvalidParam();
        depositLock = seconds_;
        emit DepositLockSet(seconds_);
    }

    // ------------------------------------------------------------------ counterparty

    /// @inheritdoc ILPVault
    function payProfit(uint256 amount) external override nonReentrant returns (uint256 paid) {
        if (msg.sender != address(marginAccount)) revert OnlyMarginAccount();
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        paid = amount > bal ? bal : amount;
        if (paid != 0) IERC20(asset()).safeTransfer(msg.sender, paid);
        emit ProfitPaid(amount, paid);
    }

    // ------------------------------------------------------------------ accounting

    /// @notice Open trader profit across all markets, in asset units (rounded up).
    function traderLiabilities() public view returns (uint256 liab) {
        uint256 n = marginAccount.marketCount(); // bounded by MarginAccount.MAX_MARKETS
        int256 total = 0;
        for (uint256 i; i < n; ++i) {
            int256 pnl = IFuturesMarketView(marginAccount.marketAt(i)).aggregateTraderPnl();
            if (pnl > 0) total += pnl;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        liab = Math.ceilDiv(uint256(total), _scale);
    }

    /// @notice Assets the vault must keep against open interest, in asset units.
    function requiredReserve() public view returns (uint256 reserve) {
        uint256 n = marginAccount.marketCount();
        uint256 total = 0;
        for (uint256 i; i < n; ++i) {
            total += IFuturesMarketView(marginAccount.marketAt(i)).requiredReserve();
        }
        reserve = Math.ceilDiv(total, _scale);
    }

    function totalAssets() public view override(ERC4626, ILPVault) returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 liab = traderLiabilities();
        return bal > liab ? bal - liab : 0;
    }

    /// @notice Assets that can leave the vault now without breaching reserves.
    function freeLiquidity() public view returns (uint256) {
        uint256 ta = totalAssets();
        uint256 res = requiredReserve();
        return ta > res ? ta - res : 0;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused() || !_allowed(receiver)) return 0;
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (paused() || !_allowed(receiver)) return 0;
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused() || block.timestamp < lastDepositAt[owner] + depositLock) return 0;
        uint256 own = super.maxWithdraw(owner);
        uint256 free = freeLiquidity();
        return own < free ? own : free;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused() || block.timestamp < lastDepositAt[owner] + depositLock) return 0;
        uint256 own = super.maxRedeem(owner);
        uint256 freeShares = _convertToShares(freeLiquidity(), Math.Rounding.Floor);
        return own < freeShares ? own : freeShares;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        // third-party deposits would let anyone reset someone else's lock (griefing)
        if (caller != receiver) revert NotAllowed();
        lastDepositAt[receiver] = block.timestamp;
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        uint256 until = lastDepositAt[owner] + depositLock;
        if (block.timestamp < until) revert Locked(until);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Freshly deposited shares cannot be transferred until the lock expires, so the lock cannot be
    ///      bypassed (and nobody can grief a recipient by pushing a lock onto them).
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 until = lastDepositAt[from] + depositLock;
            if (block.timestamp < until) revert Locked(until);
        }
        super._update(from, to, value);
    }

    function _allowed(address a) internal view returns (bool) {
        return address(compliance) == address(0) || compliance.isAllowed(a);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function decimals() public view override(ERC4626) returns (uint8) {
        return super.decimals();
    }
}
