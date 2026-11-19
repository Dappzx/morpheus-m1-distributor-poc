# M1 — Morpheus DistributorV2 yield-share manipulation via aToken donation

Foundry fork PoC for a yield-accounting issue in the Morpheus Capital contracts
([mor.org/bug-bounty](https://mor.org/bug-bounty), v2).

## The issue

`DistributorV2.distributeRewards()` measures each pool's yield as the raw balance
delta of its yield token (`balance_ - lastUnderlyingBalance`), with no check on
where the balance increase came from. A direct aToken transfer to the Distributor
is indistinguishable from genuine Aave interest, so it is counted as that pool's
yield and skews that day's fixed MOR emission toward the pool.

Attack: stake 2 wBTC in the (small) wBTC pool to become its dominant staker,
donate 0.0042 wBTC of aWBTC (~$263) directly to the Distributor, call the public
`distributeRewards(0)`, and claim the MOR after the 14-day claim lock.
Repeatable daily; the loss falls on the other stakers.

- Target: `DistributorV2` `0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A` (Ethereum
  mainnet), wBTC `DepositPool` `0xdE283F8309Fd1AA46c95d299f6B8310716277A42`,
  Aave v3 aWBTC `0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8`.
- Fork-measured at block 26450598: attacker pending MOR 0.0129 (control) →
  **626.04 MOR** (attack); wBTC pool share 1.35 → **884.55 MOR**. Net on-fork
  +$175.51 per distribution; live-adjusted ≈ +$89/day (~$32k/year).
- No privileged accounts are used anywhere. Fork only — no mainnet execution,
  no real funds.

## Run the PoC

One command, from a clean clone (forge-std is vendored in `lib/`, no setup
beyond an RPC URL):

```shell
forge test --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26450598 --match-contract M1YieldDonationTest
```

Expected: 2 tests pass (`test_yieldDonationSkewsMOR`, `test_claimEndToEnd`).
See `FORGE_TEST_OUTPUT.txt` for a recorded passing run.

Note: Chainlink feeds are frozen on a fork, so the test mocks only the
third-party feeds to re-serve their real live answers with a fresh `updatedAt`.
All Morpheus contracts run unmodified.
