// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DripVault, IERC20} from "./DripVault.sol";

/// @title DripVaultFactory
/// @notice Deploys DripVaults and keeps an enumerable on-chain registry so
///         scanners (and buyers) can discover every vault for a token.
contract DripVaultFactory {
    error TokenNotInPool();
    error ZeroToken();

    event VaultCreated(
        address indexed vault, address indexed token, address indexed devRecipient, bool poolBound, PoolId poolId
    );

    IPoolManager public immutable poolManager;

    address[] public allVaults;
    mapping(address => address[]) internal _vaultsByToken;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Create a vault bound to a v4 pool: the drip is capped by both
    ///         the time schedule and current pool depth.
    function createVault(
        PoolKey calldata key,
        address token,
        address devRecipient,
        uint16 dripBips,
        uint16 depthBips,
        uint32 cliffSeconds
    ) external returns (DripVault vault) {
        if (token == address(0)) revert ZeroToken();
        bool tokenIsZero;
        if (Currency.unwrap(key.currency0) == token) tokenIsZero = true;
        else if (Currency.unwrap(key.currency1) != token) revert TokenNotInPool();

        vault = new DripVault(
            DripVault.VaultConfig({
                token: IERC20(token),
                devRecipient: devRecipient,
                dripBips: dripBips,
                depthBips: depthBips,
                cliffSeconds: cliffSeconds,
                poolBound: true,
                tokenIsZero: tokenIsZero,
                poolManager: poolManager,
                poolId: key.toId()
            })
        );
        _register(address(vault), token, devRecipient, true, key.toId());
    }

    /// @notice Create an unbound vault (pure time-schedule drip). Works with
    ///         any pool type — v2/v3/v4/launchpad curves.
    function createUnboundVault(address token, address devRecipient, uint16 dripBips, uint32 cliffSeconds)
        external
        returns (DripVault vault)
    {
        if (token == address(0)) revert ZeroToken();
        vault = new DripVault(
            DripVault.VaultConfig({
                token: IERC20(token),
                devRecipient: devRecipient,
                dripBips: dripBips,
                depthBips: 0,
                cliffSeconds: cliffSeconds,
                poolBound: false,
                tokenIsZero: false,
                poolManager: poolManager,
                poolId: PoolId.wrap(0)
            })
        );
        _register(address(vault), token, devRecipient, false, PoolId.wrap(0));
    }

    function _register(address vault, address token, address devRecipient, bool poolBound, PoolId poolId) internal {
        allVaults.push(vault);
        _vaultsByToken[token].push(vault);
        emit VaultCreated(vault, token, devRecipient, poolBound, poolId);
    }

    // ----------------------------------------------------------- registry

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function vaultsByToken(address token) external view returns (address[] memory) {
        return _vaultsByToken[token];
    }
}
