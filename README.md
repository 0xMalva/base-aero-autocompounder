# AeroCompounder Contracts

Auto-compounding vault infrastructure for Aerodrome LP positions on Base.

Website
https://aerocompounder.com

---

## Overview

AeroCompounder provides automated yield compounding for Aerodrome liquidity providers.
Deposited LP tokens are staked in Aerodrome gauges, rewards are harvested, swapped back into the underlying pool assets, and liquidity is re-added to increase the position over time.

Vault shares are represented by ERC-20 tokens that track a proportional claim on the vault’s underlying LP position.

---

## Deployed Contracts

Network: Base
Chain ID: 8453

VaultFactoryV2
0x1cBb85b82076650CE3075133b7DfEa6151122819

AutoCompounderV2 Implementation
0x1CEEb2e03d55A3260B73f57e6686661d654bBe60

VaultFactoryV2 deploys vaults as minimal proxy clones of the AutoCompounderV2 implementation.

---

## Architecture

AeroCompounder uses a factory-based vault architecture.

User → Vault Clone → Aerodrome Gauge

### VaultFactoryV2

Responsible for:

* Deploying vaults using EIP-1167 minimal proxy clones
* Maintaining the registry of deployed vaults
* Managing keeper and fee recipient addresses
* Enforcing unique LP vaults

### AutoCompounderV2

Vault implementation that:

* Accepts LP token deposits
* Stakes LP tokens into Aerodrome gauges
* Harvests AERO rewards
* Swaps rewards into pool tokens
* Adds liquidity and restakes LP tokens
* Issues ERC20 vault shares to depositors

Each vault corresponds to a single Aerodrome LP pair.

---

## Key Features

### Minimal Proxy Vaults

Vaults are deployed using the EIP-1167 clone pattern for gas efficiency.

### Multi-Hop Swap Paths

Rewards can be swapped through configurable routes before liquidity is added.

### Keeper-Based Harvesting

Harvest execution is restricted to the keeper or owner to prevent griefing.

### On-Chain Profitability Check

Harvests must exceed a minimum profitability threshold relative to gas cost.

### Emergency Withdraw Protection

Emergency withdraw requires:

* vault pause
* 24-hour deposit cooldown

This prevents fee-avoidance exploits.

### Hard-Capped Fees

Performance fee: maximum 2%
Withdrawal fee: maximum 1%

Fee limits are enforced in contract code.

---

## Security Considerations

The system includes multiple safety mechanisms:

* Reentrancy protection
* Pausable vaults
* Profitability guard on harvest
* Swap path validation
* Canonical pool verification
* Emergency withdrawal restrictions

Users should always verify contract addresses before interacting.

---

## Repository Structure

src/

AutoCompounderV2.sol
VaultFactoryV2.sol

interfaces/

IAerodromeRouter.sol
IVaultFactory.sol

---

## Development

The contracts use Foundry.

Build

forge build

Test

forge test

---

## License

MIT
