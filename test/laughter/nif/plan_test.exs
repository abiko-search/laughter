defmodule Laughter.Nif.PlanTest do
  use ExUnit.Case, async: true

  alias Laughter.Nif

  test "native boundary rejects unknown mutation tags" do
    assert_raise ErlangError, ~r/Could not decode field :mutation/, fn ->
      Nif.rewrite_plan("", [%{selector: "p", mutation: :unknown}], "utf-8", 1024)
    end
  end
end
