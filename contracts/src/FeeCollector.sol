// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuakeBase} from "./base/QuakeBase.sol";
import {IFeeCollector, IProjectTokenHooks} from "./interfaces/IQuake.sol";

/// @title FeeCollector
/// @notice Receives trading fees and splits them (permissionless `distribute`) between the LP vault, the
///         insurance fund, $QUAK stakers (only when the project token is set and someone is staked; otherwise
///         that share goes to LPs) and the treasury. Also the single source of trading-fee discounts.
contract FeeCollector is QuakeBase, IFeeCollector {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    IERC20 public immutable token;
    address public vault;
    address public insurance;
    address public treasury;
    IProjectTokenHooks public hooks;

    uint256 public lpBps = 5_000;
    uint256 public insuranceBps = 2_000;
    uint256 public stakerBps = 2_000;
    uint256 public treasuryBps = 1_000;

    event Distributed(uint256 toLp, uint256 toInsurance, uint256 toStakers, uint256 toTreasury);
    event SplitSet(uint256 lpBps, uint256 insuranceBps, uint256 stakerBps, uint256 treasuryBps);
    event RecipientsSet(address vault, address insurance, address treasury, address hooks);

    constructor(address admin, IERC20 token_, address vault_, address insurance_, address treasury_, IProjectTokenHooks hooks_)
        QuakeBase(admin)
    {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        _setRecipients(vault_, insurance_, treasury_, hooks_);
    }

    function setRecipients(address vault_, address insurance_, address treasury_, IProjectTokenHooks hooks_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setRecipients(vault_, insurance_, treasury_, hooks_);
    }

    function _setRecipients(address vault_, address insurance_, address treasury_, IProjectTokenHooks hooks_) internal {
        if (vault_ == address(0) || insurance_ == address(0) || treasury_ == address(0) || address(hooks_) == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        insurance = insurance_;
        treasury = treasury_;
        hooks = hooks_;
        emit RecipientsSet(vault_, insurance_, treasury_, address(hooks_));
    }

    function setSplit(uint256 lp, uint256 ins, uint256 stakers, uint256 treas) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (lp + ins + stakers + treas != BPS) revert InvalidParam();
        lpBps = lp;
        insuranceBps = ins;
        stakerBps = stakers;
        treasuryBps = treas;
        emit SplitSet(lp, ins, stakers, treas);
    }

    /// @notice Splits the whole current balance. Anyone can call.
    function distribute() external whenNotPaused nonReentrant {
        uint256 bal = token.balanceOf(address(this));
        uint256 toIns = (bal * insuranceBps) / BPS;
        uint256 toTreasury = (bal * treasuryBps) / BPS;
        uint256 toStakers = 0;
        if (hooks.isActive() && hooks.totalStaked() != 0) toStakers = (bal * stakerBps) / BPS;
        uint256 toLp = bal - toIns - toTreasury - toStakers;

        if (toLp != 0) token.safeTransfer(vault, toLp);
        if (toIns != 0) token.safeTransfer(insurance, toIns);
        if (toTreasury != 0) token.safeTransfer(treasury, toTreasury);
        if (toStakers != 0) {
            token.safeTransfer(address(hooks), toStakers);
            hooks.notifyReward(toStakers);
        }
        emit Distributed(toLp, toIns, toStakers, toTreasury);
    }

    /// @inheritdoc IFeeCollector
    function feeDiscountBps(address account) external view override returns (uint256) {
        if (!hooks.isActive()) return 0;
        try hooks.feeDiscountBps(account) returns (uint256 d) {
            return d > BPS ? BPS : d;
        } catch {
            return 0;
        }
    }
}
