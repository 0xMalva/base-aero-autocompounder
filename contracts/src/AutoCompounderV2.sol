// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  AutoCompounderV2.sol — AeroCompounder Vault Implementation
//
//  Upgrades over V1:
//    1. Multi-hop swap paths (configurable Route[] per token)
//    2. Performance fee hard cap lowered to 2% (200 bps)
//    3. Emergency withdraw gated behind pause + 24h deposit cooldown
//    4. On-chain harvest profitability guard (5x gas cost)
//    5. onlyKeeper modifier on harvest()
//    6. Path validation at set-time (factory + continuity checks)
//
//  Architecture:
//    - Deployed as EIP-1167 minimal proxy clone via VaultFactoryV2
//    - All governance references resolve through IVaultFactory
//    - Swap paths stored as IAerodromeRouter.Route[] arrays in clone storage
// ============================================================

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// ─── Aerodrome Interfaces ─────────────────────────────────────

import "./IAerodromeRouter.sol";

interface IGauge {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account) external;
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
}

interface IPoolFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

interface IPool {
    function token0()  external view returns (address);
    function token1()  external view returns (address);
    function stable()  external view returns (bool);
}

import "./IVaultFactory.sol";

// ─── Vault ───────────────────────────────────────────────────

/// @title AutoCompounderV2 — AeroCompounder Vault (v2)
/// @notice ERC20 share token representing a proportional stake in a compounding LP position.
///         Supports multi-hop swap paths, pause-gated emergency withdraw, and on-chain
///         harvest profitability enforcement.
/// @dev Deployed as EIP-1167 minimal proxy clone by VaultFactoryV2.
contract AutoCompounderV2 is ERC20, ReentrancyGuard, Initializable, Pausable {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR       = 10_000;

    /// @notice Hard cap on performance fee — 2%, immutable forever.
    ///         Stored as a constant so it is baked into bytecode and
    ///         verifiable on Etherscan without trusting any storage slot.
    uint256 public constant MAX_PERF_FEE_BPS      = 200;   // 2%

    uint256 public constant MAX_WITHDRAW_FEE_BPS  = 100;   // 1%
    uint256 public constant MIN_HARVEST_AMOUNT    = 1e15;  // 0.001 AERO
    uint256 public constant ADD_LIQ_SLIPPAGE_BPS  = 200;   // 2% on addLiquidity

    /// @notice Minimum ratio of reward value to gas cost for harvesting.
    uint256 public constant MIN_PROFIT_MULTIPLIER = 5;

    /// @notice Conservative gas estimate for a harvest tx, used in on-chain
    ///         profitability check. Over-estimated to be safe.
    uint256 public constant HARVEST_GAS_ESTIMATE  = 500_000;

    /// @notice Cooldown after deposit before emergency withdraw is allowed.
    uint256 public constant EMERGENCY_WITHDRAW_COOLDOWN = 24 hours;

    /// @notice Maximum hops in a swap path (prevents gas exhaustion).
    uint256 public constant MAX_PATH_LENGTH = 4;

    // ── Immutable-like State (set once in initialize) ─────────

    IERC20        public lpToken;
    IGauge        public gauge;
    address       public token0;
    address       public token1;
    bool          public isStable;

    /// @notice Canonical Aerodrome pool factory — used to validate swap paths.
    address       public poolFactory;

    /// @notice The VaultFactoryV2 that deployed this clone.
    IVaultFactory public factory;

    // ── Swap Paths ────────────────────────────────────────────

    /// @notice Multi-hop path: AERO → ... → token0
    IAerodromeRouter.Route[] public swapPathToken0;

    /// @notice Multi-hop path: AERO → ... → token1
    IAerodromeRouter.Route[] public swapPathToken1;

    // ── Mutable State ─────────────────────────────────────────

    uint256 public perfFeeBps;
    uint256 public withdrawFeeBps;

    uint256 public totalLpManaged;
    uint256 public lastHarvestTimestamp;
    uint256 public totalFeesCollected;
    uint256 public totalWithdrawFeesCollected;
    uint256 public totalRewardsCompounded;

    /// @notice Tracks the last deposit time per user for emergency withdraw cooldown.
    mapping(address => uint256) public lastDepositTime;

    /// @notice Human-readable name, e.g. "USDC/AERO"
    string public vaultName;

    // ── Events ────────────────────────────────────────────────

    event Deposited(address indexed user, uint256 lpAmount, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 lpAmount, uint256 fee);
    event Harvested(uint256 aeroHarvested, uint256 feeAmount, uint256 newLp, uint256 timestamp);
    event EmergencyWithdrawn(address indexed user, uint256 shares, uint256 lpAmount);
    event PerfFeeBpsUpdated(uint256 newFeeBps);
    event WithdrawFeeBpsUpdated(uint256 newFeeBps);
    event SwapPathsUpdated();

    // ── Errors ────────────────────────────────────────────────

    error NotKeeper();
    error NotOwner();
    error ZeroAmount();
    error FeeTooHigh();
    error InsufficientShares();
    error HarvestAmountTooLow();
    error HarvestNotProfitable();
    error InvalidPath();
    error NonCanonicalFactory();
    error PoolDoesNotExist();
    error EmergencyWithdrawCooldown();
    error VaultNotPaused();

    // ── Constructor ───────────────────────────────────────────
    // ERC20 requires name/symbol in constructor even for clones.

    constructor() ERC20("AeroCompounder Vault V2", "acVAULTV2") {}

    // ── Initializer ───────────────────────────────────────────

    /// @notice Called once by VaultFactoryV2 after cloning.
    /// @param _lpToken      Aerodrome LP token address
    /// @param _gauge        Aerodrome gauge for this LP
    /// @param _factory      VaultFactoryV2 address
    /// @param _vaultName    Human-readable name
    /// @param _perfFeeBps   Initial performance fee (≤ MAX_PERF_FEE_BPS)
    /// @param _pathToken0   Multi-hop route AERO → token0
    /// @param _pathToken1   Multi-hop route AERO → token1
    function initialize(
        address               _lpToken,
        address               _gauge,
        address               _factory,
        string  calldata      _vaultName,
        uint256               _perfFeeBps,
        IAerodromeRouter.Route[] calldata _pathToken0,
        IAerodromeRouter.Route[] calldata _pathToken1
    ) external initializer {
        if (_perfFeeBps > MAX_PERF_FEE_BPS) revert FeeTooHigh();

        lpToken   = IERC20(_lpToken);
        gauge     = IGauge(_gauge);
        factory   = IVaultFactory(_factory);
        vaultName = _vaultName;

        perfFeeBps     = _perfFeeBps;
        withdrawFeeBps = 10; // 0.1% default

        IPool pool  = IPool(_lpToken);
        token0      = pool.token0();
        token1      = pool.token1();
        isStable    = pool.stable();
        poolFactory = IAerodromeRouter(factory.router()).defaultFactory();

        // Validate and store swap paths
        _validatePath(_pathToken0, token0);
        _validatePath(_pathToken1, token1);
        _storePath(swapPathToken0, _pathToken0);
        _storePath(swapPathToken1, _pathToken1);

        // Approve router and gauge
        address _router = factory.router();
        IERC20(_lpToken).forceApprove(_gauge, type(uint256).max);
        IERC20(token0).forceApprove(_router, type(uint256).max);
        IERC20(token1).forceApprove(_router, type(uint256).max);
        IERC20(factory.aeroToken()).forceApprove(_router, type(uint256).max);
    }

    // ── Access Control ────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != factory.owner()) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != factory.keeper() && msg.sender != factory.owner()) revert NotKeeper();
        _;
    }

    // ── User Functions ────────────────────────────────────────

    /// @notice Deposit LP tokens, receive vault shares.
    /// @param lpAmount Amount of LP to deposit
    /// @return shares  Vault shares minted
    function deposit(uint256 lpAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (lpAmount == 0) revert ZeroAmount();

        uint256 totalLpBefore     = totalLpManaged;
        uint256 totalSharesBefore = totalSupply();

        lpToken.safeTransferFrom(msg.sender, address(this), lpAmount);
        gauge.deposit(lpAmount);

        if (totalSharesBefore == 0 || totalLpBefore == 0) {
            shares = lpAmount - 1000;
            _mint(address(0xdead), 1000);
        } else {
            shares = (lpAmount * totalSharesBefore) / totalLpBefore;
        }

        if (shares == 0) revert ZeroAmount();

        totalLpManaged           += lpAmount;
        lastDepositTime[msg.sender] = block.timestamp;
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, lpAmount, shares);
    }

    /// @notice Burn shares, receive LP minus withdrawal fee.
    ///         Always available — even when paused — so users are never locked.
    /// @param shares  Vault shares to burn
    /// @return lpOut  LP tokens returned after fee
    function withdraw(uint256 shares)
        external
        nonReentrant
        returns (uint256 lpOut)
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 lpGross = (shares * totalLpManaged) / totalSupply();
        if (lpGross == 0) revert ZeroAmount();

        uint256 withdrawFee = (lpGross * withdrawFeeBps) / BPS_DENOMINATOR;
        lpOut = lpGross - withdrawFee;

        // CEI: state updates before external calls
        _burn(msg.sender, shares);
        totalLpManaged -= lpGross;

        gauge.withdraw(lpGross);

        if (withdrawFee > 0) {
            lpToken.safeTransfer(factory.feeRecipient(), withdrawFee);
            totalWithdrawFeesCollected += withdrawFee;
        }

        lpToken.safeTransfer(msg.sender, lpOut);

        emit Withdrawn(msg.sender, shares, lpOut, withdrawFee);
    }

    /// @notice Emergency withdraw — no fee, but only available when vault is paused
    ///         and caller has not deposited in the last 24 hours.
    ///
    ///         The pause requirement means this can only be triggered by the owner
    ///         in a genuine emergency, preventing fee-dodge abuse.
    ///         The 24h cooldown prevents deposit-then-immediate-emergency-withdraw exploits.
    ///
    /// @param shares  Vault shares to burn
    /// @return lpOut  LP tokens returned (no fee)
    function emergencyWithdraw(uint256 shares)
        external
        nonReentrant
        returns (uint256 lpOut)
    {
        if (!paused()) revert VaultNotPaused();
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        if (block.timestamp < lastDepositTime[msg.sender] + EMERGENCY_WITHDRAW_COOLDOWN)
            revert EmergencyWithdrawCooldown();

        lpOut = (shares * totalLpManaged) / totalSupply();
        if (lpOut == 0) revert ZeroAmount();

        _burn(msg.sender, shares);
        totalLpManaged -= lpOut;

        gauge.withdraw(lpOut);
        lpToken.safeTransfer(msg.sender, lpOut);

        emit EmergencyWithdrawn(msg.sender, shares, lpOut);
    }

    // ── Keeper Functions ──────────────────────────────────────

    /// @notice Harvest AERO rewards and compound back to LP.
    ///         Enforces on-chain profitability: reward value must be ≥ 5× estimated gas cost.
    ///         Caller must be keeper or owner.
    /// @param minToken0Out Min token0 received from swap (slippage, computed off-chain)
    /// @param minToken1Out Min token1 received from swap (slippage, computed off-chain)
    function harvest(uint256 minToken0Out, uint256 minToken1Out)
        external
        nonReentrant
        whenNotPaused
        onlyKeeper
    {
        address aeroAddr = factory.aeroToken();

        // 1. Claim AERO from gauge
        gauge.getReward(address(this));

        uint256 aeroBalance = IERC20(aeroAddr).balanceOf(address(this));
        if (aeroBalance < MIN_HARVEST_AMOUNT) revert HarvestAmountTooLow();

        // 2. On-chain profitability guard
        //    Uses spot AERO/WETH price from router — acts as a backstop against
        //    direct harvest() calls that bypass the keeper's off-chain check.
        _assertProfitable(aeroBalance);

        // 3. Take performance fee in AERO
        uint256 feeAmount = (aeroBalance * perfFeeBps) / BPS_DENOMINATOR;
        if (feeAmount > 0) {
            IERC20(aeroAddr).safeTransfer(factory.feeRecipient(), feeAmount);
            totalFeesCollected += feeAmount;
        }

        uint256 aeroToCompound = aeroBalance - feeAmount;

        // 4. Swap → addLiquidity → restake
        uint256 newLp = _swapAndCompound(aeroToCompound, minToken0Out, minToken1Out);

        // 5. Sweep leftover token dust to feeRecipient
        _sweepDust();

        lastHarvestTimestamp = block.timestamp;
        emit Harvested(aeroBalance, feeAmount, newLp, block.timestamp);
    }

    // ── Internal: Harvest Helpers ─────────────────────────────

    /// @dev Verifies reward value ≥ MIN_PROFIT_MULTIPLIER × estimated gas cost.
    ///      Uses a single-hop AERO→WETH spot quote. Not a TWAP — manipulation
    ///      resistance relies on onlyKeeper restricting who can call harvest().
    function _assertProfitable(uint256 aeroAmount) internal view {
        address weth = factory.weth();

        // Build a single-hop AERO→WETH price route
        IAerodromeRouter.Route[] memory priceRoute = new IAerodromeRouter.Route[](1);
        priceRoute[0] = IAerodromeRouter.Route({
            from:    factory.aeroToken(),
            to:      weth,
            stable:  false,
            factory: poolFactory
        });

        uint256[] memory amounts = IAerodromeRouter(factory.router()).getAmountsOut(aeroAmount, priceRoute);
        uint256 rewardValueWei   = amounts[amounts.length - 1];
        uint256 gasCostWei       = tx.gasprice * HARVEST_GAS_ESTIMATE;

        if (rewardValueWei < gasCostWei * MIN_PROFIT_MULTIPLIER) revert HarvestNotProfitable();
    }

    /// @dev Swaps AERO → token0 and token1, adds liquidity, restakes.
    ///      Split into its own function to reduce stack depth in harvest().
    function _swapAndCompound(
        uint256 aeroToCompound,
        uint256 minToken0Out,
        uint256 minToken1Out
    ) internal returns (uint256 newLp) {
        IAerodromeRouter router   = IAerodromeRouter(factory.router());
        uint256 aeroHalf = aeroToCompound / 2;

        uint256 amount0 = _swap(router, swapPathToken0, aeroHalf,                    minToken0Out);
        uint256 amount1 = _swap(router, swapPathToken1, aeroToCompound - aeroHalf,   minToken1Out);

        (,, newLp) = router.addLiquidity(
            token0, token1, isStable,
            amount0, amount1,
            (amount0 * (BPS_DENOMINATOR - ADD_LIQ_SLIPPAGE_BPS)) / BPS_DENOMINATOR,
            (amount1 * (BPS_DENOMINATOR - ADD_LIQ_SLIPPAGE_BPS)) / BPS_DENOMINATOR,
            address(this),
            block.timestamp
        );

        if (newLp > 0) {
            gauge.deposit(newLp);
            totalLpManaged         += newLp;
            totalRewardsCompounded += aeroToCompound;
        }
    }

    /// @dev Executes a multi-hop swap using a stored Route[] path.
    ///      If path[0].from == path[0].to (i.e. token is AERO itself), returns amountIn directly.
    function _swap(
        IAerodromeRouter router,
        IAerodromeRouter.Route[] storage path,
        uint256          amountIn,
        uint256          minOut
    ) internal returns (uint256) {
        // If target token is AERO itself, no swap needed
        if (path[path.length - 1].to == path[0].from) return amountIn;

        // Copy storage path to memory for router call
        IAerodromeRouter.Route[] memory memPath = new IAerodromeRouter.Route[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            memPath[i] = path[i];
        }

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn, minOut, memPath, address(this), block.timestamp
        );
        return amounts[amounts.length - 1];
    }

    /// @dev Sweeps residual token0/token1 dust to feeRecipient after addLiquidity.
    function _sweepDust() internal {
        address recipient = factory.feeRecipient();
        uint256 dust0 = IERC20(token0).balanceOf(address(this));
        uint256 dust1 = IERC20(token1).balanceOf(address(this));
        if (dust0 > 0) IERC20(token0).safeTransfer(recipient, dust0);
        if (dust1 > 0) IERC20(token1).safeTransfer(recipient, dust1);
    }

    // ── Internal: Path Helpers ────────────────────────────────

    /// @dev Validates a swap path:
    ///      - Length 1..MAX_PATH_LENGTH
    ///      - Starts with AERO
    ///      - Ends with expectedOut
    ///      - All hops use canonical poolFactory
    ///      - All pools exist
    ///      - Path is continuous (hop[i].to == hop[i+1].from)
    function _validatePath(IAerodromeRouter.Route[] calldata path, address expectedOut) internal view {
        if (path.length == 0 || path.length > MAX_PATH_LENGTH) revert InvalidPath();

        // Identity path: AERO→AERO means this token IS AERO, no swap needed.
        // Only valid when expectedOut is also AERO.
        if (path.length == 1 && path[0].from == path[0].to) {
            if (path[0].from != factory.aeroToken()) revert InvalidPath();
            if (expectedOut  != factory.aeroToken()) revert InvalidPath();
            return;
        }

        if (path[0].from != factory.aeroToken()) revert InvalidPath();
        if (path[path.length - 1].to != expectedOut) revert InvalidPath();

        for (uint256 i = 0; i < path.length; i++) {
            if (path[i].factory != poolFactory) revert NonCanonicalFactory();

            address pool = IPoolFactory(poolFactory).getPool(
                path[i].from,
                path[i].to,
                path[i].stable
            );
            if (pool == address(0)) revert PoolDoesNotExist();

            if (i < path.length - 1) {
                if (path[i].to != path[i + 1].from) revert InvalidPath();
            }
        }
    }

    /// @dev Copies a calldata Route[] into a storage Route[].
    function _storePath(IAerodromeRouter.Route[] storage dest, IAerodromeRouter.Route[] calldata src) internal {
        for (uint256 i = 0; i < src.length; i++) {
            dest.push(src[i]);
        }
    }

    // ── Admin Functions ───────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Update performance fee. Hard-capped at MAX_PERF_FEE_BPS (2%).
    function setPerfFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_PERF_FEE_BPS) revert FeeTooHigh();
        perfFeeBps = _feeBps;
        emit PerfFeeBpsUpdated(_feeBps);
    }

    /// @notice Update withdrawal fee. Hard-capped at MAX_WITHDRAW_FEE_BPS (1%).
    function setWithdrawFeeBps(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_WITHDRAW_FEE_BPS) revert FeeTooHigh();
        withdrawFeeBps = _feeBps;
        emit WithdrawFeeBpsUpdated(_feeBps);
    }

    /// @notice Update swap paths. Paths are re-validated on every update.
    function setSwapPaths(
        IAerodromeRouter.Route[] calldata _pathToken0,
        IAerodromeRouter.Route[] calldata _pathToken1
    ) external onlyOwner {
        _validatePath(_pathToken0, token0);
        _validatePath(_pathToken1, token1);

        // Clear existing paths
        delete swapPathToken0;
        delete swapPathToken1;

        _storePath(swapPathToken0, _pathToken0);
        _storePath(swapPathToken1, _pathToken1);

        emit SwapPathsUpdated();
    }

    /// @notice Recover accidentally sent tokens. Cannot touch LP or AERO.
    function recoverToken(address token, uint256 amount) external onlyOwner {
        if (token == address(lpToken))    revert();
        if (token == factory.aeroToken()) revert();
        IERC20(token).safeTransfer(factory.owner(), amount);
    }

    // ── View Functions ────────────────────────────────────────

    function getLpForShares(uint256 shares) external view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return (shares * totalLpManaged) / totalSupply();
    }

    function pricePerShare() external view returns (uint256) {
        if (totalSupply() == 0) return 1e18;
        return (totalLpManaged * 1e18) / totalSupply();
    }

    function pendingRewards() external view returns (uint256) {
        return gauge.earned(address(this));
    }

    function totalStaked() external view returns (uint256) {
        return gauge.balanceOf(address(this));
    }

    function getSwapPathToken0() external view returns (IAerodromeRouter.Route[] memory) {
        return swapPathToken0;
    }

    function getSwapPathToken1() external view returns (IAerodromeRouter.Route[] memory) {
        return swapPathToken1;
    }
}
