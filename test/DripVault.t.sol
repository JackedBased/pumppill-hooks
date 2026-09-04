// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DripVault, IERC20} from "../src/DripVault.sol";
import {DripVaultFactory} from "../src/DripVaultFactory.sol";

interface IMintableERC20 {
    function approve(address, uint256) external returns (bool);
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

contract DripVaultTest is Test, Deployers {
    DripVaultFactory factory;
    DripVault vault;
    address token;
    address dev = makeAddr("dev");
    uint256 t0;

    uint16 constant DRIP_BIPS = 100; // 1%/day
    uint16 constant DEPTH_BIPS = 100; // 1% of depth/day
    uint32 constant CLIFF = 7 days;
    uint256 constant ALLOCATION = 1_000_000e18;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        factory = new DripVaultFactory(manager);
        token = Currency.unwrap(currency0);
        vault = factory.createVault(key, token, dev, DRIP_BIPS, DEPTH_BIPS, CLIFF);
        t0 = block.timestamp;

        IMintableERC20(token).approve(address(vault), type(uint256).max);
        vault.deposit(ALLOCATION);
    }

    function _expectedCap() internal view returns (uint256 cap) {
        cap = ALLOCATION * DRIP_BIPS / 10_000;
        uint256 depthCap = vault.poolDepth() * DEPTH_BIPS / 10_000;
        if (depthCap < cap) cap = depthCap;
    }

    function test_registry() public view {
        assertEq(factory.vaultCount(), 1);
        assertEq(factory.vaultsByToken(token).length, 1);
        assertEq(factory.vaultsByToken(token)[0], address(vault));
    }

    function test_cliff_blocks_release() public {
        assertEq(vault.releasable(), 0);
        vm.expectRevert(DripVault.CliffActive.selector);
        vault.release(1);
        vm.warp(t0 + CLIFF);
        assertGt(vault.releasable(), 0);
    }

    function test_depth_is_positive() public view {
        assertGt(vault.poolDepth(), 0);
    }

    function test_releasable_is_min_of_caps() public {
        vm.warp(t0 + CLIFF);
        assertEq(vault.releasable(), _expectedCap());
    }

    function test_epoch_cap_and_reset() public {
        vm.warp(t0 + CLIFF);
        uint256 cap = vault.releasable();
        vault.release(cap);
        assertEq(IMintableERC20(token).balanceOf(dev), cap);
        assertEq(vault.releasable(), 0);
        vm.expectRevert(DripVault.ExceedsReleasable.selector);
        vault.release(1);
        // next epoch reopens the drip
        vm.warp(t0 + CLIFF + 1 days);
        assertGt(vault.releasable(), 0);
    }

    function test_release_goes_only_to_dev() public {
        vm.warp(t0 + CLIFF);
        address rando = makeAddr("rando");
        uint256 cap = vault.releasable();
        vm.prank(rando);
        vault.release(cap);
        assertEq(IMintableERC20(token).balanceOf(dev), cap);
        assertEq(IMintableERC20(token).balanceOf(rando), 0);
    }

    function test_unbound_vault_ignores_depth() public {
        DripVault ub = factory.createUnboundVault(token, dev, DRIP_BIPS, 0);
        IMintableERC20(token).approve(address(ub), type(uint256).max);
        ub.deposit(ALLOCATION);
        assertEq(ub.releasable(), ALLOCATION * DRIP_BIPS / 10_000);
        vm.expectRevert(DripVault.NotBound.selector);
        ub.pokeDead();
    }

    function test_fee_on_transfer_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        DripVault fv = factory.createUnboundVault(address(fot), dev, DRIP_BIPS, 0);
        fot.approve(address(fv), type(uint256).max);
        vm.expectRevert(DripVault.FeeOnTransferToken.selector);
        fv.deposit(1e18);
    }

    function test_dead_pool_unlock() public {
        // drain the pool entirely
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        vault.pokeDead();
        assertGt(vault.deadSince(), 0);

        vm.expectRevert(DripVault.PoolNotDead.selector);
        vault.unlockDead();

        vm.warp(block.timestamp + 30 days);
        uint256 bal = IMintableERC20(token).balanceOf(address(vault));
        vault.unlockDead();
        assertEq(IMintableERC20(token).balanceOf(dev), bal);
    }

    function test_dead_pool_timer_clears_when_liquidity_returns() public {
        modifyLiquidityRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        vault.pokeDead();
        assertGt(vault.deadSince(), 0);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        vault.pokeDead();
        assertEq(vault.deadSince(), 0);
    }

    function test_wrong_token_reverts() public {
        vm.expectRevert(DripVaultFactory.TokenNotInPool.selector);
        factory.createVault(key, makeAddr("other"), dev, DRIP_BIPS, DEPTH_BIPS, CLIFF);
    }

    /// fuzz: whatever the timing, a single epoch can never release more than
    /// the drip cap, and funds only ever reach the dev
    function testFuzz_epoch_never_exceeds_cap(uint64 warpBy, uint96 ask) public {
        warpBy = uint64(bound(warpBy, CLIFF, CLIFF + 3650 days));
        vm.warp(t0 + warpBy);
        uint256 cap = _expectedCap();
        uint256 amount = bound(uint256(ask), 1, ALLOCATION);
        if (amount > vault.releasable()) {
            vm.expectRevert(DripVault.ExceedsReleasable.selector);
            vault.release(amount);
        } else {
            vault.release(amount);
            assertLe(vault.releasedInEpoch(), cap);
            assertEq(IMintableERC20(token).balanceOf(dev), amount);
        }
    }
}
