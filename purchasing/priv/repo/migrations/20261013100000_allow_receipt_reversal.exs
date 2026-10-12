defmodule Bilimbi.SupplyChain.Purchasing.Migrations.AllowReceiptReversal do
  @moduledoc """
  Lets a Receiving module correct what was received against an order.

  Bilimbi-only. Two rules of `20261012210000` change: a line's received
  quantity may exceed the ordered one (the facade bounds it by the tolerance
  the receiving caller states), and a closed order goes back to partially
  received when a receipt against it is reversed, so the reversal's effect on
  the lines is recorded under a transition with its reason. Every other rule
  of the first migration stays as it was.

  The migration is self-contained: a database that already ran the first
  migration loads only this file, so the replaced trigger function is
  spelled out here with the transitions it allows, and `down/0` restores the
  original list. `statements/1` mirrors the first migration's contract so
  the module's `test/support/test_fixtures.ex` runs both against temporary
  tables.
  """

  use Ecto.Migration

  @lines "supply_chain_purchasing_order_lines"
  @received_check "supply_chain_purchasing_order_lines_received_quantity"

  @original_transitions [
    {"draft", "submitted"},
    {"draft", "cancelled"},
    {"submitted", "approved"},
    {"submitted", "draft"},
    {"submitted", "cancelled"},
    {"approved", "sent"},
    {"approved", "submitted"},
    {"approved", "cancelled"},
    {"sent", "partially_received"},
    {"sent", "closed"},
    {"sent", "submitted"},
    {"sent", "cancelled"},
    {"partially_received", "closed"},
    {"partially_received", "cancelled"}
  ]

  @order_transitions @original_transitions ++ [{"closed", "partially_received"}]

  @doc "The `{from, to}` order transitions the database allows from this migration on."
  def order_transitions, do: @order_transitions

  def up do
    Enum.each(statements(:permanent), &execute/1)
  end

  def down do
    execute("ALTER TABLE #{@lines} DROP CONSTRAINT #{@received_check}")

    execute(
      "ALTER TABLE #{@lines} ADD CONSTRAINT #{@received_check} " <>
        "CHECK (received_quantity >= 0 AND received_quantity <= quantity)"
    )

    execute(header_rules("", @original_transitions))
  end

  @doc """
  Every DDL statement, in order. `:permanent` alters the real tables and
  functions; `:temporary` alters the temporary copies and `pg_temp` functions
  the first migration's `statements(:temporary)` created.
  """
  @spec statements(:permanent | :temporary) :: [String.t()]
  def statements(mode) when mode in [:permanent, :temporary] do
    fun = if mode == :temporary, do: "pg_temp.", else: ""

    [
      "ALTER TABLE #{@lines} DROP CONSTRAINT #{@received_check}",
      "ALTER TABLE #{@lines} ADD CONSTRAINT #{@received_check} CHECK (received_quantity >= 0)",
      header_rules(fun, @order_transitions)
    ]
  end

  # The first migration's order header rule, with `transitions` as the
  # allowed `(from, to)` pairs.
  defp header_rules(fun, transitions) do
    """
    CREATE OR REPLACE FUNCTION #{fun}supply_chain_purchasing_order_header_rules() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
        OR NEW.order_number <> OLD.order_number
        OR NEW.created_by_user_id <> OLD.created_by_user_id
        OR NEW.created_by_impersonator_id IS DISTINCT FROM OLD.created_by_impersonator_id THEN
        RAISE EXCEPTION 'a purchase order keeps its company, number and creator'
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF OLD.status = 'draft' THEN
        IF NEW.status = OLD.status OR (OLD.status, NEW.status) IN (#{pairs(transitions)}) THEN
          RETURN NEW;
        END IF;

        RAISE EXCEPTION 'a purchase order does not go from % to %', OLD.status, NEW.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF NEW.supplier_id <> OLD.supplier_id OR NEW.currency_code <> OLD.currency_code
        OR NEW.purchase_request_id IS DISTINCT FROM OLD.purchase_request_id THEN
        RAISE EXCEPTION 'purchase order % is %: its supplier, currency and request are fixed',
          OLD.id, OLD.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF NEW.status <> OLD.status THEN
        IF (OLD.status, NEW.status) NOT IN (#{pairs(transitions)}) THEN
          RAISE EXCEPTION 'a purchase order does not go from % to %', OLD.status, NEW.status
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.amendment_count <> OLD.amendment_count THEN
          RAISE EXCEPTION 'a purchase order is not amended in the same change as a transition'
            USING ERRCODE = 'restrict_violation';
        END IF;
      ELSIF NEW.amendment_count = OLD.amendment_count + 1 THEN
        IF OLD.status NOT IN ('approved', 'sent') THEN
          RAISE EXCEPTION 'purchase order % is %: only an approved or sent order is amended',
            OLD.id, OLD.status
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      ELSE
        RAISE EXCEPTION 'purchase order % is %: it changes only by a transition or an amendment',
          OLD.id, OLD.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF NEW.reference IS DISTINCT FROM OLD.reference OR NEW.notes IS DISTINCT FROM OLD.notes
        OR NEW.expected_on IS DISTINCT FROM OLD.expected_on THEN
        RAISE EXCEPTION 'purchase order % is %: its reference, notes and date change only by an amendment',
          OLD.id, OLD.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      RETURN NEW;
    END
    $$
    """
  end

  defp pairs(transitions),
    do: Enum.map_join(transitions, ", ", fn {a, b} -> "('#{a}', '#{b}')" end)
end
