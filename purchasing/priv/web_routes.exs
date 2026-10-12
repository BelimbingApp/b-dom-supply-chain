[
  %{
    path: "/supply-chain/suppliers",
    live: Bilimbi.SupplyChain.Purchasing.Web.SuppliersLive,
    session: :auth,
    capability: "supply-chain.purchasing.view"
  },
  %{
    path: "/supply-chain/purchase-requests",
    live: Bilimbi.SupplyChain.Purchasing.Web.RequestsLive,
    session: :auth,
    capability: "supply-chain.purchasing.view"
  },
  %{
    path: "/supply-chain/purchase-orders",
    live: Bilimbi.SupplyChain.Purchasing.Web.OrdersLive,
    session: :auth,
    capability: "supply-chain.purchasing.view"
  },
  %{
    path: "/supply-chain/purchase-orders/:id",
    live: Bilimbi.SupplyChain.Purchasing.Web.OrderLive,
    session: :auth,
    capability: "supply-chain.purchasing.view"
  }
]
