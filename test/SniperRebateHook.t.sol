// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {SniperRebateHook} from "../src/SniperRebateHook.sol";

interface IApproveERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract SniperRebateHookTest is Test, Deployers {
    SniperRebateHook hook;
    PoolId id;
    uint256 t0;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address treasury = makeAddr("treasury");

    uint32 constant START_TAX = 2_500; // 25%
    uint32 constant PROTECTION = 6 hours;
    uint32 constant TRACK_WINDOW = 30 minutes;
    uint256 constant CLAIM_WINDOW = 30 days;
    uint256 constant PROTO_BIPS = 1_000; // must match PROTOCOL_FEE_BIPS
    address constant FAKE_WETH = address(0xBEEF);

    function setUp() public {
        deployFreshManagerAndRouters();
        currency1 = deployMintAndApproveCurrency();

        address hookAddr = address(
            uint160(
                (uint256(0x4444) << 144)
                    | uint256(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
            )
        );
        deployCodeTo(
            "src/SniperRebateHook.sol:SniperRebateHook",
            abi.encode(manager, FAKE_WETH, treasury, START_TAX, PROTECTION, TRACK_WINDOW, CLAIM_WINDOW),
            hookAddr
        );
        hook = SniperRebateHook(payable(hookAddr));

        // this test contract is tx.origin for initialize → pool creator
        vm.prank(address(this), address(this));
        (key,) = initPoolAndAddLiquidityETH(
            CurrencyLibrary.ADDRESS_ZERO, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1, 10 ether
        );
        id = key.toId();
        t0 = block.timestamp;

        // deep full-range liquidity so multi-buy scenarios don't blow through
        // the harness's default narrow position
        vm.deal(address(this), 300 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 101 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ---- helpers ------------------------------------------------------------

    function _buy(address origin, uint256 ethIn) internal returns (uint256 tokensOut) {
        uint256 before = IApproveERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        vm.prank(address(this), origin);
        swapNativeInput(key, true, -int256(ethIn), ZERO_BYTES, ethIn);
        tokensOut = IApproveERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - before;
    }

    function _sell(address origin, uint256 tokensIn) internal returns (uint256 ethReceived) {
        uint256 before = address(this).balance;
        vm.prank(address(this), origin);
        swap(key, false, -int256(tokensIn), ZERO_BYTES);
        ethReceived = address(this).balance - before;
    }

    function _potQuote() internal view returns (uint128) {
        return hook.pools(id).potQuote;
    }

    function _totalEligible() internal view returns (uint128) {
        return hook.pools(id).totalEligible;
    }

    // ---- registration & registry -------------------------------------------

    function test_pool_registered_and_active() public view {
        SniperRebateHook.PoolState memory s = hook.pools(id);
        assertEq(s.initAt, uint64(t0));
        assertFalse(s.tokenIsZero); // token is currency1, ETH is currency0
        assertTrue(s.active); // ETH-quoted pools auto-configure
        assertEq(s.creator, address(this));
        assertEq(hook.poolCount(), 1);
    }

    function test_non_eth_pool_inactive_until_configured() public {
        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        vm.prank(address(this), address(this));
        (PoolKey memory k2,) = initPool(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        PoolId id2 = k2.toId();
        assertFalse(hook.pools(id2).active);
        assertEq(hook.currentTaxBips(id2), 0);
        assertEq(hook.poolCount(), 2);

        // creator declares the token side → activates within caps
        hook.configure(id2, true, 2000, 4 hours, 20 minutes);
        SniperRebateHook.PoolState memory s2 = hook.pools(id2);
        assertTrue(s2.active);
        assertTrue(s2.tokenIsZero);
        assertEq(s2.startTaxBips, 2000);
    }

    // ---- configure gates ----------------------------------------------------

    function test_configure_only_creator() public {
        vm.prank(alice);
        vm.expectRevert(SniperRebateHook.NotCreator.selector);
        hook.configure(id, false, 1000, 3 hours, 10 minutes);
    }

    function test_configure_caps_enforced() public {
        vm.expectRevert(SniperRebateHook.BadParams.selector);
        hook.configure(id, false, 3_001, 6 hours, 30 minutes); // tax over cap
        vm.expectRevert(SniperRebateHook.BadParams.selector);
        hook.configure(id, false, 1000, 25 hours, 30 minutes); // protection over cap
        vm.expectRevert(SniperRebateHook.BadParams.selector);
        hook.configure(id, false, 1000, 1 hours, 2 hours); // window > protection
    }

    function test_configure_locked_after_trading_when_active() public {
        _buy(alice, 0.01 ether);
        vm.expectRevert(SniperRebateHook.AlreadyTrading.selector);
        hook.configure(id, false, 1000, 3 hours, 10 minutes);
    }

    function test_inactive_pool_grief_swap_keeps_grace_window() public {
        (Currency c0, Currency c1) = deployMintAndApprove2Currencies();
        vm.prank(address(this), address(this));
        (PoolKey memory k2,) = initPoolAndAddLiquidity(c0, c1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        PoolId id2 = k2.toId();

        // griefer dust-swaps immediately — pool stays configurable in grace
        vm.prank(address(this), carol);
        swap(k2, true, -1e15, ZERO_BYTES);
        hook.configure(id2, true, 2000, 4 hours, 20 minutes);
        assertTrue(hook.pools(id2).active);

        // an untraded pool stays configurable even past the grace window…
        (Currency c2, Currency c3) = deployMintAndApprove2Currencies();
        vm.prank(address(this), address(this));
        (PoolKey memory k3,) = initPool(c2, c3, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        PoolId id3 = k3.toId();
        vm.warp(block.timestamp + TRACK_WINDOW + 1);
        hook.configure(id3, false, 1000, 2 hours, 10 minutes);

        // …but a traded-and-inactive pool past the window is closed for good
        vm.prank(address(this), address(this));
        (PoolKey memory k4,) = initPoolAndAddLiquidity(c2, c3, IHooks(address(hook)), 500, SQRT_PRICE_1_1);
        PoolId id4 = k4.toId();
        vm.prank(address(this), carol);
        swap(k4, true, -1e15, ZERO_BYTES);
        vm.warp(block.timestamp + TRACK_WINDOW + 1);
        vm.expectRevert(SniperRebateHook.ConfigWindowClosed.selector);
        hook.configure(id4, true, 1000, 2 hours, 10 minutes);
    }

    // ---- buy tracking -------------------------------------------------------

    function test_buy_in_window_tracked() public {
        uint256 out = _buy(alice, 0.01 ether);
        assertEq(hook.netBought(id, alice), out);
        assertEq(_totalEligible(), out);
    }

    function test_buy_after_window_not_tracked() public {
        vm.warp(t0 + TRACK_WINDOW + 1);
        _buy(alice, 0.01 ether);
        assertEq(hook.netBought(id, alice), 0);
    }

    // ---- sell taxation + fee split -----------------------------------------

    function test_sell_taxed_and_split_90_10() public {
        uint256 out = _buy(alice, 0.01 ether);
        uint256 received = _sell(alice, out);
        uint256 hookBal = address(hook).balance;
        assertGt(hookBal, 0);
        // total fee = 25% of untaxed proceeds => fee*3 ~= received
        assertApproxEqAbs(hookBal * 3, received, 5);
        // 10% of the fee accrued to protocol, 90% to the pot
        uint256 proto = hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertApproxEqAbs(proto, hookBal * PROTO_BIPS / 10_000, 2);
        assertApproxEqAbs(uint256(_potQuote()), hookBal - proto, 2);
        // seller's eligibility is forfeited
        assertEq(hook.netBought(id, alice), 0);
    }

    function test_tax_declines_and_dies() public {
        assertEq(hook.currentTaxBips(id), START_TAX);
        vm.warp(t0 + PROTECTION / 2);
        assertEq(hook.currentTaxBips(id), START_TAX / 2);
        vm.warp(t0 + PROTECTION);
        assertEq(hook.currentTaxBips(id), 0);
        uint256 out = _buy(alice, 0.01 ether);
        uint256 potBefore = address(hook).balance;
        _sell(alice, out);
        assertEq(address(hook).balance, potBefore); // inert
    }

    // ---- claims -------------------------------------------------------------

    function _seedScenario() internal returns (uint256 aliceNet, uint256 bobNet) {
        aliceNet = _buy(alice, 0.01 ether);
        bobNet = _buy(bob, 0.03 ether);
        uint256 carolOut = _buy(carol, 0.02 ether);
        vm.warp(t0 + 1 hours);
        _sell(carol, carolOut);
        assertEq(hook.netBought(id, carol), 0);
        assertGt(_potQuote(), 0);
    }

    function test_claims_pro_rata_and_sniper_excluded() public {
        (uint256 aliceNet, uint256 bobNet) = _seedScenario();
        uint256 pot = _potQuote();
        vm.warp(t0 + PROTECTION + 1);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        hook.claim(id);
        uint256 aliceGot = alice.balance - aliceBefore;
        assertEq(aliceGot, pot * aliceNet / (aliceNet + bobNet));

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        hook.claim(id);
        uint256 bobGot = bob.balance - bobBefore;
        assertApproxEqAbs(bobGot * aliceNet, aliceGot * bobNet, aliceNet + bobNet);

        vm.prank(carol);
        vm.expectRevert(SniperRebateHook.NothingToClaim.selector);
        hook.claim(id);

        vm.prank(alice);
        vm.expectRevert(SniperRebateHook.AlreadyClaimed.selector);
        hook.claim(id);

        // protocol fees remain claimable to treasury after user claims
        uint256 proto = hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertGt(proto, 0);
        hook.claimProtocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(treasury.balance, proto);
    }

    function test_claim_timing_gates() public {
        _seedScenario();
        vm.prank(alice);
        vm.expectRevert(SniperRebateHook.ProtectionNotOver.selector);
        hook.claim(id);

        vm.warp(t0 + PROTECTION + CLAIM_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(SniperRebateHook.ClaimWindowClosed.selector);
        hook.claim(id);
    }

    // ---- sweep + protocol fees ---------------------------------------------

    function test_sweep_accrues_to_treasury_not_burn() public {
        _seedScenario();
        uint256 pot = _potQuote();
        uint256 protoBefore = hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO);

        vm.expectRevert(SniperRebateHook.ClaimWindowOpen.selector);
        hook.sweep(id);

        vm.warp(t0 + PROTECTION + CLAIM_WINDOW + 1);
        hook.sweep(id);
        assertEq(hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO), protoBefore + pot);
        assertEq(_potQuote(), 0);

        vm.expectRevert(SniperRebateHook.AlreadySwept.selector);
        hook.sweep(id);

        // full accrual reaches the treasury via pull
        uint256 total = hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO);
        hook.claimProtocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertEq(treasury.balance, total);
        assertEq(hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO), 0);
    }

    function test_reverting_treasury_cannot_brick_swaps() public {
        // rotate treasury to a contract that rejects ETH — swaps must still work
        RevertingReceiver bad = new RevertingReceiver();
        vm.prank(treasury);
        hook.setTreasury(address(bad));

        uint256 out = _buy(alice, 0.01 ether);
        uint256 received = _sell(alice, out); // must not revert
        assertGt(received, 0);
        assertGt(hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO), 0);

        // only the protocol-fee CLAIM fails, and only until treasury rotates back
        vm.expectRevert();
        hook.claimProtocolFees(CurrencyLibrary.ADDRESS_ZERO);
        vm.prank(address(bad));
        hook.setTreasury(treasury);
        hook.claimProtocolFees(CurrencyLibrary.ADDRESS_ZERO);
        assertGt(treasury.balance, 0);
    }

    // ---- treasury rotation --------------------------------------------------

    function test_treasury_rotation_only_by_treasury() public {
        vm.expectRevert(SniperRebateHook.NotTreasury.selector);
        hook.setTreasury(alice);

        vm.prank(treasury);
        hook.setTreasury(alice);
        assertEq(hook.treasury(), alice);

        vm.prank(treasury); // old key is dead now
        vm.expectRevert(SniperRebateHook.NotTreasury.selector);
        hook.setTreasury(bob);
    }

    // ---- fuzz ---------------------------------------------------------------

    function testFuzz_tax_bounded_and_split_exact(uint32 dt, uint96 ethIn) public {
        dt = uint32(bound(dt, 0, PROTECTION - 1));
        uint256 amount = bound(uint256(ethIn), 0.001 ether, 1 ether);
        uint256 out = _buy(alice, amount);
        vm.warp(t0 + dt);
        uint256 balBefore = address(hook).balance;
        uint256 received = _sell(alice, out);
        uint256 fee = address(hook).balance - balBefore;
        uint256 maxBips = uint256(START_TAX) * (PROTECTION - dt) / PROTECTION;
        assertLe(fee * 10_000, maxBips * (fee + received) + 10_000);
        // pot + protocol always exactly account for the fee
        assertEq(uint256(_potQuote()) + hook.protocolFees(CurrencyLibrary.ADDRESS_ZERO), fee);
    }
}

contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }

    // lets the test rotate treasury back
    function callSetTreasury(SniperRebateHook hook, address t) external {
        hook.setTreasury(t);
    }
}
