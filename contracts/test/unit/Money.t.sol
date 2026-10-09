// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../Base.t.sol";
import {MarginAccount} from "../../src/MarginAccount.sol";
import {LPVault} from "../../src/LPVault.sol";
import {InsuranceFund} from "../../src/InsuranceFund.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../../src/ComplianceRegistry.sol";
import {QuakeBase} from "../../src/base/QuakeBase.sol";
import {ICompliance, ILPVault, IInsuranceFund, IMarginAccount, IProjectTokenHooks} from "../../src/interfaces/IQuake.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MarginAccountTest is BaseTest {
    // lets this test contract act as a registered market
    function aggregateTraderPnl() external pure returns (int256) {
        return 0;
    }

    function requiredReserve() external pure returns (uint256) {
        return 0;
    }

    function test_depositWithdraw() public {
        _fund(alice, 1_000e6);
        assertEq(d.marginAccount.freeBalance(alice), 1_000e6);
        assertEq(d.marginAccount.totalFree(), 1_000e6);
        vm.startPrank(alice);
        vm.expectRevert(MarginAccount.InsufficientBalance.selector);
        d.marginAccount.withdraw(1_001e6);
        vm.expectRevert(MarginAccount.ZeroAmount.selector);
        d.marginAccount.withdraw(0);
        vm.expectRevert(MarginAccount.ZeroAmount.selector);
        d.marginAccount.deposit(0);
        d.marginAccount.withdraw(400e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(alice), 400e6);
        assertEq(d.marginAccount.collateral(), address(usd));
    }

    function test_compliance() public {
        _timelock(address(d.compliance), abi.encodeCall(ComplianceRegistry.setEnabled, (true)));
        usd.mint(alice, 10e6);
        vm.startPrank(alice);
        usd.approve(address(d.marginAccount), 10e6);
        vm.expectRevert(MarginAccount.NotAllowed.selector);
        d.marginAccount.deposit(10e6);
        vm.stopPrank();
    }

    function test_onlyMarket() public {
        vm.expectRevert(MarginAccount.NotMarket.selector);
        d.marginAccount.lock(alice, 1);
        vm.expectRevert(MarginAccount.NotMarket.selector);
        d.marginAccount.unlock(alice, 1);
        vm.expectRevert(MarginAccount.NotMarket.selector);
        d.marginAccount.payFromLocked(alice, 1);
        vm.expectRevert(MarginAccount.NotMarket.selector);
        d.marginAccount.pullProfit(1);
        vm.expectRevert(MarginAccount.NotMarket.selector);
        d.marginAccount.coverBadDebt(1);
    }

    function test_marketRegistry() public {
        vm.startPrank(address(d.timelock));
        vm.expectRevert(MarginAccount.MarketExists.selector);
        d.marginAccount.addMarket(address(m0));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.marginAccount.addMarket(address(0));
        for (uint256 i = 3; i < 16; ++i) {
            d.marginAccount.addMarket(address(uint160(0x5000 + i)));
        }
        vm.expectRevert(MarginAccount.TooManyMarkets.selector);
        d.marginAccount.addMarket(address(0x9999));
        d.marginAccount.removeMarket(address(uint160(0x5003)));
        vm.expectRevert(MarginAccount.NotMarket.selector);
        d.marginAccount.removeMarket(address(uint160(0x5003)));
        vm.stopPrank();
        assertEq(d.marginAccount.marketCount(), 15);
        assertEq(d.marginAccount.markets().length, 15);
    }

    function test_removeMarketWithMarginReverts() public {
        // act as a registered market
        vm.prank(address(d.timelock));
        d.marginAccount.addMarket(address(this));
        _fund(alice, 100e6);
        d.marginAccount.lock(alice, 50e6);
        vm.prank(address(d.timelock));
        vm.expectRevert(MarginAccount.MarketHasMargin.selector);
        d.marginAccount.removeMarket(address(this));
        vm.expectRevert(MarginAccount.InsufficientBalance.selector);
        d.marginAccount.lock(alice, 51e6);
        vm.expectRevert(MarginAccount.InsufficientBalance.selector);
        d.marginAccount.unlock(alice, 51e6);
        d.marginAccount.payFromLocked(bob, 0);
        assertEq(d.marginAccount.pullProfit(0), 0);
        assertEq(d.marginAccount.coverBadDebt(0), 0);
    }

    function test_pullProfit_fallsBackToInsurance() public {
        vm.prank(address(d.timelock));
        d.marginAccount.addMarket(address(this));
        _seedVault(100e6);
        usd.mint(address(d.insurance), 50e6);
        uint256 paid = d.marginAccount.pullProfit(130e6);
        assertEq(paid, 130e6);
        assertEq(usd.balanceOf(address(d.vault)), 0);
        assertEq(usd.balanceOf(address(d.insurance)), 20e6);
        assertEq(d.marginAccount.lockedByMarket(address(this)), 130e6);
        // both empty -> partial
        paid = d.marginAccount.pullProfit(100e6);
        assertEq(paid, 20e6);
    }

    function test_setters() public {
        vm.startPrank(address(d.timelock));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.marginAccount.setVault(ILPVault(address(0)));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.marginAccount.setInsurance(IInsuranceFund(address(0)));
        d.marginAccount.setCompliance(ICompliance(address(0)));
        vm.stopPrank();
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new MarginAccount(address(this), IERC20(address(0)));
    }

    function test_coverBadDebt_noInsurance() public {
        MarginAccount ma = new MarginAccount(address(this), IERC20(address(usd)));
        ma.addMarket(address(this));
        assertEq(ma.coverBadDebt(10), 0);
        assertEq(ma.pullProfit(0), 0);
    }
}

