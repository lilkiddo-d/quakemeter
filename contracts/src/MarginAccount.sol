// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {ICompliance, IMarginAccount, ILPVault, IInsuranceFund} from "./interfaces/IQuake.sol";

/// @title MarginAccount
/// @notice Custodies all trader collateral (stablecoin). Users hold a free balance; registered markets lock
///         part of it as isolated margin per position. Markets realize PnL through this contract:
///         losses/fees are paid out of locked margin, profits are pulled from the LP vault (then the insurance
///         fund if the vault is short). Invariant: token balance >= sum(free) + sum(locked).
contract MarginAccount is QuakeBase, IMarginAccount {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_MARKETS = 16;

    IERC20 public immutable collateralToken;
    ILPVault public vault;
    IInsuranceFund public insurance;
    ICompliance public compliance;

    mapping(address user => uint256) public freeBalance;
    mapping(address market => uint256) public lockedByMarket;
    uint256 public totalFree;
    uint256 public totalLocked;

    address[] internal _markets;
    mapping(address => bool) public override isMarket;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Locked(address indexed market, address indexed user, uint256 amount);
    event Unlocked(address indexed market, address indexed user, uint256 amount);
    event PaidFromLocked(address indexed market, address indexed to, uint256 amount);
    event ProfitPulled(address indexed market, uint256 requested, uint256 paid);
    event BadDebtCovered(address indexed market, uint256 requested, uint256 paid);
    event MarketAdded(address indexed market);
    event MarketRemoved(address indexed market);
    event VaultSet(address indexed vault);
    event InsuranceSet(address indexed insurance);
    event ComplianceSet(address indexed compliance);

    error NotMarket();
    error NotAllowed();
    error InsufficientBalance();
    error ZeroAmount();
    error TooManyMarkets();
    error MarketExists();
    error MarketHasMargin();

    modifier onlyMarket() {
        if (!isMarket[msg.sender]) revert NotMarket();
        _;
    }

    constructor(address admin, IERC20 collateral_) QuakeBase(admin) {
        if (address(collateral_) == address(0)) revert ZeroAddress();
        collateralToken = collateral_;
    }

    // ------------------------------------------------------------------ admin

    function setVault(ILPVault vault_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(address(vault_));
    }

    function setInsurance(IInsuranceFund insurance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(insurance_) == address(0)) revert ZeroAddress();
        insurance = insurance_;
        emit InsuranceSet(address(insurance_));
    }

    function setCompliance(ICompliance compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = compliance_;
        emit ComplianceSet(address(compliance_));
    }

    function addMarket(address market) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (market == address(0)) revert ZeroAddress();
        if (isMarket[market]) revert MarketExists();
        if (_markets.length >= MAX_MARKETS) revert TooManyMarkets();
        isMarket[market] = true;
        _markets.push(market);
        emit MarketAdded(market);
    }

    /// @notice Removes a fully settled market (no margin left locked) to free a slot.
    function removeMarket(address market) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!isMarket[market]) revert NotMarket();
        if (lockedByMarket[market] != 0) revert MarketHasMargin();
        isMarket[market] = false;
        uint256 len = _markets.length;
        for (uint256 i; i < len; ++i) {
            if (_markets[i] == market) {
                _markets[i] = _markets[len - 1];
                _markets.pop();
                break;
            }
        }
        emit MarketRemoved(market);
    }

    // ------------------------------------------------------------------ users

    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (address(compliance) != address(0) && !compliance.isAllowed(msg.sender)) revert NotAllowed();
        uint256 before = collateralToken.balanceOf(address(this));
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateralToken.balanceOf(address(this)) - before;
        freeBalance[msg.sender] += received;
        totalFree += received;
        emit Deposited(msg.sender, received);
    }

    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = freeBalance[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        freeBalance[msg.sender] = bal - amount;
        totalFree -= amount;
        collateralToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ------------------------------------------------------------------ markets

    function lock(address user, uint256 amount) external override onlyMarket {
        uint256 bal = freeBalance[user];
        if (bal < amount) revert InsufficientBalance();
        freeBalance[user] = bal - amount;
        totalFree -= amount;
        lockedByMarket[msg.sender] += amount;
        totalLocked += amount;
        emit Locked(msg.sender, user, amount);
    }

    function unlock(address user, uint256 amount) external override onlyMarket {
        _reduceLocked(amount);
        freeBalance[user] += amount;
        totalFree += amount;
        emit Unlocked(msg.sender, user, amount);
    }

    /// @notice Pays `amount` of the market's locked margin to `to` (vault, fee collector, insurance, liquidator).
    function payFromLocked(address to, uint256 amount) external override onlyMarket nonReentrant {
        if (amount == 0) return;
        _reduceLocked(amount);
        collateralToken.safeTransfer(to, amount);
        emit PaidFromLocked(msg.sender, to, amount);
    }

    /// @notice Pulls realized trader profit from the vault (then the insurance fund) into the market's locked pool.
    function pullProfit(uint256 amount) external override onlyMarket nonReentrant returns (uint256 paid) {
        if (amount == 0) return 0;
        paid = _pull(address(vault), amount);
        if (paid < amount && address(insurance) != address(0)) {
            paid += _pullInsurance(amount - paid);
        }
        lockedByMarket[msg.sender] += paid;
        totalLocked += paid;
        emit ProfitPulled(msg.sender, amount, paid);
    }

    /// @notice Bad debt (a position lost more than its margin): the insurance fund reimburses the vault.
    function coverBadDebt(uint256 amount) external override onlyMarket nonReentrant returns (uint256 paid) {
        if (amount == 0 || address(insurance) == address(0)) return 0;
        paid = insurance.cover(address(vault), amount);
        emit BadDebtCovered(msg.sender, amount, paid);
    }

    function _pull(address from, uint256 amount) internal returns (uint256 received) {
        uint256 before = collateralToken.balanceOf(address(this));
        uint256 reported = ILPVault(from).payProfit(amount);
        received = collateralToken.balanceOf(address(this)) - before;
        if (received > reported) received = reported;
    }

    function _pullInsurance(uint256 amount) internal returns (uint256 received) {
        uint256 before = collateralToken.balanceOf(address(this));
        uint256 reported = insurance.cover(address(this), amount);
        received = collateralToken.balanceOf(address(this)) - before;
        if (received > reported) received = reported;
    }

    function _reduceLocked(uint256 amount) internal {
        uint256 l = lockedByMarket[msg.sender];
        if (l < amount) revert InsufficientBalance();
        lockedByMarket[msg.sender] = l - amount;
        totalLocked -= amount;
    }

    // ------------------------------------------------------------------ views

    /// @notice Maximum trader profit that can currently be paid: vault balance plus insurance fund balance.
    function profitCapacity() external view override returns (uint256 cap) {
        if (address(vault) != address(0)) cap = collateralToken.balanceOf(address(vault));
        if (address(insurance) != address(0)) cap += collateralToken.balanceOf(address(insurance));
    }

    function collateral() external view override returns (address) {
        return address(collateralToken);
    }

    function marketCount() external view override returns (uint256) {
        return _markets.length;
    }

    function marketAt(uint256 i) external view override returns (address) {
        return _markets[i];
    }

    function markets() external view returns (address[] memory) {
        return _markets;
    }
}
