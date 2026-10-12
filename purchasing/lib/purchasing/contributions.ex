defmodule Bilimbi.SupplyChain.Purchasing.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The Authz domain is "supply-chain": a capability segment may not carry an
  # underscore, while the container ID and table prefix stay "supply_chain".
  @view "supply-chain.purchasing.view"
  @configure "supply-chain.purchasing.configuration.manage"
  @manage_requests "supply-chain.purchasing.requests.manage"
  @approve_requests "supply-chain.purchasing.requests.approve"
  @manage_orders "supply-chain.purchasing.orders.manage"
  @approve_orders "supply-chain.purchasing.orders.approve"
  @receive_orders "supply-chain.purchasing.orders.receive"

  @capabilities [
    @view,
    @configure,
    @manage_requests,
    @approve_requests,
    @manage_orders,
    @approve_orders,
    @receive_orders
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"supply-chain" => "Supply Chain domain modules"},
        verbs: ["receive"],
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        %{
          id: "supply_chain",
          label: "Supply chain",
          icon: "clipboard-document-list",
          parent: nil,
          route: nil,
          capability: nil,
          order: 55
        },
        %{
          id: "supply_chain.purchase_requests",
          label: "Purchase requests",
          parent: "supply_chain",
          route: "/supply-chain/purchase-requests",
          capability: @view,
          order: 10
        },
        %{
          id: "supply_chain.purchase_orders",
          label: "Purchase orders",
          parent: "supply_chain",
          route: "/supply-chain/purchase-orders",
          capability: @view,
          order: 20
        },
        %{
          id: "supply_chain.suppliers",
          label: "Suppliers",
          parent: "supply_chain",
          route: "/supply-chain/suppliers",
          capability: @view,
          order: 30
        }
      ]
    }
  end
end
