# StVault - Demonstration Security Review

A self-contained **demonstration** of a smart-contract security review: a deliberately
vulnerable lending vault, the real vulnerabilities it contains - each proven with a
passing [Foundry](https://book.getfoundry.sh) proof-of-concept - and a `fixed` branch
where the same PoCs confirm the remediation.

> ⚠️ **This is a demonstration on intentionally vulnerable code.** `StVault` was written
> to showcase audit methodology end to end. It is **not** production code, **not** a real
> client engagement, and must never be deployed. The findings are real vulnerabilities in
> this demo contract - not invented severities.

## Why this repo exists

Anyone can write "I audit smart contracts" in a bio. This repo shows the work instead:
a target, concrete findings, executable proofs, and a verified fix. Same principle as the
rest of my work - *if it isn't reproducible, it isn't done.*

## Repository layout

The review lives across two branches:

| Branch | Contents | What a green `forge test` means |
|--------|----------|---------------------------------|
| `master` | The vulnerable target + the PoC suite that **exploits** it | each attack **succeeds** → the vulnerability is reproduced |
| `fixed`  | The remediated contract + the **same** PoC scenarios | each attack now **reverts / is bounded** → the fix is verified |

- `src/StVault.sol` - the vault under review
- `test/StVault.poc.t.sol` - the proof-of-concept suite
- `StVault_Security_Review.pdf` - the full written report

## Findings

| ID | Severity | Summary |
|----|----------|---------|
| H-01 | High | Unvalidated Chainlink price - no staleness / sign / decimals checks; a stale answer enables over-borrowing and drains the pool |
| M-01 | Medium | Reentrancy in `withdrawCollateral` - missing guard + transfer-before-zero lets a hook token (ERC777/1363) drain collateral |
| L-01 | Low | Origination-fee rounding - division before multiplication truncates and under-charges the fee |

Impact analysis, code references, and recommendations are in the
[PDF report](./StVault_Security_Review.pdf).

## Reproduce it

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone https://github.com/Musyg/stvault-audit.git
cd stvault-audit
forge install        # fetches OpenZeppelin + forge-std (git submodules)

# master - exploits succeed, demonstrating each vulnerability
forge test -vv

# fixed - the same attacks now fail
git checkout fixed
forge test -vv
```

## How severity is rated

Each finding is rated **Impact × Likelihood**, following industry conventions
(Immunefi / Sherlock-style). Severity reflects the *nature* of the impact and the
*share of funds at risk* - never a flat dollar amount. Every finding is quantified
and backed by a reproducible PoC.

## About

Built by Gilles Musy ([@Musyg](https://github.com/Musyg)), independent smart-contract
security researcher, with competition findings on Code4rena and Cantina.

## License

[MIT](./LICENSE).
