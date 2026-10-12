defmodule Bilimbi.SupplyChain.Purchasing.Web.FormsTest do
  use ExUnit.Case, async: true

  alias Bilimbi.SupplyChain.Purchasing.Web.Forms

  describe "lines_from_params/1" do
    test "returns posted rows in numeric order without blank ones" do
      lines = %{
        "10" => %{"description" => "last"},
        "2" => %{"description" => "second"},
        "1" => %{"description" => "  "},
        "0" => %{"description" => "first"}
      }

      assert Forms.lines_from_params(lines) == [
               %{"description" => "first"},
               %{"description" => "second"},
               %{"description" => "last"}
             ]
    end

    test "ignores rows whose index is not a number instead of crashing" do
      lines = %{"0" => %{"description" => "kept"}, "abc" => %{"description" => "forged"}}

      assert Forms.lines_from_params(lines) == [%{"description" => "kept"}]
    end
  end
end
