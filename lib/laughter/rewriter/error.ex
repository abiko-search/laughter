defmodule Laughter.Rewriter.Error do
  @moduledoc "Raised when a native rewrite fails while enumerating a rewrite stream."

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "HTML rewriting failed: #{inspect(reason)}"
  end
end
