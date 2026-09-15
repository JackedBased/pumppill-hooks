// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {DripVaultV2, IERC20} from "../src/DripVaultV2.sol";
import {DripVaultV2Factory} from "../src/DripVaultV2Factory.sol";

interface IMintableERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// 1%-burn fee-on-transfer token: deposits must be rejected.
contract FeeOnTransferToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        balanceOf[msg.sender] = 1e27;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        uint256 fee = amount / 100;
        balanceOf[to] += amount - fee;
        return true;
    }
}

/// The three checkpoints Nodar asked us to answer are named in the test names:
/// pool binding, who owns the deposited tokens, and how late or third-party
/// deposits interact with the cliff.
contract DripVaultV2Test is Test, Deployers {
    DripVaultV2Factory factory;
    DripVaultV2 vault;
    address token;
    address dev = makeAddr("dev");
    address stranger = makeAddr("stranger");
    uint256 t0;

    uint16 constant DRIP_BIPS = 100; // 1%/day
    uint16 constant DEPTH_BIPS = 100; // 1% of depth/day
    uint32 constant CLIFF = 7 days;
    uint256 constant MIN_DEPOSIT = 1e18;
    uint256 constant ALLOCATION = 1_000_000e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        factory = new DripVaultV2Factory(manager);
        token = Currency.unwrap(currency0);
        vault = factory.createVault(key, _params(address(this)));
        t0 = block.timestamp;

        IMintableERC20(token).approve(address(vault), type(uint256).max);
        vault.deposit(ALLOCATION);
    }

    function _params(address depositor) internal view returns (DripVaultV2Factory.NewVault memory) {
        return DripVaultV2Factory.NewVault({
            token: token,
            devRecipient: dev,
            depositor: depositor,
            dripBips: DRIP_BIPS,
            depthBips: DEPTH_BIPS,
            cliffSeconds: CLIFF,
            minDeposit: MIN_DEPOSIT
        });
    }

    function _capFor(uint256 matured) internal view returns (uint256 cap) {
        cap = matured * DRIP_BIPS / 10_000;
        uint256 depthCap = vault.poolDepth() * DEPTH_BIPS / 10_000;
        if (depthCap < cap) cap = depthCap;
    }

    // ------------------------------------------------------ 1. pool binding

    function test_poolBinding_is_fixed_at_construction() public view {
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(key.toId()), "vault must carry the pool it was made for");
        assertTrue(vault.poolBound());
        assertTrue(vault.tokenIsZero(), "currency0 is the escrowed token in this fixture");
        assertGt(vault.poolDepth(), 0, "a bound vault reads live depth");
    }

    function test_poolBinding_has_no_rebind_path() public view {
        // There is no bind(), so there is nothing to restrict and no way to
        // point a funded vault at a pool with fabricated depth after the fact.
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(key.toId()));
    }

    function test_poolBinding_rejects_a_token_that_is_not_in_the_pool() public {
        DripVaultV2Factory.NewVault memory p = _params(address(this));
        p.token = makeAddr("elsewhere");
        vm.expectRevert(DripVaultV2Factory.TokenNotInPool.selector);
        factory.createVault(key, p);
    }

    function test_registry_lists_every_vault_for_a_token() public view {
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultsByToken(token).length, 1);
        assertEq(factory.vaultsByToken(token)[0], address(vault));
    }

    // -------------------------------------- 2. who owns the deposited tokens

    function test_ownership_only_devRecipient_can_ever_receive() public {
        vm.warp(t0 + CLIFF);
        uint256 amount = vault.releasable();
        assertGt(amount, 0);

        // Anyone may poke the release; the destination is not theirs to choose.
        vm.prank(stranger);
        vault.release(amount);

        assertEq(IMintableERC20(token).balanceOf(dev), amount, "tokens go to devRecipient");
        assertEq(IMintableERC20(token).balanceOf(stranger), 0, "never to the caller");
    }

    function test_ownership_depositor_has_no_claim_on_what_it_deposited() public {
        DripVaultV2 open = factory.createVault(key, _params(address(0)));
        IMintableERC20(token).transfer(stranger, 10e18);

        vm.startPrank(stranger);
        IMintableERC20(token).approve(address(open), type(uint256).max);
        open.deposit(10e18);
        vm.stopPrank();

        vm.warp(block.timestamp + CLIFF);
        uint256 amount = open.releasable();
        assertGt(amount, 0);
        open.release(amount);

        // A deposit by anyone other than the creator is a donation on the same
        // schedule. There is no withdrawal path back to the depositor.
        assertEq(IMintableERC20(token).balanceOf(dev), amount);
        assertEq(IMintableERC20(token).balanceOf(stranger), 0, "stranger gets nothing back");
    }

    function test_ownership_deposits_are_restricted_when_a_depositor_is_set() public {
        IMintableERC20(token).transfer(stranger, 10e18);
        vm.startPrank(stranger);
        IMintableERC20(token).approve(address(vault), type(uint256).max);
        vm.expectRevert(DripVaultV2.NotDepositor.selector);
        vault.deposit(10e18);
        vm.stopPrank();
    }

    function test_ownership_open_vault_accepts_anyone() public {
        DripVaultV2 open = factory.createVault(key, _params(address(0)));
        IMintableERC20(token).transfer(stranger, 10e18);
        vm.startPrank(stranger);
        IMintableERC20(token).approve(address(open), type(uint256).max);
        open.deposit(10e18);
        vm.stopPrank();
        assertEq(open.allocation(), 10e18);
    }

    // ------------------------------- 3. late and third-party deposits × cliff

    /// The v1 hole, stated as a test: in v1 the cliff ran from createdAt alone,
    /// so anything deposited after it had passed was releasable the same day.
    function test_lateDeposit_is_not_immediately_releasable() public {
        vm.warp(t0 + CLIFF);
        uint256 maturedBefore = vault.maturedAllocation();
        assertEq(maturedBefore, ALLOCATION);

        uint256 late = 500_000e18;
        vault.deposit(late);

        assertEq(vault.allocation(), ALLOCATION + late, "allocation counts it");
        assertEq(vault.maturedAllocation(), ALLOCATION, "but it has not matured");
        assertEq(vault.nextUnlockAt(), uint64(block.timestamp) + CLIFF);

        // Not a single token of the late deposit is reachable yet.
        assertLe(vault.releasable(), _capFor(ALLOCATION), "late deposit must not be releasable");

        vm.warp(block.timestamp + CLIFF);
        assertEq(vault.maturedAllocation(), ALLOCATION + late, "it matures on its own clock");
        assertEq(vault.nextUnlockAt(), 0);
    }

    /// The second half of the same hole: in v1 the per-epoch cap was sized off
    /// total allocation, so a late deposit sped up the drip on the bag that was
    /// already escrowed.
    function test_lateDeposit_does_not_raise_the_cap_before_it_matures() public {
        vm.warp(t0 + CLIFF);
        uint256 releasableBefore = vault.releasable();

        vault.deposit(10_000_000e18); // ten times the original bag

        assertEq(vault.releasable(), releasableBefore, "an immature deposit must not accelerate the drip");
    }

    function test_thirdParty_cannot_accelerate_an_open_vault() public {
        DripVaultV2 open = factory.createVault(key, _params(address(0)));
        IMintableERC20(token).approve(address(open), type(uint256).max);
        open.deposit(ALLOCATION);
        uint256 openedAt = block.timestamp;

        vm.warp(openedAt + CLIFF);
        uint256 before = open.releasable();

        IMintableERC20(token).transfer(stranger, 5_000_000e18);
        vm.startPrank(stranger);
        IMintableERC20(token).approve(address(open), type(uint256).max);
        open.deposit(5_000_000e18);
        vm.stopPrank();

        assertEq(open.releasable(), before, "a stranger cannot speed up someone else's drip");
    }

    function test_cliff_blocks_release_entirely_before_anything_matures() public {
        assertEq(vault.releasable(), 0);
        vm.expectRevert(DripVaultV2.CliffActive.selector);
        vault.release(1);
    }

    function test_each_tranche_carries_its_own_unlock() public {
        vm.warp(t0 + 1 days);
        vault.deposit(100e18);
        vm.warp(t0 + 2 days);
        vault.deposit(100e18);

        assertEq(vault.trancheCount(), 3);
        assertEq(vault.maturedAllocation(), 0, "nothing has reached its own cliff yet");

        vm.warp(t0 + CLIFF);
        assertEq(vault.maturedAllocation(), ALLOCATION);
        vm.warp(t0 + CLIFF + 1 days);
        assertEq(vault.maturedAllocation(), ALLOCATION + 100e18);
        vm.warp(t0 + CLIFF + 2 days);
        assertEq(vault.maturedAllocation(), ALLOCATION + 200e18);
    }

    // ------------------------------------------------- bounds and exclusions

    function test_dust_deposits_are_rejected() public {
        vm.expectRevert(DripVaultV2.DepositTooSmall.selector);
        vault.deposit(MIN_DEPOSIT - 1);
    }

    function test_tranche_count_is_bounded() public {
        // One tranche already exists from setUp.
        for (uint256 i = 1; i < vault.MAX_TRANCHES(); ++i) {
            vault.deposit(MIN_DEPOSIT);
        }
        assertEq(vault.trancheCount(), vault.MAX_TRANCHES());
        vm.expectRevert(DripVaultV2.TooManyTranches.selector);
        vault.deposit(MIN_DEPOSIT);
    }

    function test_a_full_tranche_array_still_releases_within_gas() public {
        for (uint256 i = 1; i < vault.MAX_TRANCHES(); ++i) {
            vault.deposit(MIN_DEPOSIT);
        }
        vm.warp(t0 + CLIFF);
        uint256 gasBefore = gasleft();
        vault.release(vault.releasable());
        uint256 used = gasBefore - gasleft();
        assertLt(used, 1_000_000, "absorbing a full backlog must stay well inside a block");
    }

    function test_second_release_does_not_rewalk_matured_tranches() public {
        for (uint256 i = 1; i < vault.MAX_TRANCHES(); ++i) {
            vault.deposit(MIN_DEPOSIT);
        }
        vm.warp(t0 + CLIFF);
        vault.release(vault.releasable());

        vm.warp(t0 + CLIFF + 1 days);
        uint256 gasBefore = gasleft();
        vault.release(vault.releasable());
        uint256 used = gasBefore - gasleft();
        assertLt(used, 120_000, "the cursor means each tranche is walked once in its life");
    }

    function test_fee_on_transfer_token_is_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        DripVaultV2Factory.NewVault memory p = _params(address(this));
        p.token = address(fot);
        DripVaultV2 v = factory.createUnboundVault(p);
        fot.approve(address(v), type(uint256).max);
        vm.expectRevert(DripVaultV2.FeeOnTransferToken.selector);
        v.deposit(1000e18);
    }

    // ---------------------------------------------------------- rate limits

    function test_depth_cap_binds_when_it_is_the_tighter_of_the_two() public {
        vm.warp(t0 + CLIFF);
        uint256 timeCap = ALLOCATION * DRIP_BIPS / 10_000;
        uint256 depthCap = vault.poolDepth() * DEPTH_BIPS / 10_000;
        assertLt(depthCap, timeCap, "fixture is meant to be depth-bound");
        assertEq(vault.releasable(), depthCap);
    }

    function test_epoch_cap_cannot_be_exceeded_twice_in_one_day() public {
        vm.warp(t0 + CLIFF);
        uint256 cap = vault.releasable();
        vault.release(cap);
        assertEq(vault.releasable(), 0, "the epoch is spent");
        vm.expectRevert(DripVaultV2.ExceedsReleasable.selector);
        vault.release(1);

        vm.warp(block.timestamp + 1 days);
        assertGt(vault.releasable(), 0, "next epoch refills");
    }

    function test_release_can_never_exceed_what_has_matured() public {
        vm.warp(t0 + CLIFF);
        uint256 total;
        for (uint256 i = 0; i < 400; ++i) {
            uint256 r = vault.releasable();
            if (r > 0) {
                vault.release(r);
                total += r;
            }
            vm.warp(block.timestamp + 1 days);
        }
        assertLe(total, vault.maturedAllocation(), "never more than matured");
        assertEq(IMintableERC20(token).balanceOf(dev), total);
    }

    // ------------------------------------------------------ dead-pool escape

    function test_dead_pool_unlocks_everything_including_immature_tranches() public {
        vm.warp(t0 + CLIFF);
        vault.deposit(250_000e18); // immature, and stays immature throughout

        _drainPoolLiquidity();
        vault.pokeDead();
        vm.warp(block.timestamp + vault.DEAD_POOL_DELAY());

        uint256 held = IMintableERC20(token).balanceOf(address(vault));
        vault.unlockDead();

        // The cliff protects buyers in a live market. There is no market left
        // to protect here, and burning someone's tokens for launching into a
        // pool that died is not a protection.
        assertEq(IMintableERC20(token).balanceOf(dev), held);
        assertEq(IMintableERC20(token).balanceOf(address(vault)), 0);
    }

    function test_dead_pool_timer_clears_if_liquidity_returns() public {
        _drainPoolLiquidity();
        vault.pokeDead();
        assertGt(vault.deadSince(), 0);

        modifyLiquidityRouter.modifyLiquidity(
            key, LIQUIDITY_PARAMS, ""
        );
        vault.pokeDead();
        assertEq(vault.deadSince(), 0, "a pool that comes back cancels the escape hatch");
    }

    function _drainPoolLiquidity() internal {
        ModifyLiquidityParams memory p = LIQUIDITY_PARAMS;
        p.liquidityDelta = -p.liquidityDelta;
        modifyLiquidityRouter.modifyLiquidity(key, p, "");
    }
}
