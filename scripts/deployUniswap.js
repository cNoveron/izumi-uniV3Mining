const hardhat = require("hardhat");
const BigNumber = require("bignumber.js");
const uniV3 = require("../test/uniswap/deployUniV3.js");

async function main() {

  const [signer, miner1, miner2, trader, tokenAProvider, tokenBProvider] = await ethers.getSigners();

  // a fake weth
  const tokenFactory = await ethers.getContractFactory("TestToken");
  const weth = await tokenFactory.deploy('weth', 'weth', 18);
  const wethAddr = weth.address;

  const deployed = await uniV3.deployUniV3(wethAddr, signer);
  const uniFactory = deployed.uniFactory;
  const uniSwapRouter = deployed.uniSwapRouter;
  const uniPositionManager = deployed.uniPositionManager;

  const [tokenX, tokenY] = await getToken();
  const sqrtPriceX_96 = "0x2000000000000000000000000";
  await uniPositionManager.createAndInitializePoolIfNecessary(tokenX.address, tokenY.address, "3000", sqrtPriceX_96);

  var tokenA = await deployToken("a", "a", 18);
  var tokenB = await deployToken('b', 'b', 18);

  const rewardInfoA = {
    rewardToken: tokenA.address,
    provider: tokenAProvider.address,
    rewardPerBlock: "30000000000000",
    accRewardPerShare: "0",
  }
  const rewardInfoB = {
    rewardToken: tokenB.address,
    provider: tokenBProvider.address,
    rewardPerBlock: "60000000000000",
    accRewardPerShare: "0",
  }

  const startBlock = "0";
  const endBlock = "10000000000000000000";

  const q128 = BigNumber("2").pow(128);

  const rewardLowerTick = '-5000';
  const rewardUpperTick = '50000';

  mining2RewardNoBoost = await deployMining(uniPositionManager, tokenX, tokenY, "3000",
    [rewardInfoA, rewardInfoB], "0x0000000000000000000000000000000000000000", rewardUpperTick, rewardLowerTick,
    startBlock, endBlock
  );
  console.log("a");

  await setProvideer(mining2RewardNoBoost, tokenA, tokenAProvider, "1000000000000000000000000");
  console.log("b");
  await setProvideer(mining2RewardNoBoost, tokenB, tokenBProvider, "1000000000000000000000000");
  console.log("c");

}

async function deployMining(
  uniNFTManager, token0, token1, fee, rewardInfos,
  iziTokenAddr, upperTick, lowerTick, startBlock, endBlock) {
  const MiningFactory = await ethers.getContractFactory('MiningFixRangeBoost');
  var mining = await MiningFactory.deploy(
    uniNFTManager.address, token0.address, token1.address, fee,
    rewardInfos, iziTokenAddr, upperTick, lowerTick, startBlock, endBlock);
  await mining.deployed();
  return mining;
}

async function deployToken(name, symbol, decimals) {
  var tokenFactory = await ethers.getContractFactory("TestToken");
  var token = await tokenFactory.deploy(name, symbol, decimals);
  return token;
}

async function getToken() {

  // deploy token
  const tokenFactory = await ethers.getContractFactory("TestToken")
  tokenX = await tokenFactory.deploy('a', 'a', 18);
  await tokenX.deployed();
  tokenY = await tokenFactory.deploy('b', 'b', 18);
  await tokenY.deployed();

  txAddr = tokenX.address.toLowerCase();
  tyAddr = tokenY.address.toLowerCase();

  if (txAddr > tyAddr) {
    tmpAddr = tyAddr;
    tyAddr = txAddr;
    txAddr = tmpAddr;

    tmpToken = tokenY;
    tokenY = tokenX;
    tokenX = tmpToken;
  }
  return [tokenX, tokenY];
}

async function setProvideer(mining, token, provider, amount) {
  await token.transfer(provider.address, amount);
  await token.connect(provider).approve(mining.address, amount);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });