// .thirdweb.config.ts
import { defineThirdwebConfig } from "thirdweb";

export default defineThirdwebConfig({
  contracts: [
    {
      name: "AbokiV2Contract",
      constructorParams: ["0xD0A2362c6cF02f8FdaCD3E2aBCbfBc625AA0f967"],
    },
  ],
  chain: {
    id: 8453, // Base Mainnet
    name: "Base",
    nativeCurrency: {
      name: "Ether",
      symbol: "ETH",
      decimals: 18,
    },
    rpc: ["https://mainnet.base.org"],
  },
});
