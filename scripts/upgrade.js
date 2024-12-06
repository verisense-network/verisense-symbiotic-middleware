const { ethers, upgrades } = require("hardhat");

async function main() {
  const VerisenseMiddleware = await ethers.getContractFactory("VerisenseMiddleware");
  console.log("Upgrading Verisense...");
  const r = await upgrades.upgradeProxy(process.env.PROXY, VerisenseMiddleware);
  console.log("VerisenseMiddleware upgraded successfully address: ", await r.getAddress());
}

main();
