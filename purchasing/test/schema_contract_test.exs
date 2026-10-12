Code.require_file(
  "../priv/repo/migrations/20261012210000_create_supply_chain_purchasing.exs",
  __DIR__
)

defmodule Bilimbi.SupplyChain.Purchasing.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.SupplyChain.Purchasing.Migrations.CreatePurchasing
  alias Bilimbi.SupplyChain.Purchasing.SchemaContract
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_purchasing_#{String.replace(Ecto.UUID.generate(), "-", "")}"
    quoted = SchemaVerifier.quote_identifier!(database)
    Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "CREATE DATABASE #{quoted}", []) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> SQL.query!(Repo, "DROP DATABASE #{quoted}", []) end)
    end)

    repo = Module.concat(__MODULE__, FreshRepo)

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: repo, database: database, pool: DBConnection.ConnectionPool, pool_size: 2},
        id: repo
      )
    )

    assert :ok =
             Ecto.Migrator.up(Repo, SchemaContract.migration_version(), CreatePurchasing,
               log: false,
               dynamic_repo: repo
             )

    %{repo: repo}
  end

  test "the fresh migration implements the complete purchasing contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migration rolls back", %{repo: repo} do
    assert :ok =
             Ecto.Migrator.down(Repo, SchemaContract.migration_version(), CreatePurchasing,
               log: false,
               dynamic_repo: repo
             )

    %{rows: [[0]]} =
      SQL.query!(
        repo,
        "SELECT count(*) FROM pg_tables WHERE tablename LIKE 'supply_chain_purchasing_%'",
        []
      )
  end

  # The module's other suites prove these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred history checks run at commit. A refused commit
  # disconnects, which Postgrex logs; the log is expected.
  @tag :capture_log
  test "the migration's triggers number, audit, and freeze orders", %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    {:ok, _} =
      in_transaction.([
        "INSERT INTO supply_chain_purchasing_suppliers (id, tenant_id, company_id, code, name, inserted_at, updated_at) VALUES (1, 1, 1, 'S1', 'Supplier', now(), now())"
      ])

    # The writer's own number is replaced by the database's, and a creation
    # commits only with its history row.
    order = fn id ->
      "INSERT INTO supply_chain_purchasing_orders (id, tenant_id, company_id, order_number, supplier_id, currency_code, created_by_user_id, inserted_at, updated_at) VALUES (#{id}, 1, 1, 99, 1, 'XTS', 1, now(), now())"
    end

    event = fn order_id, from, to ->
      "INSERT INTO supply_chain_purchasing_order_events (tenant_id, company_id, order_id, from_status, to_status, actor_user_id, occurred_at) VALUES (1, 1, #{order_id}, #{from}, '#{to}', 1, '2000-01-01')"
    end

    line = fn order_id, number ->
      "INSERT INTO supply_chain_purchasing_order_lines (tenant_id, company_id, order_id, line_number, description, quantity, unit, unit_price) VALUES (1, 1, #{order_id}, #{number}, 'Item', 1, 'unit', 1)"
    end

    assert_raise Postgrex.Error, ~r/without a history row/, fn -> in_transaction.([order.(1)]) end

    assert {:ok, _} = in_transaction.([order.(2), event.(2, "NULL", "draft"), line.(2, 1)])
    assert {:ok, _} = in_transaction.([order.(3), event.(3, "NULL", "draft")])

    # Refused transactions consumed no number: the two created orders are 1 and 2.
    assert %{rows: [[2, 1], [3, 2]]} =
             query!.("SELECT id, order_number FROM supply_chain_purchasing_orders ORDER BY id")

    # A transition needs its history row and must be one the table allows.
    assert_raise Postgrex.Error, ~r/without a history row/, fn ->
      in_transaction.([
        "UPDATE supply_chain_purchasing_orders SET status = 'submitted', submitted_by_user_id = 1, submitted_at = now() WHERE id = 2"
      ])
    end

    assert_raise Postgrex.Error, ~r/does not go from draft to approved/, fn ->
      query!.("UPDATE supply_chain_purchasing_orders SET status = 'approved' WHERE id = 2")
    end

    assert {:ok, _} =
             in_transaction.([
               "UPDATE supply_chain_purchasing_orders SET status = 'submitted', submitted_by_user_id = 1, submitted_at = now() WHERE id = 2",
               event.(2, "'draft'", "submitted")
             ])

    # From submission on, the header and lines are fixed.
    assert_raise Postgrex.Error, ~r/changes only by a transition or an amendment/, fn ->
      query!.("UPDATE supply_chain_purchasing_orders SET reference = 'x' WHERE id = 2")
    end

    assert_raise Postgrex.Error, ~r/lines change only by an amendment or a receipt/, fn ->
      query!.("UPDATE supply_chain_purchasing_order_lines SET quantity = 5 WHERE order_id = 2")
    end

    assert_raise Postgrex.Error, ~r/its lines are kept/, fn ->
      query!.("DELETE FROM supply_chain_purchasing_order_lines WHERE order_id = 2")
    end

    for sql <- [
          "DELETE FROM supply_chain_purchasing_orders WHERE id = 3",
          "TRUNCATE supply_chain_purchasing_order_events",
          "UPDATE supply_chain_purchasing_order_events SET reason = 'x'",
          "DELETE FROM supply_chain_purchasing_suppliers WHERE id = 1"
        ] do
      assert_raise Postgrex.Error, ~r/supply chain purchasing keeps/, fn -> query!.(sql) end
    end

    assert_raise Postgrex.Error, ~r/keeps its company and code/, fn ->
      query!.("UPDATE supply_chain_purchasing_suppliers SET code = 'S9' WHERE id = 1")
    end

    # An approved order goes back to submitted only with the amendment that
    # sent it there, written in the same transaction.
    assert {:ok, _} =
             in_transaction.([
               "UPDATE supply_chain_purchasing_orders SET status = 'approved', approved_by_user_id = 2, approved_at = now() WHERE id = 2",
               event.(2, "'submitted'", "approved")
             ])

    back_to_submitted =
      "UPDATE supply_chain_purchasing_orders SET status = 'submitted', submitted_by_user_id = 3, submitted_at = now(), approved_by_user_id = NULL, approved_at = NULL WHERE id = 2"

    assert_raise Postgrex.Error, ~r/went back to submitted without an amendment/, fn ->
      in_transaction.([back_to_submitted, event.(2, "'approved'", "submitted")])
    end

    assert {:ok, _} =
             in_transaction.([
               "INSERT INTO supply_chain_purchasing_order_amendments (tenant_id, company_id, order_id, reason, amended_by_user_id, occurred_at) VALUES (1, 1, 2, 'Price changed', 3, now())",
               "UPDATE supply_chain_purchasing_orders SET amendment_count = 1 WHERE id = 2",
               back_to_submitted,
               event.(2, "'approved'", "submitted")
             ])

    assert %{rows: [["submitted", 1]]} =
             query!.(
               "SELECT status, amendment_count FROM supply_chain_purchasing_orders WHERE id = 2"
             )

    assert %{rows: [[2]]} = query!.("SELECT count(*) FROM supply_chain_purchasing_orders")
  end
end
