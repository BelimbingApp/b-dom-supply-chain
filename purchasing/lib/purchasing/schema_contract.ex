defmodule Bilimbi.SupplyChain.Purchasing.SchemaContract do
  @moduledoc """
  Fresh Bilimbi purchasing schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  def migration_version, do: 20_261_012_210_000

  @impl true
  def tables do
    [
      %{
        name: "supply_chain_purchasing_suppliers",
        columns:
          owned_columns("supply_chain_purchasing_suppliers")
          |> Map.merge(%{
            "code" => column({:varchar, 50}, false),
            "name" => column({:varchar, 200}, false),
            "contact_name" => column({:varchar, 200}, true),
            "email" => column({:varchar, 255}, true),
            "phone" => column({:varchar, 50}, true),
            "address_line1" => column({:varchar, 255}, true),
            "address_line2" => column({:varchar, 255}, true),
            "address_line3" => column({:varchar, 255}, true),
            "locality" => column({:varchar, 120}, true),
            "postcode" => column({:varchar, 20}, true),
            "country_iso" => column({:varchar, 2}, true),
            "admin1_code" => column({:varchar, 20}, true),
            "active" => column(:boolean, false, {:boolean, true})
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "supply_chain_purchasing_suppliers_pkey" => index(["id"], true),
          "supply_chain_purchasing_suppliers_id_company_unique" =>
            index(["id", "company_id"], true),
          "supply_chain_purchasing_suppliers_company_code_unique" =>
            index(["company_id", "code"], true),
          "supply_chain_purchasing_suppliers_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "supply_chain_purchasing_suppliers_country_iso" =>
            check("country_iso IS NULL OR (country_iso)::text ~ '^[A-Z]{2}$'::text")
        }
      },
      %{
        name: "supply_chain_purchasing_tax_codes",
        columns:
          owned_columns("supply_chain_purchasing_tax_codes")
          |> Map.merge(%{
            "code" => column({:varchar, 20}, false),
            "name" => column({:varchar, 120}, false),
            "rate" => column({:numeric, 7, 4}, false),
            "active" => column(:boolean, false, {:boolean, true})
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "supply_chain_purchasing_tax_codes_pkey" => index(["id"], true),
          "supply_chain_purchasing_tax_codes_id_company_unique" =>
            index(["id", "company_id"], true),
          "supply_chain_purchasing_tax_codes_company_code_unique" =>
            index(["company_id", "code"], true),
          "supply_chain_purchasing_tax_codes_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "supply_chain_purchasing_tax_codes_rate" =>
            check("rate >= (0)::numeric AND rate <= (100)::numeric")
        }
      },
      %{
        name: "supply_chain_purchasing_requests",
        columns:
          owned_columns("supply_chain_purchasing_requests")
          |> Map.merge(%{
            "request_number" => column(:bigint, false),
            "status" => column({:varchar, 20}, false, {:string, "draft"}),
            "title" => column({:varchar, 200}, false),
            "justification" => column({:varchar, 1000}, true),
            "needed_on" => column(:date, true),
            "created_by_user_id" => column(:bigint, false),
            "created_by_impersonator_id" => column(:bigint, true),
            "submitted_by_user_id" => column(:bigint, true),
            "submitted_at" => column({:timestamp, 6}, true),
            "decided_by_user_id" => column(:bigint, true),
            "decided_at" => column({:timestamp, 6}, true),
            "decision_reason" => column({:varchar, 500}, true)
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "supply_chain_purchasing_requests_pkey" => index(["id"], true),
          "supply_chain_purchasing_requests_id_company_unique" =>
            index(["id", "company_id"], true),
          "supply_chain_purchasing_requests_company_number_unique" =>
            index(["company_id", "request_number"], true),
          "supply_chain_purchasing_requests_tenant_company_status_index" =>
            index(["tenant_id", "company_id", "status"])
        },
        foreign_keys: %{},
        checks: %{
          "supply_chain_purchasing_requests_request_number" => check("request_number > 0"),
          "supply_chain_purchasing_requests_status" =>
            check(status_check(~w(draft submitted approved rejected cancelled))),
          "supply_chain_purchasing_requests_lifecycle" =>
            check(
              "((status)::text = 'draft'::text AND submitted_by_user_id IS NULL AND submitted_at IS NULL " <>
                "AND decided_by_user_id IS NULL AND decided_at IS NULL AND decision_reason IS NULL) " <>
                "OR ((status)::text = 'submitted'::text AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND decided_by_user_id IS NULL AND decided_at IS NULL " <>
                "AND decision_reason IS NULL) " <>
                "OR ((status)::text = 'approved'::text AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND decided_by_user_id IS NOT NULL AND decided_at IS NOT NULL) " <>
                "OR ((status)::text = 'rejected'::text AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND decided_by_user_id IS NOT NULL AND decided_at IS NOT NULL " <>
                "AND decision_reason IS NOT NULL) " <>
                "OR (status)::text = 'cancelled'::text"
            )
        }
      },
      %{
        name: "supply_chain_purchasing_request_lines",
        columns:
          owned_columns("supply_chain_purchasing_request_lines")
          |> Map.merge(%{
            "request_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "description" => column({:varchar, 500}, false),
            "external_item_ref" => column({:varchar, 100}, true),
            "quantity" => column({:numeric, 20, 4}, false),
            "unit" => column({:varchar, 20}, false)
          }),
        indexes: %{
          "supply_chain_purchasing_request_lines_pkey" => index(["id"], true),
          "supply_chain_purchasing_request_lines_request_line_unique" =>
            index(["request_id", "line_number"], true)
        },
        foreign_keys: %{
          "supply_chain_purchasing_request_lines_request_fkey" =>
            company_reference("request_id", "supply_chain_purchasing_requests")
        },
        checks: %{
          "supply_chain_purchasing_request_lines_line_number" => check("line_number > 0"),
          "supply_chain_purchasing_request_lines_quantity" => check("quantity > (0)::numeric")
        }
      },
      %{
        name: "supply_chain_purchasing_request_events",
        columns:
          owned_columns("supply_chain_purchasing_request_events")
          |> Map.merge(%{
            "request_id" => column(:bigint, false),
            "from_status" => column({:varchar, 20}, true),
            "to_status" => column({:varchar, 20}, false),
            "actor_user_id" => column(:bigint, false),
            "actor_impersonator_id" => column(:bigint, true),
            "reason" => column({:varchar, 500}, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "supply_chain_purchasing_request_events_pkey" => index(["id"], true),
          "supply_chain_purchasing_request_events_request_id_id_index" =>
            index(["request_id", "id"])
        },
        foreign_keys: %{
          "supply_chain_purchasing_request_events_request_fkey" =>
            company_reference("request_id", "supply_chain_purchasing_requests")
        },
        checks: %{}
      },
      %{
        name: "supply_chain_purchasing_orders",
        columns:
          owned_columns("supply_chain_purchasing_orders")
          |> Map.merge(%{
            "order_number" => column(:bigint, false),
            "purchase_request_id" => column(:bigint, true),
            "supplier_id" => column(:bigint, false),
            "currency_code" => column({:varchar, 3}, false),
            "status" => column({:varchar, 20}, false, {:string, "draft"}),
            "reference" => column({:varchar, 100}, true),
            "notes" => column({:varchar, 1000}, true),
            "expected_on" => column(:date, true),
            "amendment_count" => column(:integer, false, {:integer, 0}),
            "created_by_user_id" => column(:bigint, false),
            "created_by_impersonator_id" => column(:bigint, true),
            "submitted_by_user_id" => column(:bigint, true),
            "submitted_at" => column({:timestamp, 6}, true),
            "approved_by_user_id" => column(:bigint, true),
            "approved_at" => column({:timestamp, 6}, true),
            "sent_at" => column({:timestamp, 6}, true),
            "closed_at" => column({:timestamp, 6}, true),
            "cancelled_at" => column({:timestamp, 6}, true)
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "supply_chain_purchasing_orders_pkey" => index(["id"], true),
          "supply_chain_purchasing_orders_id_company_unique" => index(["id", "company_id"], true),
          "supply_chain_purchasing_orders_company_number_unique" =>
            index(["company_id", "order_number"], true),
          "supply_chain_purchasing_orders_tenant_company_status_index" =>
            index(["tenant_id", "company_id", "status"]),
          "supply_chain_purchasing_orders_company_id_supplier_id_index" =>
            index(["company_id", "supplier_id"])
        },
        foreign_keys: %{
          "supply_chain_purchasing_orders_supplier_fkey" =>
            company_reference("supplier_id", "supply_chain_purchasing_suppliers"),
          "supply_chain_purchasing_orders_request_fkey" =>
            company_reference("purchase_request_id", "supply_chain_purchasing_requests")
        },
        checks: %{
          "supply_chain_purchasing_orders_order_number" => check("order_number > 0"),
          "supply_chain_purchasing_orders_amendment_count" => check("amendment_count >= 0"),
          "supply_chain_purchasing_orders_currency_code" =>
            check("(currency_code)::text ~ '^[A-Z]{3}$'::text"),
          "supply_chain_purchasing_orders_status" =>
            check(
              status_check(~w(draft submitted approved sent partially_received closed cancelled))
            ),
          "supply_chain_purchasing_orders_lifecycle" =>
            check(
              "((status)::text = 'draft'::text AND submitted_by_user_id IS NULL AND submitted_at IS NULL " <>
                "AND approved_by_user_id IS NULL AND approved_at IS NULL AND sent_at IS NULL " <>
                "AND closed_at IS NULL AND cancelled_at IS NULL AND amendment_count = 0) " <>
                "OR ((status)::text = 'submitted'::text AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND approved_by_user_id IS NULL AND approved_at IS NULL " <>
                "AND sent_at IS NULL AND closed_at IS NULL AND cancelled_at IS NULL) " <>
                "OR ((status)::text = 'approved'::text AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL " <>
                "AND sent_at IS NULL AND closed_at IS NULL AND cancelled_at IS NULL) " <>
                "OR ((status)::text = ANY ((ARRAY['sent'::character varying, " <>
                "'partially_received'::character varying])::text[]) AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL " <>
                "AND sent_at IS NOT NULL AND closed_at IS NULL AND cancelled_at IS NULL) " <>
                "OR ((status)::text = 'closed'::text AND submitted_by_user_id IS NOT NULL " <>
                "AND submitted_at IS NOT NULL AND approved_by_user_id IS NOT NULL AND approved_at IS NOT NULL " <>
                "AND sent_at IS NOT NULL AND closed_at IS NOT NULL AND cancelled_at IS NULL) " <>
                "OR ((status)::text = 'cancelled'::text AND cancelled_at IS NOT NULL AND closed_at IS NULL)"
            )
        }
      },
      %{
        name: "supply_chain_purchasing_order_amendments",
        columns:
          owned_columns("supply_chain_purchasing_order_amendments")
          |> Map.merge(%{
            "order_id" => column(:bigint, false),
            "amendment_number" => column(:integer, false),
            "reason" => column({:varchar, 500}, false),
            "amended_by_user_id" => column(:bigint, false),
            "amended_by_impersonator_id" => column(:bigint, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "supply_chain_purchasing_order_amendments_pkey" => index(["id"], true),
          "supply_chain_purchasing_order_amendments_id_order_unique" =>
            index(["id", "order_id"], true),
          "supply_chain_purchasing_order_amendments_order_number_unique" =>
            index(["order_id", "amendment_number"], true)
        },
        foreign_keys: %{
          "supply_chain_purchasing_order_amendments_order_fkey" =>
            company_reference("order_id", "supply_chain_purchasing_orders")
        },
        checks: %{
          "supply_chain_purchasing_order_amendments_amendment_number" =>
            check("amendment_number > 0")
        }
      },
      %{
        name: "supply_chain_purchasing_order_lines",
        columns:
          owned_columns("supply_chain_purchasing_order_lines")
          |> Map.merge(%{
            "order_id" => column(:bigint, false),
            "amendment_id" => column(:bigint, true),
            "superseded_by_amendment_id" => column(:bigint, true),
            "line_number" => column(:integer, false),
            "description" => column({:varchar, 500}, false),
            "external_item_ref" => column({:varchar, 100}, true),
            "quantity" => column({:numeric, 20, 4}, false),
            "unit" => column({:varchar, 20}, false),
            "unit_price" => column({:numeric, 20, 4}, false),
            "tax_code_id" => column(:bigint, true),
            "tax_rate" => column({:numeric, 7, 4}, true),
            "received_quantity" => column({:numeric, 20, 4}, false, {:integer, 0})
          }),
        indexes: %{
          "supply_chain_purchasing_order_lines_pkey" => index(["id"], true),
          "supply_chain_purchasing_order_lines_current_line_unique" => %{
            columns: ["order_id", "line_number"],
            unique: true,
            where: "(superseded_by_amendment_id IS NULL)"
          },
          "supply_chain_purchasing_order_lines_order_id_id_index" => index(["order_id", "id"]),
          "supply_chain_purchasing_order_lines_company_tax_code_index" =>
            index(["company_id", "tax_code_id"])
        },
        foreign_keys: %{
          "supply_chain_purchasing_order_lines_order_fkey" =>
            company_reference("order_id", "supply_chain_purchasing_orders"),
          "supply_chain_purchasing_order_lines_amendment_fkey" => order_reference("amendment_id"),
          "supply_chain_purchasing_order_lines_superseded_fkey" =>
            order_reference("superseded_by_amendment_id"),
          "supply_chain_purchasing_order_lines_tax_code_fkey" =>
            company_reference("tax_code_id", "supply_chain_purchasing_tax_codes")
        },
        checks: %{
          "supply_chain_purchasing_order_lines_line_number" => check("line_number > 0"),
          "supply_chain_purchasing_order_lines_quantity" => check("quantity > (0)::numeric"),
          "supply_chain_purchasing_order_lines_unit_price" => check("unit_price >= (0)::numeric"),
          "supply_chain_purchasing_order_lines_received_quantity" =>
            check("received_quantity >= (0)::numeric AND received_quantity <= quantity"),
          "supply_chain_purchasing_order_lines_tax" =>
            check(
              "(tax_code_id IS NULL AND tax_rate IS NULL) OR (tax_code_id IS NOT NULL " <>
                "AND tax_rate IS NOT NULL AND tax_rate >= (0)::numeric AND tax_rate <= (100)::numeric)"
            ),
          "supply_chain_purchasing_order_lines_not_self_superseded" =>
            check(
              "superseded_by_amendment_id IS NULL OR amendment_id IS NULL " <>
                "OR superseded_by_amendment_id <> amendment_id"
            )
        }
      },
      %{
        name: "supply_chain_purchasing_order_events",
        columns:
          owned_columns("supply_chain_purchasing_order_events")
          |> Map.merge(%{
            "order_id" => column(:bigint, false),
            "from_status" => column({:varchar, 20}, true),
            "to_status" => column({:varchar, 20}, false),
            "actor_user_id" => column(:bigint, false),
            "actor_impersonator_id" => column(:bigint, true),
            "reason" => column({:varchar, 500}, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "supply_chain_purchasing_order_events_pkey" => index(["id"], true),
          "supply_chain_purchasing_order_events_order_id_id_index" => index(["order_id", "id"])
        },
        foreign_keys: %{
          "supply_chain_purchasing_order_events_order_fkey" =>
            company_reference("order_id", "supply_chain_purchasing_orders")
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

  # A line names an amendment of its own order through `(id, order_id)`.
  defp order_reference(column) do
    %{
      columns: [column, "order_id"],
      references: {"supply_chain_purchasing_order_amendments", ["id", "order_id"]},
      on_delete: :restrict
    }
  end

  defp status_check(statuses) do
    "(status)::text = ANY ((ARRAY[" <>
      Enum.map_join(statuses, ", ", &"'#{&1}'::character varying") <> "])::text[])"
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}

  defp check(expression), do: %{expression: expression}
end
