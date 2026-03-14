// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared interface implemented by both VaultFactory and VaultFactoryV2.
///         Vaults resolve all governance references through this interface.
interface IVaultFactory {
    function owner()        external view returns (address);
    function keeper()       external view returns (address);
    function feeRecipient() external view returns (address);
    function router()       external view returns (address);
    function aeroToken()    external view returns (address);
    function weth()         external view returns (address);
}