contract LPVaultTest is BaseTest {
    function test_depositLockAndWithdraw() public {
        _seedVault(10_000e6);
        assertEq(d.vault.totalAssets(), 10_000e6);
        assertEq(d.vault.balanceOf(lp), 10_000e6 * 1e6);
        assertEq(d.vault.maxWithdraw(lp), 0);
        vm.startPrank(lp);
        vm.expectRevert();
        d.vault.withdraw(1e6, lp, lp);
        vm.expectRevert();
        d.vault.transfer(bob, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 days);
        assertEq(d.vault.maxWithdraw(lp), 10_000e6);
        assertGt(d.vault.maxRedeem(lp), 0);
        vm.startPrank(lp);
        d.vault.transfer(bob, 1);
        d.vault.withdraw(4_000e6, lp, lp);
        vm.stopPrank();
        assertEq(usd.balanceOf(lp), 4_000e6);
        assertEq(d.vault.decimals(), 12);
    }

    function test_thirdPartyDepositBlocked() public {
        usd.mint(alice, 10e6);
        vm.startPrank(alice);
        usd.approve(address(d.vault), 10e6);
        vm.expectRevert(LPVault.NotAllowed.selector);
        d.vault.deposit(10e6, bob);
        vm.stopPrank();
    }

    function test_mintAndRedeem() public {
        usd.mint(alice, 100e6);
        vm.startPrank(alice);
        usd.approve(address(d.vault), 100e6);
        d.vault.mint(50e12, alice);
        vm.warp(block.timestamp + 1 days);
        d.vault.redeem(d.vault.maxRedeem(alice), alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(usd.balanceOf(alice), 100e6, 1);
    }

    function test_feesRaiseSharePrice() public {
        _seedVault(10_000e6);
        uint256 before = d.vault.convertToAssets(1e12);
        usd.mint(address(d.vault), 1_000e6);
        assertGt(d.vault.convertToAssets(1e12), before);
    }

    function test_payProfit_onlyMarginAccount() public {
        vm.expectRevert(LPVault.OnlyMarginAccount.selector);
        d.vault.payProfit(1);
    }

    function test_complianceAndPause() public {
        _timelock(address(d.compliance), abi.encodeCall(ComplianceRegistry.setEnabled, (true)));
        assertEq(d.vault.maxDeposit(alice), 0);
        assertEq(d.vault.maxMint(alice), 0);
        vm.prank(guardian);
        d.vault.pause();
        assertEq(d.vault.maxWithdraw(lp), 0);
        assertEq(d.vault.maxRedeem(lp), 0);
    }

    function test_admin() public {
        vm.startPrank(address(d.timelock));
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        d.vault.setDepositLock(31 days);
        d.vault.setDepositLock(0);
        d.vault.setCompliance(ICompliance(address(0)));
        vm.stopPrank();
        assertEq(d.vault.depositLock(), 0);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new LPVault(address(this), IERC20(address(usd)), IMarginAccount(address(0)), "x", "x");
        MockERC20 weird = new MockERC20("w", "w", 19);
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        new LPVault(address(this), IERC20(address(weird)), IMarginAccount(address(d.marginAccount)), "x", "x");
    }
}

contract FeesAndTokenTest is BaseTest {
    MockERC20 quak;

    function setUp() public override {
        super.setUp();
        quak = new MockERC20("Mock QUAK", "mQUAK", 18);
    }

    function _setToken() internal {
        _timelock(address(d.tokenHooks), abi.encodeCall(ProjectTokenHooks.setProjectToken, (address(quak))));
    }

    function test_distribute_withoutToken_goesToLps() public {
        usd.mint(address(d.feeCollector), 1_000e6);
        d.feeCollector.distribute();
        assertEq(usd.balanceOf(address(d.vault)), 700e6); // 50% + 20% staker share
        assertEq(usd.balanceOf(address(d.insurance)), 200e6);
        assertEq(usd.balanceOf(treasury), 100e6);
        d.feeCollector.distribute(); // empty: no-op
        assertEq(d.feeCollector.feeDiscountBps(alice), 0);
    }

    function test_tokenDisabledUntilSet() public {
        assertFalse(d.tokenHooks.isActive());
        assertEq(d.tokenHooks.feeDiscountBps(alice), 0);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        d.tokenHooks.stake(1);
        vm.expectRevert();
        d.tokenHooks.setProjectToken(address(quak)); // not via timelock
    }

    function test_setProjectToken_once() public {
        vm.startPrank(address(d.timelock));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.tokenHooks.setProjectToken(address(0));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.tokenHooks.setProjectToken(alice); // EOA
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        d.tokenHooks.setProjectToken(address(usd));
        d.tokenHooks.setProjectToken(address(quak));
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        d.tokenHooks.setProjectToken(address(quak));
        vm.stopPrank();
        assertTrue(d.tokenHooks.isActive());
    }

    function test_stakingRewardsAndDiscount() public {
        _setToken();
        quak.mint(alice, 20_000e18);
        quak.mint(bob, 1_000e18);
        vm.startPrank(alice);
        quak.approve(address(d.tokenHooks), type(uint256).max);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.tokenHooks.stake(0);
        d.tokenHooks.stake(10_000e18);
        vm.stopPrank();
        vm.startPrank(bob);
        quak.approve(address(d.tokenHooks), type(uint256).max);
        d.tokenHooks.stake(1_000e18);
        vm.stopPrank();
        assertEq(d.tokenHooks.feeDiscountBps(alice), 2_000);
        assertEq(d.tokenHooks.feeDiscountBps(bob), 1_000);
        assertEq(d.tokenHooks.feeDiscountBps(carol), 0);
        assertEq(d.feeCollector.feeDiscountBps(alice), 2_000);

        usd.mint(address(d.feeCollector), 1_100e6);
        d.feeCollector.distribute();
        assertEq(usd.balanceOf(address(d.tokenHooks)), 220e6);
        assertApproxEqAbs(d.tokenHooks.earned(alice), 200e6, 1);
        assertApproxEqAbs(d.tokenHooks.earned(bob), 20e6, 1);
        vm.prank(alice);
        uint256 got = d.tokenHooks.claim();
        assertApproxEqAbs(got, 200e6, 1);
        vm.prank(alice);
        assertEq(d.tokenHooks.claim(), 0);

        // unstake: stops counting immediately, withdraw after cooldown
        vm.startPrank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.tokenHooks.requestUnstake(0);
        d.tokenHooks.requestUnstake(10_000e18);
        assertEq(d.tokenHooks.feeDiscountBps(alice), 0);
        vm.expectRevert();
        d.tokenHooks.withdrawUnstaked();
        vm.warp(block.timestamp + 7 days);
        d.tokenHooks.withdrawUnstaked();
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.tokenHooks.withdrawUnstaked();
        vm.stopPrank();
        assertEq(quak.balanceOf(alice), 20_000e18);
    }

    function test_queuedRewardsWhenNobodyStaked() public {
        _setToken();
        vm.prank(address(d.feeCollector));
        d.tokenHooks.notifyReward(0);
        usd.mint(address(d.tokenHooks), 50e6);
        vm.prank(address(d.feeCollector));
        d.tokenHooks.notifyReward(50e6);
        assertEq(d.tokenHooks.queuedRewards(), 50e6);
        quak.mint(alice, 1e18);
        vm.startPrank(alice);
        quak.approve(address(d.tokenHooks), 1e18);
        d.tokenHooks.stake(1e18);
        vm.stopPrank();
        vm.prank(address(d.feeCollector));
        d.tokenHooks.notifyReward(0);
        assertApproxEqAbs(d.tokenHooks.earned(alice), 50e6, 1);
        vm.expectRevert();
        d.tokenHooks.notifyReward(1);
    }

    function test_tiersAndCooldownAdmin() public {
        uint256[] memory t = new uint256[](2);
        uint256[] memory dsc = new uint256[](2);
        t[0] = 10;
        t[1] = 5;
        dsc[0] = 100;
        dsc[1] = 200;
        vm.startPrank(address(d.timelock));
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        d.tokenHooks.setTiers(t, dsc);
        t[1] = 50;
        dsc[1] = 6_000;
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        d.tokenHooks.setTiers(t, dsc);
        dsc[1] = 300;
        d.tokenHooks.setTiers(t, dsc);
        uint256[] memory one = new uint256[](1);
        vm.expectRevert(ProjectTokenHooks.BadTiers.selector);
        d.tokenHooks.setTiers(one, dsc);
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        d.tokenHooks.setUnstakeCooldown(31 days);
        d.tokenHooks.setUnstakeCooldown(1 days);
        vm.stopPrank();
        (uint256[] memory tt,) = d.tokenHooks.tiers();
        assertEq(tt[1], 50);
        assertEq(d.tokenHooks.unstakeCooldown(), 1 days);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new ProjectTokenHooks(address(this), IERC20(address(0)));
    }

    function test_feeCollectorAdmin() public {
        vm.startPrank(address(d.timelock));
        vm.expectRevert(QuakeBase.InvalidParam.selector);
        d.feeCollector.setSplit(5000, 5000, 1, 0);
        d.feeCollector.setSplit(10_000, 0, 0, 0);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.feeCollector.setRecipients(address(0), alice, alice, IProjectTokenHooks(address(d.tokenHooks)));
        d.feeCollector.setRecipients(alice, alice, alice, IProjectTokenHooks(address(d.tokenHooks)));
        vm.stopPrank();
        usd.mint(address(d.feeCollector), 10e6);
        d.feeCollector.distribute();
        assertEq(usd.balanceOf(alice), 10e6);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new FeeCollector(address(this), IERC20(address(0)), alice, alice, alice, IProjectTokenHooks(address(d.tokenHooks)));
    }

    function test_discountClampAndFailure() public {
        BadHooks bad = new BadHooks();
        vm.prank(address(d.timelock));
        d.feeCollector.setRecipients(alice, alice, alice, IProjectTokenHooks(address(bad)));
        bad.setMode(1);
        assertEq(d.feeCollector.feeDiscountBps(alice), 10_000);
        bad.setMode(2);
        assertEq(d.feeCollector.feeDiscountBps(alice), 0);
    }

    function test_insurance() public {
        usd.mint(address(d.insurance), 100e6);
        assertEq(d.insurance.balance(), 100e6);
        vm.expectRevert();
        d.insurance.cover(alice, 1);
        vm.startPrank(address(d.marginAccount));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.insurance.cover(address(0), 1);
        assertEq(d.insurance.cover(alice, 150e6), 100e6);
        vm.stopPrank();
        usd.mint(address(d.insurance), 10e6);
        vm.startPrank(address(d.timelock));
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        d.insurance.withdraw(address(0), 1);
        d.insurance.withdraw(bob, 10e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(bob), 10e6);
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new InsuranceFund(address(this), IERC20(address(0)));
    }

    function test_compliance() public {
        address[] memory big = new address[](201);
        vm.startPrank(address(d.timelock));
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        d.compliance.setAllowlisted(big, true);
        vm.stopPrank();
        assertTrue(d.compliance.isAllowed(alice));
    }

    function test_quakeBaseConstructor() public {
        vm.expectRevert(QuakeBase.ZeroAddress.selector);
        new InsuranceFund(address(0), IERC20(address(usd)));
    }
}

contract BadHooks {
    uint256 public mode;

    function setMode(uint256 m) external {
        mode = m;
    }

    function isActive() external pure returns (bool) {
        return true;
    }

    function totalStaked() external pure returns (uint256) {
        return 0;
    }

    function feeDiscountBps(address) external view returns (uint256) {
        if (mode == 2) revert("x");
        return 50_000;
    }
}
