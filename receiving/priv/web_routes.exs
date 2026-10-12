[
  %{
    path: "/supply-chain/receipts",
    live: Bilimbi.SupplyChain.Receiving.Web.ReceiptsLive,
    session: :auth,
    capability: "supply-chain.receiving.view"
  },
  %{
    path: "/supply-chain/receive",
    live: Bilimbi.SupplyChain.Receiving.Web.ReceiveLive,
    session: :auth,
    capability: "supply-chain.receiving.view"
  },
  %{
    path: "/supply-chain/receipts/:id",
    live: Bilimbi.SupplyChain.Receiving.Web.ReceiptLive,
    session: :auth,
    capability: "supply-chain.receiving.view"
  }
]
