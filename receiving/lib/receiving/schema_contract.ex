defmodule Bilimbi.SupplyChain.Receiving.SchemaContract do
  @moduledoc """
  Fresh Bilimbi receiving schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  @doc "The module's migrations as `{version, module}` in version order."
  def migrations do
    [{20_261_013_110_000, Bilimbi.SupplyChain.Receiving.Migrations.CreateReceiving}]
  end

  @impl true
  def tables do
    [
      %{
        name: "supply_chain_receiving_settings",
        columns:
          owned_columns("supply_chain_receiving_settings")
          |> Map.merge(%{
            "over_receipt_tolerance_percent" => column({:numeric, 7, 4}, false),
            "set_by_user_id" => column(:bigint, false),
            "set_by_impersonator_id" => column(:bigint, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "supply_chain_receiving_settings_pkey" => index(["id"], true),
          "supply_chain_receiving_settings_company_id_id_index" => index(["company_id", "id"])
        },
        foreign_keys: %{},
        checks: %{
          "supply_chain_receiving_settings_tolerance" =>
            check(
              "over_receipt_tolerance_percent >= (0)::numeric " <>
                "AND over_receipt_tolerance_percent <= (100)::numeric"
            )
        }
      },
      %{
        name: "supply_chain_receiving_receipts",
        columns:
          owned_columns("supply_chain_receiving_receipts")
          |> Map.merge(%{
            "receipt_number" => column(:bigint, false),
            "kind" => column({:varchar, 20}, false, {:string, "receipt"}),
            "status" => column({:varchar, 20}, false, {:string, "draft"}),
            "order_id" => column(:bigint, false),
            "order_number" => column(:bigint, false),
            "supplier_id" => column(:bigint, false),
            "reverses_receipt_id" => column(:bigint, true),
            "reason" => column({:varchar, 500}, true),
            "received_on" => column(:date, false),
            "supplier_reference" => column({:varchar, 100}, true),
            "notes" => column({:varchar, 1000}, true),
            "created_by_user_id" => column(:bigint, false),
            "created_by_impersonator_id" => column(:bigint, true),
            "posted_by_user_id" => column(:bigint, true),
            "posted_by_impersonator_id" => column(:bigint, true),
            "posted_at" => column({:timestamp, 6}, true),
            "cancelled_at" => column({:timestamp, 6}, true)
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "supply_chain_receiving_receipts_pkey" => index(["id"], true),
          "supply_chain_receiving_receipts_id_company_unique" =>
            index(["id", "company_id"], true),
          "supply_chain_receiving_receipts_company_number_unique" =>
            index(["company_id", "receipt_number"], true),
          "supply_chain_receiving_receipts_reversal_unique" => %{
            columns: ["reverses_receipt_id"],
            unique: true,
            where: "((status)::text <> 'cancelled'::text)"
          },
          "supply_chain_receiving_receipts_tenant_company_status_index" =>
            index(["tenant_id", "company_id", "status"]),
          "supply_chain_receiving_receipts_company_id_order_id_index" =>
            index(["company_id", "order_id"])
        },
        foreign_keys: %{
          "supply_chain_receiving_receipts_reverses_fkey" =>
            company_reference("reverses_receipt_id", "supply_chain_receiving_receipts")
        },
        checks: %{
          "supply_chain_receiving_receipts_receipt_number" => check("receipt_number > 0"),
          "supply_chain_receiving_receipts_order_number" => check("order_number > 0"),
          "supply_chain_receiving_receipts_kind" =>
            check(any_of("kind", ["receipt", "reversal"])),
          "supply_chain_receiving_receipts_status" =>
            check(any_of("status", ["draft", "posted", "cancelled"])),
          "supply_chain_receiving_receipts_reversal" =>
            check(
              "((kind)::text = 'receipt'::text AND reverses_receipt_id IS NULL AND reason IS NULL) " <>
                "OR ((kind)::text = 'reversal'::text AND reverses_receipt_id IS NOT NULL AND reason IS NOT NULL)"
            ),
          "supply_chain_receiving_receipts_not_self_reversal" =>
            check("reverses_receipt_id IS NULL OR reverses_receipt_id <> id"),
          "supply_chain_receiving_receipts_lifecycle" =>
            check(
              "((status)::text = 'draft'::text AND posted_by_user_id IS NULL " <>
                "AND posted_by_impersonator_id IS NULL AND posted_at IS NULL AND cancelled_at IS NULL) " <>
                "OR ((status)::text = 'posted'::text AND posted_by_user_id IS NOT NULL " <>
                "AND posted_at IS NOT NULL AND cancelled_at IS NULL) " <>
                "OR ((status)::text = 'cancelled'::text AND posted_by_user_id IS NULL " <>
                "AND posted_by_impersonator_id IS NULL AND posted_at IS NULL AND cancelled_at IS NOT NULL)"
            )
        }
      },
      %{
        name: "supply_chain_receiving_receipt_lines",
        columns:
          owned_columns("supply_chain_receiving_receipt_lines")
          |> Map.merge(%{
            "receipt_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "order_line_id" => column(:bigint, false),
            "order_line_number" => column(:integer, false),
            "description" => column({:varchar, 500}, false),
            "unit" => column({:varchar, 20}, false),
            "ordered_quantity" => column({:numeric, 20, 4}, false),
            "received_quantity" => column({:numeric, 20, 4}, false, {:integer, 0}),
            "rejected_quantity" => column({:numeric, 20, 4}, false, {:integer, 0}),
            "rejection_reason" => column({:varchar, 500}, true)
          }),
        indexes: %{
          "supply_chain_receiving_receipt_lines_pkey" => index(["id"], true),
          "supply_chain_receiving_receipt_lines_receipt_line_unique" =>
            index(["receipt_id", "line_number"], true),
          "supply_chain_receiving_receipt_lines_receipt_order_line_unique" =>
            index(["receipt_id", "order_line_id"], true),
          "supply_chain_receiving_receipt_lines_company_order_line_index" =>
            index(["company_id", "order_line_id"])
        },
        foreign_keys: %{
          "supply_chain_receiving_receipt_lines_receipt_fkey" =>
            company_reference("receipt_id", "supply_chain_receiving_receipts")
        },
        checks: %{
          "supply_chain_receiving_receipt_lines_line_number" => check("line_number > 0"),
          "supply_chain_receiving_receipt_lines_order_line_number" =>
            check("order_line_number > 0"),
          "supply_chain_receiving_receipt_lines_ordered_quantity" =>
            check("ordered_quantity > (0)::numeric"),
          "supply_chain_receiving_receipt_lines_quantities" =>
            check(
              "received_quantity >= (0)::numeric AND rejected_quantity >= (0)::numeric " <>
                "AND (received_quantity + rejected_quantity) > (0)::numeric"
            ),
          "supply_chain_receiving_receipt_lines_rejection" =>
            check(
              "(rejected_quantity = (0)::numeric AND rejection_reason IS NULL) " <>
                "OR (rejected_quantity > (0)::numeric AND rejection_reason IS NOT NULL)"
            )
        }
      },
      %{
        name: "supply_chain_receiving_receipt_events",
        columns:
          owned_columns("supply_chain_receiving_receipt_events")
          |> Map.merge(%{
            "receipt_id" => column(:bigint, false),
            "from_status" => column({:varchar, 20}, true),
            "to_status" => column({:varchar, 20}, false),
            "actor_user_id" => column(:bigint, false),
            "actor_impersonator_id" => column(:bigint, true),
            "reason" => column({:varchar, 500}, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "supply_chain_receiving_receipt_events_pkey" => index(["id"], true),
          "supply_chain_receiving_receipt_events_receipt_id_id_index" =>
            index(["receipt_id", "id"]),
          "supply_chain_receiving_receipt_events_company_status_id_index" =>
            index(["company_id", "to_status", "id"])
        },
        foreign_keys: %{
          "supply_chain_receiving_receipt_events_receipt_fkey" =>
            company_reference("receipt_id", "supply_chain_receiving_receipts")
        },
        checks: %{}
      }
    ]
  end

  defp owned_columns(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false)
    }
  end

  defp timestamps do
    %{
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
    }
  end

  # Rows of one company reference each other through `(id, company_id)`.
  defp company_reference(column, table) do
    %{
      columns: [column, "company_id"],
      references: {table, ["id", "company_id"]},
      on_delete: :restrict
    }
  end

  defp any_of(column, values) do
    "(#{column})::text = ANY ((ARRAY[" <>
      Enum.map_join(values, ", ", &"'#{&1}'::character varying") <> "])::text[])"
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}

  defp check(expression), do: %{expression: expression}
end
