# AeroCompounder Contracts

Official smart contracts for **AeroCompounder** — automated yield compounding for Aerodrome LP positions on Base.

Website
https://aerocompounder.com

![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Network](https://img.shields.io/badge/network-Base-blue)

---

## Overview

AeroCompounder provides automated yield compounding for Aerodrome liquidity providers.

Deposited LP tokens are staked in Aerodrome gauges. Rewards are harvested, swapped back into the underlying pool assets, and liquidity is re-added to increase the LP position over time.

Vault shares are represented by ERC-20 tokens that track a proportional claim on the vault’s underlying LP position.

---

## Deployed Contracts

Network: **Base**
Chain ID: **8453**

VaultFactoryV2
https://basescan.org/address/0x1cBb85b82076650CE3075133b7DfEa6151122819

AutoCompounderV2 Implementation
https://basescan.org/address/0x1CEEb2e03d55A3260B73f57e6686661d654bBe60

VaultFactoryV2 deploys vaults as minimal proxy clones of the AutoCompounderV2 implementation using the EIP-1167 proxy pattern.

---

## Architecture

AeroCompounder uses a factory-based vault architecture.

User → Vault Clone → Aerodrome Gauge → Compounding → LP Growth

### VaultFactoryV2

Responsible for:

• Deploying vaults using EIP-1167 minimal proxy clones
• Maintaining the registry of deployed vaults
• Managing keeper and fee recipient addresses
• Enforcing unique LP vaults

### AutoCompounderV2

Vault implementation that:

• Accepts LP token deposits
• Stakes LP tokens into Aerodrome gauges
• Harvests AERO rewards
• Swaps rewards into pool tokens
• Adds liquidity and restakes LP tokens
• Issues ERC20 vault shares to depositors

Each vault corresponds to a single Aerodrome LP pair.

---

## Key Features

### Minimal Proxy Vaults

Vaults are deployed using the **EIP-1167 clone pattern**, allowing efficient deployment of new vaults while reusing the same implementation contract.

### Multi-Hop Swap Paths

Reward tokens can be swapped through configurable multi-hop routes before liquidity is added.

### Keeper-Based Harvesting

Harvest execution is restricted to the protocol keeper or owner to prevent griefing and inefficient harvest calls.

### On-Chain Profitability Check

Harvests must exceed a minimum profitability threshold relative to estimated gas cost before execution.

### Emergency Withdraw Protection

Emergency withdrawals require:

• the vault to be paused
• a 24-hour cooldown after the last deposit

This prevents fee-avoidance exploits while still allowing recovery during emergencies.

### Hard-Capped Fees

Performance fee: **maximum 2%**
Withdrawal fee: **maximum 1%**

Fee caps are enforced directly in contract code.

---

## Security Considerations

The system includes multiple safety mechanisms:

• Reentrancy protection
• Pausable vaults
• On-chain harvest profitability guard
• Swap path validation
• Canonical pool verification
• Emergency withdrawal cooldowns

Users should always verify contract addresses before interacting.

---

## Repository Structure

```
src/
  AutoCompounderV2.sol
  VaultFactoryV2.sol

src/interfaces/
  IAerodromeRouter.sol
  IVaultFactory.sol
```

---

## Development

Contracts are built using Foundry.

Build

```
forge build
```

Run tests

```
forge test
```

---

## Links

Website
https://aerocompounder.com

GitHub
https://github.com/0xMalva/base-aero-autocompounder

---

## License

MIT
