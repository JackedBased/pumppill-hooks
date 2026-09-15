// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {DripVaultV2} from "../src/DripVaultV2.sol";
import {DripVaultV2Factory} from "../src/DripVaultV2Factory.sol";
import {BuyAndEscrowRouter} from "../src/BuyAndEscrowRouter.sol";

interface IERC20T {
    function balanceOf(address) external view returns (uint256);
}

/// Stands in for a launch hook — an anti-snipe cap, an opening-window fee,
/// anything that inspects a buy. It records what it was told so the test can
/// assert the escrow route is seen like any other buy, and that the swap
/// carries a beneficiary distinct from the contract receiving the tokens.
contract RecordingHook {
    address public lastSender;
    address public lastBeneficiary;
    uint256 public swapCount;

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        lastSender = sender;
        if (hookData.length == 32) lastBeneficiary = abi.decode(hookData, (address));
        swapCount++;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

contract BuyAndEscrowRouterTest is Test, Deployers {
    BuyAndEscrowRouter router;
    DripVaultV2Factory factory;
    DripVaultV2 vault;
    RecordingHook hook;

    address token;
    address dev = makeAddr("dev");
    address creator = makeAddr("creator");

    uint16 constant DRIP_BIPS = 100;
    uint16 constant DEPTH_BIPS = 100;
    uint32 constant CLIFF = 7 days;
    uint256 constant MIN_DEPOSIT = 1e15;

    function setUp() public {
        deployFreshManagerAndRouters();
        currency1 = deployMintAndApproveCurrency();
        currency0 = CurrencyLibrary.ADDRESS_ZERO; // native ETH
        token = Currency.unwrap(currency1);

        address hookAddr = address(uint160((uint256(0x4444) << 144) | uint256(Hooks.BEFORE_SWAP_FLAG)));
        deployCodeTo("BuyAndEscrowRouter.t.sol:RecordingHook", "", hookAddr);
        hook = RecordingHook(hookAddr);

        (key,) = initPoolAndAddLiquidityETH(currency0, currency1, IHooks(hookAddr), 3000, SQRT_PRICE_1_1, 50 ether);

        // The Deployers default position is both tiny and only ~1.2% wide, so
        // a single buy walks straight off the end of it and the pool reports
        // zero active liquidity afterwards. A launch pool is not that shape,
        // and the depth cap is meaningless against a range that is already
        // spent, so give the fixture a full-range position to swap against.
        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 500 ether}(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 500e18, salt: 0}),
            ""
        );

        router = new BuyAndEscrowRouter(manager);
        factory = new DripVaultV2Factory(manager);
        vault = factory.createVault(key, _params(address(router), MIN_DEPOSIT));

        vm.deal(creator, 100 ether);
    }

    function _params(address depositor, uint256 minDeposit)
        internal
        view
        returns (DripVaultV2Factory.NewVault memory)
    {
        return DripVaultV2Factory.NewVault({
            token: token,
            devRecipient: dev,
            depositor: depositor,
            dripBips: DRIP_BIPS,
            depthBips: DEPTH_BIPS,
            cliffSeconds: CLIFF,
            minDeposit: minDeposit
        });
    }

    function _buy(uint256 amount, uint256 minEscrowed) internal returns (uint256) {
        vm.prank(creator);
        return router.buyAndEscrowWithETH{value: amount}(key, vault, minEscrowed, block.timestamp + 60);
    }

    // --------------------------------------------------------------- the core

    function test_buy_and_escrow_happen_in_one_transaction() public {
        uint256 escrowed = _buy(1 ether, 0);

        assertGt(escrowed, 0, "the buy produced nothing");
        assertEq(vault.allocation(), escrowed, "every token bought is escrowed");
        assertEq(IERC20T(token).balanceOf(address(vault)), escrowed, "and is actually held by the vault");
        assertEq(vault.trancheCount(), 1);
        assertEq(IERC20T(token).balanceOf(creator), 0, "the creator never holds a free-floating bag");
    }

    function test_escrows_the_amount_actually_received() public {
        uint256 escrowed = _buy(1 ether, 0);
        // Measured on the balance that moved, not on a quote or a reported
        // delta: allocation, vault balance and the returned figure must agree
        // exactly or the transaction should not have survived.
        assertEq(vault.allocation(), IERC20T(token).balanceOf(address(vault)));
        assertEq(vault.allocation(), escrowed);
    }

    function test_router_holds_nothing_afterwards() public {
        _buy(1 ether, 0);
        assertEq(IERC20T(token).balanceOf(address(router)), 0, "tokens must not linger in the router");
        assertEq(address(router).balance, 0, "nor ETH");
    }

    function test_escrowed_bag_is_locked_on_the_normal_schedule() public {
        uint256 escrowed = _buy(1 ether, 0);
        assertEq(vault.releasable(), 0, "a freshly bought bag is behind its own cliff");

        vm.warp(block.timestamp + CLIFF);
        assertEq(vault.maturedAllocation(), escrowed);
        assertGt(vault.releasable(), 0);
        assertLe(vault.releasable(), escrowed * DRIP_BIPS / 10_000, "and still rate-limited");
    }

    // ------------------------------------------------- all-or-nothing failure

    function test_a_failed_escrow_takes_the_whole_buy_down_with_it() public {
        // A vault whose minimum deposit the buy cannot meet: the escrow leg
        // reverts, so the buy must revert too.
        DripVaultV2 strict = factory.createVault(key, _params(address(router), 1e30));

        uint256 ethBefore = creator.balance;
        uint256 swapsBefore = hook.swapCount();

        vm.prank(creator);
        vm.expectRevert(DripVaultV2.DepositTooSmall.selector);
        router.buyAndEscrowWithETH{value: 1 ether}(key, strict, 0, block.timestamp + 60);

        assertEq(creator.balance, ethBefore, "the creator's ETH is untouched");
        assertEq(strict.allocation(), 0);
        assertEq(hook.swapCount(), swapsBefore, "the swap is rolled back with everything else");
    }

    function test_rejects_a_vault_that_does_not_admit_this_router() public {
        DripVaultV2 other = factory.createVault(key, _params(makeAddr("someoneElse"), MIN_DEPOSIT));
        vm.prank(creator);
        vm.expectRevert(BuyAndEscrowRouter.VaultRejectsRouter.selector);
        router.buyAndEscrowWithETH{value: 1 ether}(key, other, 0, block.timestamp + 60);
    }

    function test_rejects_funding_a_vault_from_a_different_pool() public {
        // Same token, different pool. The vault's depth cap reads the pool it
        // was bound to, so buying somewhere thinner — or somewhere fabricated —
        // would size the drip off a pool the escrow has nothing to do with.
        (PoolKey memory otherKey,) =
            initPoolAndAddLiquidityETH(currency0, currency1, IHooks(address(0)), 500, SQRT_PRICE_1_1, 1 ether);

        vm.prank(creator);
        vm.expectRevert(BuyAndEscrowRouter.VaultTokenMismatch.selector);
        router.buyAndEscrowWithETH{value: 1 ether}(otherKey, vault, 0, block.timestamp + 60);
    }

    function test_minEscrowed_binds_on_what_reaches_the_vault() public {
        vm.prank(creator);
        vm.expectRevert();
        router.buyAndEscrowWithETH{value: 1 ether}(key, vault, type(uint128).max, block.timestamp + 60);
        assertEq(vault.allocation(), 0, "nothing escrowed when the guard trips");
    }

    function test_expired_deadline_reverts() public {
        vm.warp(block.timestamp + 100);
        vm.prank(creator);
        vm.expectRevert(BuyAndEscrowRouter.Expired.selector);
        router.buyAndEscrowWithETH{value: 1 ether}(key, vault, 0, block.timestamp - 1);
    }

    // ------------------------------------------------ guards and attribution

    function test_the_buy_is_visible_to_the_pool_hook() public {
        uint256 before = hook.swapCount();
        _buy(1 ether, 0);
        assertEq(hook.swapCount(), before + 1, "launch guards must see an escrow buy like any other");
        assertEq(hook.lastSender(), address(router), "the router is the sender, and asks for no exemption");
    }

    function test_the_beneficiary_is_the_creator_not_the_receiving_vault() public {
        _buy(1 ether, 0);
        assertEq(hook.lastBeneficiary(), dev, "the swap names who the buy is for");
        assertTrue(hook.lastBeneficiary() != address(vault), "not the contract that receives the tokens");
        assertTrue(hook.lastBeneficiary() != address(router), "and not the router either");
    }

    function test_repeated_buys_each_get_their_own_tranche() public {
        _buy(1 ether, 0);
        vm.warp(block.timestamp + 1 days);
        _buy(1 ether, 0);

        assertEq(vault.trancheCount(), 2);
        assertEq(vault.maturedAllocation(), 0);

        vm.warp(block.timestamp + CLIFF - 1 days);
        (, uint64 firstUnlock) = vault.tranches(0);
        (, uint64 secondUnlock) = vault.tranches(1);
        assertEq(secondUnlock - firstUnlock, 1 days, "each buy locks from its own moment");
    }
}
