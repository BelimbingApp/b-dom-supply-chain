defmodule Bilimbi.SupplyChain.Receiving.Web.FormsTest do
  use ExUnit.Case, async: true

  alias Bilimbi.SupplyChain.Receiving.Web.Forms

  describe "lines_from_params/1" do
    test "keys rows by order line, in order, and leaves out rows without a quantity" do
      lines = %{
        "30" => %{"received_quantity" => "", "rejected_quantity" => "2", "rejection_reason" => "x"},
        "12" => %{"received_quantity" => "4", "rejected_quantity" => ""},
        "7" => %{"received_quantity" => " ", "rejected_quantity" => "", "rejection_reason" => "y"},
        "abc" => %{"received_quantity" => "9"}
      }

      assert Forms.lines_from_params(lines) == [
               %{"order_line_id" => 12, "received_quantity" => "4", "rejected_quantity" => ""},
               %{
                 "order_line_id" => 30,
                 "received_quantity" => "",
                 "rejected_quantity" => "2",
                 "rejection_reason" => "x"
               }
             ]
    end

    test "tolerates a missing or malformed lines param" do
      assert Forms.lines_from_params(nil) == []
      assert Forms.lines_from_params(%{"1" => "not a row"}) == []
    end
  end
end
