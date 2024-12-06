
const { ethers, upgrades } = require("hardhat");

async function main() {
  const VerisenseMiddleware = await ethers.getContractFactory("VerisenseMiddleware");
  console.log("recreate network file ...");
  const r = await upgrades.forceImport(process.env.PROXY, VerisenseMiddleware);
  console.log("Verisense upgraded successfully address: ", await r.getAddress());
}

main();