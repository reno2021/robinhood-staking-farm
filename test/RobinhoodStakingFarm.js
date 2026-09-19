import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();
const { loadFixture } = networkHelpers;
const { time } = networkHelpers;

const DAY = 24 * 60 * 60;
const TIER_DURATIONS = [0, 3 * DAY, 7 * DAY, 30 * DAY, 60 * DAY, 90 * DAY, 365 * DAY, 1460 * DAY];
const TIER_MULTIPLIERS = [10000, 11000, 12500, 15000, 17500, 20000, 26000, 35000];
const EARLY_FEE_BPS = 970n;
const BPS = 10000n;

async function deployFixture() {
  const [owner, admin, alice, bob, carol] = await ethers.getSigners();

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const lpToken = await MockERC20.deploy("LP Token", "LPT", 18);
  const rewardToken = await MockERC20.deploy("Reward Token", "RWD", 18);
  const bonusToken = await MockERC20.deploy("Bonus Token", "BON", 18);

  const Farm = await ethers.getContractFactory("RobinhoodStakingFarm");
  const farm = await Farm.deploy(owner.address, admin.address);

  await farm.addPool(
    await lpToken.getAddress(),
    await rewardToken.getAddress(),
    await bonusToken.getAddress(),
    ethers.parseEther("1"),
    TIER_DURATIONS,
    TIER_MULTIPLIERS,
    false
  );

  const mintAmount = ethers.parseEther("1000000");
  for (const signer of [owner, alice, bob, carol]) {
    await lpToken.mint(signer.address, mintAmount);
    await rewardToken.mint(signer.address, mintAmount);
    await bonusToken.mint(signer.address, mintAmount);
  }

  for (const signer of [owner, alice, bob, carol]) {
    await lpToken.connect(signer).approve(await farm.getAddress(), mintAmount);
    await rewardToken.connect(signer).approve(await farm.getAddress(), mintAmount);
    await bonusToken.connect(signer).approve(await farm.getAddress(), mintAmount);
  }

  return { farm, lpToken, rewardToken, bonusToken, owner, admin, alice, bob, carol };
}

