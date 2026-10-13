defmodule Bilimbi.SupplyChain.Receiving.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The Authz domain is "supply-chain", declared by Purchasing with the same
  # description; a capability segment may not carry an underscore. Each verb
  # is owned by exactly one mounted Domain, and Finance's ledger owns "post",
  # so this module's verb is "post-receipt": posting a receipt, or the
  # reversal of one. Declaring "post" here refuses the host's boot.
  @view "supply-chain.receiving.view"
  @configure "supply-chain.receiving.configuration.manage"
  @manage_receipts "supply-chain.receiving.receipts.manage"
  @post_receipts "supply-chain.receiving.receipts.post-receipt"

  @capabilities [@view, @configure, @manage_receipts, @post_receipts]

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"supply-chain" => "Supply Chain domain modules"},
        verbs: ["post-receipt"],
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        # The "supply_chain" parent is Purchasing's, a declared dependency.
        %{
          id: "supply_chain.receipts",
          label: "Goods receipts",
          parent: "supply_chain",
          route: "/supply-chain/receipts",
          capability: @view,
          order: 25
        }
      ]
    }
  end
end
