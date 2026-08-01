# Decentralized Stablecoin Engine

A minimal, exogenously-collateralized, algorithmically-stable stablecoin protocol built in Solidity with [Foundry](https://book.getfoundry.sh/). Conceptually similar to DAI, if DAI had no governance, no fees, and was backed only by WETH and WBTC.

## Protocol Properties

- **Exogenous Collateral** — backed by assets (ETH, BTC) whose value doesn't depend on the protocol's own token
- **Dollar Pegged** — targets a 1 DSC = 1 USD peg
- **Algorithmically Stable** — no governance, no fees; stability is enforced entirely by code
- **Always Overcollateralized** — the system enforces a 200% collateralization threshold; the value of deposited collateral must always exceed outstanding debt by that margin, or a position becomes eligible for liquidation

## Architecture

- **`DSCEngine.sol`** — core protocol logic: deposit/redeem collateral, mint/burn DSC, liquidations, health-factor calculations
- **`DecentralizedStableCoin.sol`** — the ERC-20 stablecoin itself (mint/burn access-controlled to the engine)
- **`library/OracleLib.sol`** — wraps Chainlink price feed calls with a staleness check; if a price feed hasn't updated within the threshold window, protocol functions relying on price data revert rather than operate on stale data

## Testing Approach

The test suite combines standard unit tests with property-based fuzz and invariant testing:

- **Unit tests** (`test/unit/`) — deposit, mint, burn, redeem, and liquidation flows, including revert conditions for zero amounts, unapproved collateral, and broken health factors
- **Stateful (invariant) fuzz testing** (`test/fuzz/`) — a `Handler` contract constrains the fuzzer to meaningful call sequences (bounded deposit sizes, valid user/collateral selection, liquidator solvency checks) across four invariants:
  - `invariant_protocolMustHaveMoreValueThanTotalSupply` — total collateral value never drops below total DSC in circulation
  - `invariant_debtShouldEqualActualTokenSupply` — the sum of tracked per-user debt always matches the token's actual total supply
  - `invariant_noUserWithDebtShouldEverHaveBrokenHealthFactor` — no user with outstanding debt ever ends a call sequence below the minimum health factor
  - `invariant_gettersShouldNotRevert` — all view functions remain callable regardless of protocol state

Each invariant runs 128 fuzz runs × 128 call depth (16,384 calls per invariant per test execution).

### Coverage

| File                          | Lines      | Statements | Branches   | Functions  |
| ----------------------------- | ---------- | ---------- | ---------- | ---------- |
| `DSCEngine.sol`               | 92.71%     | 94.44%     | 87.50%     | 87.50%     |
| `DecentralizedStableCoin.sol` | 100%       | 100%       | 100%       | 100%       |
| `library/OracleLib.sol`       | 100%       | 100%       | 100%       | 100%       |
| **Project total**             | **90.16%** | **92.74%** | **86.36%** | **82.61%** |

Lower coverage on `HelperConfig.s.sol` and test mocks is expected and by design — deployment/network configuration scripts and mock price feeds aren't security-relevant execution paths.

The one remaining uncovered branch in `DSCEngine.sol` is a defensive check (the mint-failure fallback) that isn't reachable through the token contract's actual mint semantics without altering that contract solely to force the test — left as deliberate defense-in-depth rather than an artificially-forced test path.

## Getting Started

```bash
forge install
forge build
forge test
forge coverage
```

To run only the invariant suite:
```bash
forge test --mt invariant -vv
```

## Author

Amer K.
