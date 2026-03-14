// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  VaultFactoryV2.sol — AeroCompounder Factory (v2)
//
//  Deploys EIP-1167 minimal proxy clones of AutoCompounderV2.
//  Adds:
//    - WETH address (needed by vault for profitability check)
//    - createVault now accepts perfFeeBps + swap paths
// ============================================================

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./AutoCompounderV2.sol";
import "./IAerodromeRouter.sol";
import "./IVaultFactory.sol";

contract VaultFactoryV2 is Ownable {
    using Clones for address;

    // ── Aerodrome Config (immutable after deploy) ─────────────

    address public immutable router;
    address public immutable aeroToken;
    address public immutable weth;

    // ── Mutable Config ────────────────────────────────────────

    address public keeper;
    address public feeRecipient;

    // ── Implementation ────────────────────────────────────────

    address public immutable implementation;

    // ── Vault Registry ────────────────────────────────────────

    address[] public vaults;
    mapping(address => address) public vaultByLp;

    // ── Events ────────────────────────────────────────────────

    event VaultCreated(
        address indexed vault,
        address indexed lpToken,
        address indexed gauge,
        string vaultName
    );
    event KeeperUpdated(address indexed newKeeper);
    event FeeRecipientUpdated(address indexed newFeeRecipient);

    // ── Errors ────────────────────────────────────────────────

    error ZeroAddress();
    error VaultAlreadyExists(address lpToken);

    // ── Constructor ───────────────────────────────────────────

    constructor(
        address _router,
        address _aeroToken,
        address _weth,
        address _feeRecipient,
        address _keeper
    ) Ownable(msg.sender) {
        if (_router       == address(0) ||
            _aeroToken    == address(0) ||
            _weth         == address(0) ||
            _feeRecipient == address(0) ||
            _keeper       == address(0)) revert ZeroAddress();

        router       = _router;
        aeroToken    = _aeroToken;
        weth         = _weth;
        feeRecipient = _feeRecipient;
        keeper       = _keeper;

        implementation = address(new AutoCompounderV2());
    }

    // ── Factory Function ──────────────────────────────────────

    /// @notice Deploy a new v2 vault clone.
    /// @param lpToken      Aerodrome LP token
    /// @param gauge        Aerodrome gauge for this LP
    /// @param vaultName    Human-readable name, e.g. "USDC/AERO"
    /// @param perfFeeBps   Initial performance fee (≤ 200 bps = 2%)
    /// @param pathToken0   Multi-hop route: AERO → token0
    /// @param pathToken1   Multi-hop route: AERO → token1
    /// @return vault       Address of the newly deployed clone
    function createVault(
        address lpToken,
        address gauge,
        string calldata vaultName,
        uint256 perfFeeBps,
        IAerodromeRouter.Route[] calldata pathToken0,
        IAerodromeRouter.Route[] calldata pathToken1
    ) external onlyOwner returns (address vault) {
        if (lpToken == address(0) || gauge == address(0)) revert ZeroAddress();
        if (vaultByLp[lpToken] != address(0)) revert VaultAlreadyExists(lpToken);

        vault = implementation.clone();

        AutoCompounderV2(vault).initialize(
            lpToken,
            gauge,
            address(this),
            vaultName,
            perfFeeBps,
            pathToken0,
            pathToken1
        );

        vaults.push(vault);
        vaultByLp[lpToken] = vault;

        emit VaultCreated(vault, lpToken, gauge, vaultName);
    }

    // ── Admin ─────────────────────────────────────────────────

    function setKeeper(address _keeper) external onlyOwner {
        if (_keeper == address(0)) revert ZeroAddress();
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    // ── Views ─────────────────────────────────────────────────

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function getAllVaults() external view returns (address[] memory) {
        return vaults;
    }
}
