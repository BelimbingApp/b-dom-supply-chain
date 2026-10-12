defmodule Bilimbi.SupplyChain.Receiving.Migrations.CreateReceiving do
  @moduledoc """
  Receiving: each company's goods receipts against purchase orders, their
  lines, their status history, and the company's over-receipt tolerance.

  Bilimbi-only. A receipt names its purchase order and its lines name the
  order's lines by ID, with the order number and each line's description,
  unit, and ordered quantity copied at posting so a receipt reads the same
  whatever the order becomes; nothing here references Purchasing's tables.
  Rows of one company reference each other through composite
  `(id, company_id)` foreign keys. The database numbers each company's
  receipts 1, 2, 3, ... without gaps. Nothing is deleted: triggers refuse
  DELETE and TRUNCATE on every table, and history rows and tolerance
  settings are append-only, the current tolerance being the newest row.

  A receipt is free while it is a draft. Posting or cancelling it is the
  only change the trigger allows afterwards: a posted or cancelled receipt
  and its lines are fixed for good, and a posted receipt is corrected only
  by a reversal receipt that names it, which the partial unique index
  allows once. A new receipt is always a draft. A deferred constraint
  trigger refuses a commit in which a receipt was created or changed
  status without a history row written in the same transaction, so every
  posting carries its actor, time, and reason.

  `statements/1` is the one DDL source: `up/0` runs it against permanent
  tables, and the module's `test/support/test_fixtures.ex` runs the same
  statements as temporary tables with `pg_temp` functions, so a test that
  makes PostgreSQL refuse proves this migration's rule.
  """

  use Ecto.Migration

  @tables ~w(
    supply_chain_receiving_settings
    supply_chain_receiving_receipts
    supply_chain_receiving_receipt_lines
    supply_chain_receiving_receipt_events
  )

  @functions ~w(
    supply_chain_receiving_refuse_change
    supply_chain_receiving_stamp
    supply_chain_receiving_number_receipt
    supply_chain_receiving_receipt_header_rules
    supply_chain_receiving_receipt_line_rules
    supply_chain_receiving_receipt_audited
  )

  @statuses ~w(draft posted cancelled)
  @kinds ~w(receipt reversal)

  @transitions [
    {"draft", "posted"},
    {"draft", "cancelled"}
  ]

  @doc "The tables this migration creates, in creation order."
  def tables, do: @tables

  @doc "The receipt statuses, as the database checks them."
  def statuses, do: @statuses

  @doc "The receipt kinds, as the database checks them."
  def kinds, do: @kinds

  @doc "The `{from, to}` receipt transitions the database allows."
  def transitions, do: @transitions

  def up do
    Enum.each(statements(:permanent), &execute/1)
  end

  def down do
    for table <- Enum.reverse(@tables), do: drop(table(table))
    for function <- @functions, do: execute("DROP FUNCTION #{function}()")
  end

  @doc """
  Every DDL statement, in order. `:permanent` creates the real tables and
  functions; `:temporary` creates temporary tables and `pg_temp` functions
  for module tests.
  """
  @spec statements(:permanent | :temporary) :: [String.t()]
  def statements(mode) when mode in [:permanent, :temporary] do
    {table, fun} =
      case mode do
        :permanent -> {"CREATE TABLE", ""}
        :temporary -> {"CREATE TEMPORARY TABLE", "pg_temp."}
      end

    rows = if mode == :temporary, do: " ON COMMIT PRESERVE ROWS", else: ""

    table_statements(table, rows) ++ function_statements(fun) ++ trigger_statements(fun)
  end

  defp table_statements(table, rows) do
    [
      """
      #{table} supply_chain_receiving_settings (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        over_receipt_tolerance_percent numeric(7, 4) NOT NULL,
        set_by_user_id bigint NOT NULL, set_by_impersonator_id bigint,
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT supply_chain_receiving_settings_tolerance
          CHECK (over_receipt_tolerance_percent >= 0 AND over_receipt_tolerance_percent <= 100)
      )#{rows}
      """,
      """
      CREATE INDEX supply_chain_receiving_settings_company_id_id_index
        ON supply_chain_receiving_settings (company_id, id)
      """,
      """
      #{table} supply_chain_receiving_receipts (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        receipt_number bigint NOT NULL, kind varchar(20) NOT NULL DEFAULT 'receipt',
        status varchar(20) NOT NULL DEFAULT 'draft',
        order_id bigint NOT NULL, order_number bigint NOT NULL, supplier_id bigint NOT NULL,
        reverses_receipt_id bigint, reason varchar(500),
        received_on date NOT NULL, supplier_reference varchar(100), notes varchar(1000),
        created_by_user_id bigint NOT NULL, created_by_impersonator_id bigint,
        posted_by_user_id bigint, posted_by_impersonator_id bigint, posted_at timestamp(6),
        cancelled_at timestamp(6),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT supply_chain_receiving_receipts_id_company_unique UNIQUE (id, company_id),
        CONSTRAINT supply_chain_receiving_receipts_company_number_unique
          UNIQUE (company_id, receipt_number),
        CONSTRAINT supply_chain_receiving_receipts_reverses_fkey
          FOREIGN KEY (reverses_receipt_id, company_id)
          REFERENCES supply_chain_receiving_receipts (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT supply_chain_receiving_receipts_receipt_number CHECK (receipt_number > 0),
        CONSTRAINT supply_chain_receiving_receipts_order_number CHECK (order_number > 0),
        CONSTRAINT supply_chain_receiving_receipts_kind CHECK (kind IN (#{quoted(@kinds)})),
        CONSTRAINT supply_chain_receiving_receipts_status
          CHECK (status IN (#{quoted(@statuses)})),
        CONSTRAINT supply_chain_receiving_receipts_reversal CHECK (
          (kind = 'receipt' AND reverses_receipt_id IS NULL AND reason IS NULL)
          OR (kind = 'reversal' AND reverses_receipt_id IS NOT NULL AND reason IS NOT NULL)
        ),
        CONSTRAINT supply_chain_receiving_receipts_not_self_reversal
          CHECK (reverses_receipt_id IS NULL OR reverses_receipt_id <> id),
        CONSTRAINT supply_chain_receiving_receipts_lifecycle CHECK (
          (status = 'draft' AND posted_by_user_id IS NULL AND posted_by_impersonator_id IS NULL
            AND posted_at IS NULL AND cancelled_at IS NULL)
          OR (status = 'posted' AND posted_by_user_id IS NOT NULL AND posted_at IS NOT NULL
            AND cancelled_at IS NULL)
          OR (status = 'cancelled' AND posted_by_user_id IS NULL AND posted_by_impersonator_id IS NULL
            AND posted_at IS NULL AND cancelled_at IS NOT NULL)
        )
      )#{rows}
      """,
      """
      CREATE UNIQUE INDEX supply_chain_receiving_receipts_reversal_unique
        ON supply_chain_receiving_receipts (reverses_receipt_id)
        WHERE status <> 'cancelled'
      """,
      """
      CREATE INDEX supply_chain_receiving_receipts_tenant_company_status_index
        ON supply_chain_receiving_receipts (tenant_id, company_id, status)
      """,
      """
      CREATE INDEX supply_chain_receiving_receipts_company_id_order_id_index
        ON supply_chain_receiving_receipts (company_id, order_id)
      """,
      """
      #{table} supply_chain_receiving_receipt_lines (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        receipt_id bigint NOT NULL, line_number integer NOT NULL,
        order_line_id bigint NOT NULL, order_line_number integer NOT NULL,
        description varchar(500) NOT NULL, unit varchar(20) NOT NULL,
        ordered_quantity numeric(20, 4) NOT NULL,
        received_quantity numeric(20, 4) NOT NULL DEFAULT 0,
        rejected_quantity numeric(20, 4) NOT NULL DEFAULT 0,
        rejection_reason varchar(500),
        CONSTRAINT supply_chain_receiving_receipt_lines_receipt_fkey
          FOREIGN KEY (receipt_id, company_id)
          REFERENCES supply_chain_receiving_receipts (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT supply_chain_receiving_receipt_lines_receipt_line_unique
          UNIQUE (receipt_id, line_number),
        CONSTRAINT supply_chain_receiving_receipt_lines_receipt_order_line_unique
          UNIQUE (receipt_id, order_line_id),
        CONSTRAINT supply_chain_receiving_receipt_lines_line_number CHECK (line_number > 0),
        CONSTRAINT supply_chain_receiving_receipt_lines_order_line_number
          CHECK (order_line_number > 0),
        CONSTRAINT supply_chain_receiving_receipt_lines_ordered_quantity
          CHECK (ordered_quantity > 0),
        CONSTRAINT supply_chain_receiving_receipt_lines_quantities CHECK (
          received_quantity >= 0 AND rejected_quantity >= 0
          AND received_quantity + rejected_quantity > 0
        ),
        CONSTRAINT supply_chain_receiving_receipt_lines_rejection CHECK (
          (rejected_quantity = 0 AND rejection_reason IS NULL)
          OR (rejected_quantity > 0 AND rejection_reason IS NOT NULL)
        )
      )#{rows}
      """,
      """
      CREATE INDEX supply_chain_receiving_receipt_lines_company_order_line_index
        ON supply_chain_receiving_receipt_lines (company_id, order_line_id)
      """,
      """
      #{table} supply_chain_receiving_receipt_events (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        receipt_id bigint NOT NULL, from_status varchar(20), to_status varchar(20) NOT NULL,
        actor_user_id bigint NOT NULL, actor_impersonator_id bigint, reason varchar(500),
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT supply_chain_receiving_receipt_events_receipt_fkey
          FOREIGN KEY (receipt_id, company_id)
          REFERENCES supply_chain_receiving_receipts (id, company_id) ON DELETE RESTRICT
      )#{rows}
      """,
      """
      CREATE INDEX supply_chain_receiving_receipt_events_receipt_id_id_index
        ON supply_chain_receiving_receipt_events (receipt_id, id)
      """,
      """
      CREATE INDEX supply_chain_receiving_receipt_events_company_status_id_index
        ON supply_chain_receiving_receipt_events (company_id, to_status, id)
      """
    ]
  end

  defp function_statements(fun) do
    [
      """
      CREATE FUNCTION #{fun}supply_chain_receiving_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'supply chain receiving keeps % rows: % is refused',
          TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      """
      CREATE FUNCTION #{fun}supply_chain_receiving_stamp() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.occurred_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      # The database numbers each company's receipts 1, 2, 3, ... whatever the
      # inserting writer sent: with no sequence and no deletion, a number is
      # never skipped or reused, and a concurrent writer that takes the same
      # number fails on the unique constraint. A new receipt is a draft.
      """
      CREATE FUNCTION #{fun}supply_chain_receiving_number_receipt() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.status <> 'draft' THEN
          RAISE EXCEPTION 'a new goods receipt is a draft'
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.receipt_number := COALESCE(
          (SELECT max(receipt_number) FROM supply_chain_receiving_receipts
           WHERE company_id = NEW.company_id), 0) + 1;
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{fun}supply_chain_receiving_receipt_header_rules() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
          OR NEW.receipt_number <> OLD.receipt_number OR NEW.kind <> OLD.kind
          OR NEW.order_id <> OLD.order_id OR NEW.order_number <> OLD.order_number
          OR NEW.supplier_id <> OLD.supplier_id
          OR NEW.reverses_receipt_id IS DISTINCT FROM OLD.reverses_receipt_id
          OR NEW.reason IS DISTINCT FROM OLD.reason
          OR NEW.created_by_user_id <> OLD.created_by_user_id
          OR NEW.created_by_impersonator_id IS DISTINCT FROM OLD.created_by_impersonator_id THEN
          RAISE EXCEPTION 'a goods receipt keeps its company, number, kind, order and creator'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.status <> OLD.status THEN
          IF (OLD.status, NEW.status) NOT IN (#{pairs(@transitions)}) THEN
            RAISE EXCEPTION 'a goods receipt does not go from % to %', OLD.status, NEW.status
              USING ERRCODE = 'restrict_violation';
          END IF;

          IF NEW.received_on <> OLD.received_on
            OR NEW.supplier_reference IS DISTINCT FROM OLD.supplier_reference
            OR NEW.notes IS DISTINCT FROM OLD.notes THEN
            RAISE EXCEPTION 'a goods receipt is not edited in the same change as a transition'
              USING ERRCODE = 'restrict_violation';
          END IF;
        ELSIF OLD.status <> 'draft' THEN
          RAISE EXCEPTION 'goods receipt % is %: it is fixed', OLD.id, OLD.status
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{fun}supply_chain_receiving_receipt_line_rules() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        receipt_status varchar(20);
        subject_id bigint;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          subject_id := OLD.receipt_id;
        ELSE
          subject_id := NEW.receipt_id;
        END IF;

        IF TG_OP = 'UPDATE' AND (NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
          OR NEW.receipt_id <> OLD.receipt_id) THEN
          RAISE EXCEPTION 'a goods receipt line keeps its receipt'
            USING ERRCODE = 'restrict_violation';
        END IF;

        SELECT status INTO receipt_status FROM supply_chain_receiving_receipts WHERE id = subject_id;

        IF receipt_status IS DISTINCT FROM 'draft' THEN
          RAISE EXCEPTION 'goods receipt % is %: its lines are fixed', subject_id, receipt_status
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # Every creation and transition carries a history row written in the same
      # transaction. now() is the transaction's start; events are stamped with
      # clock_timestamp(), so a row from an earlier transaction never counts.
      """
      CREATE FUNCTION #{fun}supply_chain_receiving_receipt_audited() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        previous varchar(20);
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF NEW.status = OLD.status THEN
            RETURN NULL;
          END IF;

          previous := OLD.status;
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM supply_chain_receiving_receipt_events
          WHERE receipt_id = NEW.id AND from_status IS NOT DISTINCT FROM previous
            AND to_status = NEW.status AND occurred_at >= now() AT TIME ZONE 'UTC'
        ) THEN
          RAISE EXCEPTION 'goods receipt % became % without a history row', NEW.id, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """
    ]
  end

  defp trigger_statements(fun) do
    refuse = "#{fun}supply_chain_receiving_refuse_change()"

    for(
      table <- @tables,
      do: trigger("#{table}_no_truncate", "BEFORE TRUNCATE", table, refuse, "STATEMENT")
    ) ++
      [
        trigger(
          "supply_chain_receiving_receipts_kept",
          "BEFORE DELETE",
          "supply_chain_receiving_receipts",
          refuse
        ),
        trigger(
          "supply_chain_receiving_settings_append_only",
          "BEFORE UPDATE OR DELETE",
          "supply_chain_receiving_settings",
          refuse
        ),
        trigger(
          "supply_chain_receiving_receipt_events_append_only",
          "BEFORE UPDATE OR DELETE",
          "supply_chain_receiving_receipt_events",
          refuse
        ),
        trigger(
          "supply_chain_receiving_settings_stamp",
          "BEFORE INSERT",
          "supply_chain_receiving_settings",
          "#{fun}supply_chain_receiving_stamp()"
        ),
        trigger(
          "supply_chain_receiving_receipt_events_stamp",
          "BEFORE INSERT",
          "supply_chain_receiving_receipt_events",
          "#{fun}supply_chain_receiving_stamp()"
        ),
        trigger(
          "supply_chain_receiving_receipts_number",
          "BEFORE INSERT",
          "supply_chain_receiving_receipts",
          "#{fun}supply_chain_receiving_number_receipt()"
        ),
        trigger(
          "supply_chain_receiving_receipts_header",
          "BEFORE UPDATE",
          "supply_chain_receiving_receipts",
          "#{fun}supply_chain_receiving_receipt_header_rules()"
        ),
        trigger(
          "supply_chain_receiving_receipt_lines_rules",
          "BEFORE INSERT OR UPDATE OR DELETE",
          "supply_chain_receiving_receipt_lines",
          "#{fun}supply_chain_receiving_receipt_line_rules()"
        ),
        """
        CREATE CONSTRAINT TRIGGER supply_chain_receiving_receipts_audited
          AFTER INSERT OR UPDATE ON supply_chain_receiving_receipts
          DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION #{fun}supply_chain_receiving_receipt_audited()
        """
      ]
  end

  defp trigger(name, timing, table, function, each \\ "ROW") do
    """
    CREATE TRIGGER #{name}
      #{timing} ON #{table}
      FOR EACH #{each} EXECUTE FUNCTION #{function}
    """
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp pairs(transitions),
    do: Enum.map_join(transitions, ", ", fn {a, b} -> "('#{a}', '#{b}')" end)
end
