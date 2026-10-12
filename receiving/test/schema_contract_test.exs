defmodule Bilimbi.SupplyChain.Receiving.SchemaContractTest do
  use ExUnit.Case, async: false

  alias Bilimbi.Base.Database.SchemaVerifier
  alias Bilimbi.Base.Repo
  alias Bilimbi.SupplyChain.Receiving.SchemaContract
  alias Bilimbi.SupplyChain.Receiving.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @migrations SchemaContract.migrations()

  setup do
    # UUIDs keep fresh databases isolated across concurrent BEAM instances.
    database = "bilimbi_receiving_#{String.replace(Ecto.UUID.generate(), "-", "")}"
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

    TestFixtures.migrations()

    for {version, module} <- @migrations do
      assert :ok = Ecto.Migrator.up(Repo, version, module, log: false, dynamic_repo: repo)
    end

    %{repo: repo}
  end

  test "the fresh migration implements the complete receiving contract", %{repo: repo} do
    assert :ok = SchemaVerifier.verify(repo, SchemaContract.tables())
  end

  test "the migration rolls back", %{repo: repo} do
    for {version, module} <- Enum.reverse(@migrations) do
      assert :ok = Ecto.Migrator.down(Repo, version, module, log: false, dynamic_repo: repo)
    end

    %{rows: [[0]]} =
      SQL.query!(
        repo,
        "SELECT count(*) FROM pg_tables WHERE tablename LIKE 'supply_chain_receiving_%'",
        []
      )
  end

  # The module's other suite proves these rules on temporary copies of the
  # tables; this proves the migration itself carries them, outside a sandbox,
  # where the deferred history check runs at commit. A refused commit
  # disconnects, which Postgrex logs; the log is expected.
  @tag :capture_log
  test "the migration's triggers number, audit, and fix receipts", %{repo: repo} do
    Repo.put_dynamic_repo(repo)
    query! = fn sql -> SQL.query!(repo, sql, []) end

    in_transaction = fn statements ->
      Repo.transaction(fn -> Enum.each(statements, query!) end)
    end

    # The writer's own number is replaced by the database's, and a creation
    # commits only with its history row.
    receipt = fn id ->
      "INSERT INTO supply_chain_receiving_receipts (id, tenant_id, company_id, receipt_number, order_id, order_number, supplier_id, received_on, created_by_user_id, inserted_at, updated_at) VALUES (#{id}, 1, 1, 99, 5, 7, 3, '2026-10-13', 1, now(), now())"
    end

    event = fn receipt_id, from, to ->
      "INSERT INTO supply_chain_receiving_receipt_events (tenant_id, company_id, receipt_id, from_status, to_status, actor_user_id, occurred_at) VALUES (1, 1, #{receipt_id}, #{from}, '#{to}', 1, '2000-01-01')"
    end

    line = fn receipt_id, number ->
      "INSERT INTO supply_chain_receiving_receipt_lines (tenant_id, company_id, receipt_id, line_number, order_line_id, order_line_number, description, unit, ordered_quantity, received_quantity) VALUES (1, 1, #{receipt_id}, #{number}, #{number}, #{number}, 'Item', 'unit', 10, 1)"
    end

    assert_raise Postgrex.Error, ~r/without a history row/, fn ->
      in_transaction.([receipt.(1)])
    end

    assert {:ok, _} = in_transaction.([receipt.(2), event.(2, "NULL", "draft"), line.(2, 1)])
    assert {:ok, _} = in_transaction.([receipt.(3), event.(3, "NULL", "draft")])

    # Refused transactions consumed no number: the two created receipts are 1 and 2.
    assert %{rows: [[2, 1], [3, 2]]} =
             query!.("SELECT id, receipt_number FROM supply_chain_receiving_receipts ORDER BY id")

    # A transition needs its history row and must be one the table allows.
    post = "UPDATE supply_chain_receiving_receipts SET status = 'posted', posted_by_user_id = 1, posted_at = now() WHERE id = 2"

    assert_raise Postgrex.Error, ~r/without a history row/, fn -> in_transaction.([post]) end

    assert_raise Postgrex.Error, ~r/does not go from draft to reversed/, fn ->
      query!.("UPDATE supply_chain_receiving_receipts SET status = 'reversed' WHERE id = 2")
    end

    assert {:ok, _} = in_transaction.([post, event.(2, "'draft'", "posted")])

    # From posting on, the receipt and its lines are fixed.
    assert_raise Postgrex.Error, ~r/is fixed/, fn ->
      query!.("UPDATE supply_chain_receiving_receipts SET notes = 'x' WHERE id = 2")
    end

    assert_raise Postgrex.Error, ~r/does not go from posted to cancelled/, fn ->
      query!.(
        "UPDATE supply_chain_receiving_receipts SET status = 'cancelled', posted_by_user_id = NULL, posted_at = NULL, cancelled_at = now() WHERE id = 2"
      )
    end

    assert_raise Postgrex.Error, ~r/its lines are fixed/, fn ->
      query!.("UPDATE supply_chain_receiving_receipt_lines SET received_quantity = 5 WHERE receipt_id = 2")
    end

    assert_raise Postgrex.Error, ~r/its lines are fixed/, fn -> query!.(line.(2, 2)) end

    assert_raise Postgrex.Error, ~r/its lines are fixed/, fn ->
      query!.("DELETE FROM supply_chain_receiving_receipt_lines WHERE receipt_id = 2")
    end

    query!.(
      "INSERT INTO supply_chain_receiving_settings (tenant_id, company_id, over_receipt_tolerance_percent, set_by_user_id, occurred_at) VALUES (1, 1, 5, 1, '2000-01-01')"
    )

    # The settings row is stamped by the database, not the writer.
    assert %{rows: [[true]]} =
             query!.("SELECT occurred_at > '2020-01-01' FROM supply_chain_receiving_settings")

    for sql <- [
          "DELETE FROM supply_chain_receiving_receipts WHERE id = 3",
          "TRUNCATE supply_chain_receiving_receipt_events",
          "UPDATE supply_chain_receiving_receipt_events SET reason = 'x'",
          "UPDATE supply_chain_receiving_settings SET over_receipt_tolerance_percent = 9",
          "DELETE FROM supply_chain_receiving_settings"
        ] do
      assert_raise Postgrex.Error, ~r/supply chain receiving keeps/, fn -> query!.(sql) end
    end

    # A reversal names a posted receipt once.
    reversal = fn id ->
      "INSERT INTO supply_chain_receiving_receipts (id, tenant_id, company_id, receipt_number, kind, reverses_receipt_id, reason, order_id, order_number, supplier_id, received_on, created_by_user_id, inserted_at, updated_at) VALUES (#{id}, 1, 1, 99, 'reversal', 2, 'Wrong pallet', 5, 7, 3, '2026-10-14', 1, now(), now())"
    end

    assert {:ok, _} = in_transaction.([reversal.(4), event.(4, "NULL", "draft")])

    assert_raise Postgrex.Error, ~r/supply_chain_receiving_receipts_reversal_unique/, fn ->
      in_transaction.([reversal.(5), event.(5, "NULL", "draft")])
    end

    assert_raise Postgrex.Error, ~r/supply_chain_receiving_receipts_reversal/, fn ->
      query!.(
        "INSERT INTO supply_chain_receiving_receipts (tenant_id, company_id, receipt_number, kind, order_id, order_number, supplier_id, received_on, created_by_user_id, inserted_at, updated_at) VALUES (1, 1, 99, 'reversal', 5, 7, 3, '2026-10-14', 1, now(), now())"
      )
    end

    assert %{rows: [[3]]} = query!.("SELECT count(*) FROM supply_chain_receiving_receipts")
  end
end
