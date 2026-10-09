// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {IProjectTokenHooks} from "./interfaces/IQuake.sol";

/// @title ProjectTokenHooks
/// @notice Optional $QUAK integration. The project token is NOT deployed by this protocol; its address is set
///         exactly once through `setProjectToken` (DEFAULT_ADMIN_ROLE = Timelock). Until then every token
///         feature is disabled: staking reverts, fee discount is 0 and the FeeCollector routes the staker share
///         to LPs. Once set: stakers earn a share of trading fees (paid in the collateral stablecoin) and get a
///         trading-fee discount tier based on their active stake. Unstaking has a cooldown, during which the
///         stake neither earns nor counts for discounts (prevents stake-trade-unstake fee gaming).
contract ProjectTokenHooks is QuakeBase, IProjectTokenHooks {
    using SafeERC20 for IERC20;

    bytes32 public constant NOTIFIER_ROLE = keccak256("NOTIFIER_ROLE");
    uint256 public constant MAX_TIERS = 4;
    uint256 internal constant PRECISION = 1e36;

    IERC20 public immutable rewardToken;
    IERC20 public projectToken; // set once
    uint256 public unstakeCooldown = 7 days;

    uint256 public override totalStaked;
    uint256 public rewardPerTokenStored;
    uint256 public queuedRewards; // rewards received while nobody was staked

    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public rewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public pendingUnstake;
    mapping(address => uint256) public unstakeUnlockAt;

    // tiers: thresholds in WHOLE tokens (scaled by token decimals when read), discount bps
    uint256[] internal _tierThresholds;
    uint256[] internal _tierDiscounts;
    uint256 internal _tokenUnit; // 10**decimals of project token

    event ProjectTokenSet(address indexed token);
    event Staked(address indexed user, uint256 amount);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 unlockAt);
    event UnstakeWithdrawn(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 rewardPerToken);
    event RewardClaimed(address indexed user, uint256 amount);
    event TiersSet(uint256[] thresholds, uint256[] discounts);
    event CooldownSet(uint256 seconds_);

    error AlreadySet();
    error TokenNotSet();
    error ZeroAmount();
    error StillCoolingDown(uint256 until);
    error BadTiers();

    constructor(address admin, IERC20 rewardToken_) QuakeBase(admin) {
        if (address(rewardToken_) == address(0)) revert ZeroAddress();
        rewardToken = rewardToken_;
        _tierThresholds = [uint256(1_000), 10_000, 100_000];
        _tierDiscounts = [uint256(1_000), 2_000, 3_000];
    }

    // ------------------------------------------------------------------ admin (Timelock)

    /// @notice One-time wiring of the externally launched project token.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert AlreadySet();
        if (token == address(0) || token.code.length == 0) revert ZeroAddress();
        if (token == address(rewardToken)) revert InvalidParam();
        projectToken = IERC20(token);
        uint8 dec = 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
        } catch {}
        if (dec > 36) revert InvalidParam();
        _tokenUnit = 10 ** dec;
        emit ProjectTokenSet(token);
    }

    function setTiers(uint256[] calldata thresholds, uint256[] calldata discounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = thresholds.length;
        if (len != discounts.length || len > MAX_TIERS) revert BadTiers();
        for (uint256 i; i < len; ++i) {
            if (discounts[i] > 5_000) revert BadTiers();
            if (i > 0 && (thresholds[i] <= thresholds[i - 1] || discounts[i] < discounts[i - 1])) revert BadTiers();
        }
        _tierThresholds = thresholds;
        _tierDiscounts = discounts;
        emit TiersSet(thresholds, discounts);
    }

    function setUnstakeCooldown(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seconds_ > 30 days) revert InvalidParam();
        unstakeCooldown = seconds_;
        emit CooldownSet(seconds_);
    }

    // ------------------------------------------------------------------ staking

    function isActive() public view override returns (bool) {
        return address(projectToken) != address(0);
    }

    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (!isActive()) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before;
        stakedOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        stakedOf[msg.sender] -= amount; // reverts on underflow
        totalStaked -= amount;
        pendingUnstake[msg.sender] += amount;
        uint256 unlockAt = block.timestamp + unstakeCooldown;
        unstakeUnlockAt[msg.sender] = unlockAt;
        emit UnstakeRequested(msg.sender, amount, unlockAt);
    }

    function withdrawUnstaked() external nonReentrant {
        uint256 amount = pendingUnstake[msg.sender];
        if (amount == 0) revert ZeroAmount();
        uint256 until = unstakeUnlockAt[msg.sender];
        if (block.timestamp < until) revert StillCoolingDown(until);
        pendingUnstake[msg.sender] = 0;
        projectToken.safeTransfer(msg.sender, amount);
        emit UnstakeWithdrawn(msg.sender, amount);
    }

    function claim() external nonReentrant returns (uint256 amount) {
        _accrue(msg.sender);
        amount = rewards[msg.sender];
        if (amount > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, amount);
            emit RewardClaimed(msg.sender, amount);
        }
    }

    /// @notice Called by the FeeCollector after transferring `amount` reward tokens here.
    function notifyReward(uint256 amount) external override onlyRole(NOTIFIER_ROLE) {
        uint256 total = amount + queuedRewards;
        if (totalStaked == 0) {
            queuedRewards = total;
            emit RewardNotified(amount, rewardPerTokenStored);
            return;
        }
        queuedRewards = 0;
        rewardPerTokenStored += (total * PRECISION) / totalStaked;
        emit RewardNotified(amount, rewardPerTokenStored);
    }

    function earned(address user) public view returns (uint256) {
        return rewards[user] + (stakedOf[user] * (rewardPerTokenStored - rewardPerTokenPaid[user])) / PRECISION;
    }

    function _accrue(address user) internal {
        rewards[user] = earned(user);
        rewardPerTokenPaid[user] = rewardPerTokenStored;
    }

    // ------------------------------------------------------------------ discounts

    function feeDiscountBps(address account) external view override returns (uint256 discount) {
        if (!isActive()) return 0;
        uint256 s = stakedOf[account];
        uint256 len = _tierThresholds.length;
        for (uint256 i; i < len; ++i) {
            if (s >= _tierThresholds[i] * _tokenUnit) discount = _tierDiscounts[i];
        }
    }

    function tiers() external view returns (uint256[] memory thresholds, uint256[] memory discounts) {
        return (_tierThresholds, _tierDiscounts);
    }
}
