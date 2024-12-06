const { ethers, upgrades } = require("hardhat");

async function main() {
  const VerisenseMiddleware = await ethers.getContractFactory("VerisenseMiddleware");
  const verisenseMiddleware = await upgrades.deployProxy(VerisenseMiddleware, [

      "0xa716B14513aF687B2ce2ED83775b4e2a04e5AfC8", //network
      "0x6F75a4ffF97326A00e52662d82EA4FdE86a2C548", //operatorRegister
      "0x407A039D94948484D356eFB765b3c74382A050B4", //vaultfactory
      "0x58973d16FFA900D11fC22e5e2B6840d9f7e13401", //operator net opt in
      86400,
      86400,
  ]);
  await verisenseMiddleware.waitForDeployment();
  console.log("VerisenseMiddleware deployed to:", await verisenseMiddleware.getAddress());
}
main();