describe("RobinhoodStakingFarm", function () {
  it("stores all supported default tiers and computes unlock times per tier", async function () {
    const { farm, alice } = await loadFixture(deployFixture);
    for (let tierId = 0; tierId < TIER_DURATIONS.length; tierId++) {
      const tier = await farm.getTier(0, tierId);
      expect(tier.lockDuration).to.equal(TIER_DURATIONS[tierId]);
      expect(tier.rewardMultiplierBps).to.equal(TIER_MULTIPLIERS[tierId]);

      await farm.connect(alice).deposit(0, tierId, 1000n + BigInt(tierId));
      const position = await farm.getPosition(0, alice.address, tierId);
      expect(position.unlockAt).to.equal(position.depositedAt + BigInt(TIER_DURATIONS[tierId]));
    }
  });

  it("handles multiple positions across tiers with funded rewards", async function () {
    const { farm, rewardToken, owner, alice, bob } = await loadFixture(deployFixture);
    const funding = ethers.parseEther("1000");

    await farm.connect(alice).deposit(0, 0, ethers.parseEther("100"));
    await farm.connect(alice).deposit(0, 3, ethers.parseEther("100"));
    await farm.connect(bob).deposit(0, 3, ethers.parseEther("100"));
    await farm.connect(owner).fundRewards(0, funding);

    const rewardCheckpoint = await time.latest();
    await time.increaseTo(rewardCheckpoint + 10);

    const pendingFlexible = await farm.pendingRewards(0, alice.address, 0);
    const pendingThirtyDayAlice = await farm.pendingRewards(0, alice.address, 1);
    const pendingThirtyDayBob = await farm.pendingRewards(0, bob.address, 0);

    expect(pendingFlexible.rewardAmount).to.equal(ethers.parseEther("10"));
    expect(pendingThirtyDayAlice.rewardAmount).to.equal(ethers.parseEther("7.5"));
    expect(pendingThirtyDayBob.rewardAmount).to.equal(ethers.parseEther("7.5"));

    await time.setNextBlockTimestamp((await time.latest()) + 1);
    const before = await rewardToken.balanceOf(alice.address);
    await farm.connect(alice).claimMany(0, [0, 1]);
    const after = await rewardToken.balanceOf(alice.address);
    expect(after - before).to.equal(ethers.parseEther("19.25"));
  });

  it("does not accrue historical rewards while there are no stakers", async function () {
    const { farm, rewardToken, owner, alice } = await loadFixture(deployFixture);
    await farm.connect(owner).fundRewards(0, ethers.parseEther("100"));
    await time.increase(100);

    await farm.connect(alice).deposit(0, 0, ethers.parseEther("50"));
    let pending = await farm.pendingRewards(0, alice.address, 0);
    expect(pending.rewardAmount).to.equal(0);

    const postDepositCheckpoint = await time.latest();
    await time.increaseTo(postDepositCheckpoint + 10);
    pending = await farm.pendingRewards(0, alice.address, 0);
    expect(pending.rewardAmount).to.equal(ethers.parseEther("10"));

    await time.setNextBlockTimestamp((await time.latest()) + 1);
    const before = await rewardToken.balanceOf(alice.address);
    await farm.connect(alice).claim(0, 0);
    const after = await rewardToken.balanceOf(alice.address);
    expect(after - before).to.equal(ethers.parseEther("11"));
  });

  it("charges the early withdrawal fee before maturity and sends it to the admin wallet", async function () {
    const { farm, lpToken, owner, admin, alice } = await loadFixture(deployFixture);
    await farm.connect(owner).fundRewards(0, ethers.parseEther("10"));
    const depositAmount = ethers.parseEther("100");
    await farm.connect(alice).deposit(0, 3, depositAmount);

    const adminBefore = await lpToken.balanceOf(admin.address);
    const aliceBefore = await lpToken.balanceOf(alice.address);

    await time.increase(5 * DAY);
    await farm.connect(alice).withdraw(0, 0, depositAmount);

    const expectedFee = (depositAmount * EARLY_FEE_BPS) / BPS;
    const expectedNet = depositAmount - expectedFee;

    const adminAfter = await lpToken.balanceOf(admin.address);
    const aliceAfter = await lpToken.balanceOf(alice.address);

    expect(adminAfter - adminBefore).to.equal(expectedFee);
    expect(aliceAfter - aliceBefore).to.equal(expectedNet);
  });

  it("does not charge the early withdrawal fee after maturity", async function () {
    const { farm, lpToken, alice } = await loadFixture(deployFixture);
    const depositAmount = ethers.parseEther("25");
    await farm.connect(alice).deposit(0, 1, depositAmount);

    const before = await lpToken.balanceOf(alice.address);
    await time.increase(3 * DAY + 1);
    await farm.connect(alice).withdraw(0, 0, depositAmount);
    const after = await lpToken.balanceOf(alice.address);

    expect(after - before).to.equal(depositAmount);
  });

  it("distributes explicit bonus funding pro rata across stakers", async function () {
    const { farm, bonusToken, owner, alice, bob } = await loadFixture(deployFixture);
    await farm.connect(alice).deposit(0, 0, ethers.parseEther("100"));
    await farm.connect(bob).deposit(0, 7, ethers.parseEther("300"));

    await farm.connect(owner).distributeBonusRewards(0, ethers.parseEther("40"));

    const alicePending = await farm.pendingRewards(0, alice.address, 0);
    const bobPending = await farm.pendingRewards(0, bob.address, 0);
    expect(alicePending.bonusAmount).to.equal(ethers.parseEther("10"));
    expect(bobPending.bonusAmount).to.equal(ethers.parseEther("30"));

    const before = await bonusToken.balanceOf(bob.address);
    await farm.connect(bob).claim(0, 0);
    const after = await bonusToken.balanceOf(bob.address);
    expect(after - before).to.equal(ethers.parseEther("30"));
  });

  it("supports pool admin controls and pause behavior without trapping withdrawals", async function () {
    const { farm, lpToken, rewardToken, bonusToken, owner, alice } = await loadFixture(deployFixture);
    await expect(
      farm.addPool(
        await lpToken.getAddress(),
        await rewardToken.getAddress(),
        await rewardToken.getAddress(),
        1,
        TIER_DURATIONS,
        TIER_MULTIPLIERS,
        false
      )
    ).to.be.revertedWith("duplicate lp pool");

    await farm.connect(alice).deposit(0, 0, 1000);
    await farm.connect(owner).setPoolPaused(0, true);
    await expect(farm.connect(alice).deposit(0, 0, 1000)).to.be.revertedWith("pool is paused");

    await farm.connect(owner).pause();
    await expect(farm.connect(owner).fundRewards(0, 1)).to.be.revertedWithCustomError(farm, "EnforcedPause");

    await farm.connect(alice).withdraw(0, 0, 1000);
    await farm.connect(owner).unpause();
    await farm.connect(owner).setPoolPaused(0, false);
    await farm.connect(owner).setPoolRewardToken(0, await rewardToken.getAddress());
    await farm.connect(owner).setPoolBonusToken(0, await bonusToken.getAddress());
  });

  it("prevents changing lock duration after a tier has been used", async function () {
    const { farm, owner, alice } = await loadFixture(deployFixture);
    await farm.connect(alice).deposit(0, 2, 1000);

    await expect(farm.connect(owner).setTierConfig(0, 2, 14 * DAY, TIER_MULTIPLIERS[2], true)).to.be.revertedWith(
      "lock duration immutable"
    );
  });

  it("caps rewards to funded balances and allows token changes only after positions are cleared", async function () {
    const { farm, rewardToken, bonusToken, owner, alice } = await loadFixture(deployFixture);
    await farm.connect(owner).setPoolRewardPerSecond(0, ethers.parseEther("10"));
    await farm.connect(owner).fundRewards(0, ethers.parseEther("15"));
    await farm.connect(alice).deposit(0, 0, ethers.parseEther("1"));

    await time.increase(10);
    const pending = await farm.pendingRewards(0, alice.address, 0);
    expect(pending.rewardAmount).to.equal(ethers.parseEther("15"));

    await expect(farm.connect(owner).setPoolRewardToken(0, await bonusToken.getAddress())).to.be.revertedWith(
      "active stake exists"
    );

    await farm.connect(alice).withdraw(0, 0, ethers.parseEther("1"));
    const balance = await farm.getPool(0);
    expect(balance.rewardBalance).to.equal(0);

    await farm.connect(owner).setPoolRewardToken(0, await bonusToken.getAddress());
    const updated = await farm.getPool(0);
    expect(updated.rewardToken).to.equal(await bonusToken.getAddress());
  });

  it("blocks reentrancy during LP withdrawals with a callback-capable token", async function () {
    const [owner, admin] = await ethers.getSigners();
    const CallbackERC20 = await ethers.getContractFactory("CallbackERC20");
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const Farm = await ethers.getContractFactory("RobinhoodStakingFarm");
    const Attacker = await ethers.getContractFactory("ReentrantWithdrawer");

    const lpToken = await CallbackERC20.deploy("Callback LP", "cLP");
    const rewardToken = await MockERC20.deploy("Reward", "RWD", 18);
    const bonusToken = await MockERC20.deploy("Bonus", "BON", 18);
    const farm = await Farm.deploy(owner.address, admin.address);

    await farm.addPool(
      await lpToken.getAddress(),
      await rewardToken.getAddress(),
      await bonusToken.getAddress(),
      0,
      TIER_DURATIONS,
      TIER_MULTIPLIERS,
      false
    );

    const attacker = await Attacker.deploy(await farm.getAddress(), await lpToken.getAddress());
    await lpToken.mint(await attacker.getAddress(), ethers.parseEther("10"));
    await attacker.deposit(0, 0, ethers.parseEther("10"));

    await attacker.attackWithdraw(0, 0, ethers.parseEther("10"));
    expect(await attacker.attackAttempted()).to.equal(true);
    expect(await attacker.reentrancySucceeded()).to.equal(false);
    expect(await lpToken.balanceOf(await attacker.getAddress())).to.equal(ethers.parseEther("10"));
  });
});
