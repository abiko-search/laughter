defmodule Laughter.Rewriter.Legacy do
  @moduledoc false
  @type config :: reference()
  @type handler_id :: non_neg_integer()
  @type element_handler :: Laughter.Rewriter.element_handler()
  @type text_handler :: Laughter.Rewriter.text_handler()
  @type element_mutation :: Laughter.Rewriter.element_mutation()
  @type text_mutation :: Laughter.Rewriter.text_mutation()
  @doc "Create a new rewriter configuration."
  @spec new(keyword()) :: config()
  def new(opts \\ []) do
    encoding = Keyword.get(opts, :encoding, "utf-8")
    max_memory = Keyword.get(opts, :max_memory, 1_048_576)
    Laughter.Nif.rewriter_new(encoding, max_memory)
  end

  @doc "Register an element handler for a CSS selector."
  @spec on_element(config(), String.t(), element_handler()) :: handler_id()
  def on_element(config, selector, handler) do
    id = Laughter.Nif.rewriter_on_element(config, selector)
    Process.put({__MODULE__, :handler, id}, {:element, handler})
    id
  end

  @doc "Register a text handler for a CSS selector."
  @spec on_text(config(), String.t(), text_handler()) :: handler_id()
  def on_text(config, selector, handler) do
    id = Laughter.Nif.rewriter_on_text(config, selector)
    Process.put({__MODULE__, :handler, id}, {:text, handler})
    id
  end

  @doc "Run the rewriter on HTML input. Returns `{:ok, binary}` or `{:error, reason}`.\n\nThis blocks the calling process until rewriting is complete,\ncalling registered handlers for each matched element/text node.\n"
  @spec rewrite(config(), iodata()) :: {:ok, binary()} | {:error, term()}
  def rewrite(config, html) do
    data = IO.iodata_to_binary(html)
    handle = Laughter.Nif.rewriter_write(config, data)
    poll_loop(handle)
  end

  defp poll_loop(handle) do
    case Laughter.Nif.rewriter_poll(handle) do
      {:element, handler_id, tag, attrs} ->
        mutations = dispatch_element(handler_id, tag, attrs)
        Laughter.Nif.rewriter_respond(handle, encode_mutations(mutations))
        poll_loop(handle)

      {:text, handler_id, content, last_in_text_node} ->
        mutations = dispatch_text(handler_id, content, last_in_text_node)
        Laughter.Nif.rewriter_respond(handle, encode_mutations(mutations))
        poll_loop(handle)

      :done ->
        output = Laughter.Nif.rewriter_output(handle)
        {:ok, IO.iodata_to_binary(output)}

      {:error, reason} ->
        {:error, reason}

      :pending ->
        Process.sleep(0)
        poll_loop(handle)
    end
  end

  defp dispatch_element(handler_id, tag, attrs) do
    case Process.get({__MODULE__, :handler, handler_id}) do
      {:element, handler} -> handler.(tag, attrs)
      _ -> []
    end
  end

  defp dispatch_text(handler_id, content, last_in_text_node) do
    case Process.get({__MODULE__, :handler, handler_id}) do
      {:text, handler} -> handler.(content, last_in_text_node)
      _ -> []
    end
  end

  defp encode_mutations(mutations) do
    Enum.map(mutations, fn
      {:set_attribute, name, value} -> {"set_attribute", name, value}
      {:remove_attribute, name} -> {"remove_attribute", name, ""}
      {:prepend_html, html} -> {"prepend_html", html, ""}
      {:prepend_text, text} -> {"prepend_text", text, ""}
      {:append_html, html} -> {"append_html", html, ""}
      {:append_text, text} -> {"append_text", text, ""}
      {:before_html, html} -> {"before_html", html, ""}
      {:before_text, text} -> {"before_text", text, ""}
      {:after_html, html} -> {"after_html", html, ""}
      {:after_text, text} -> {"after_text", text, ""}
      {:set_inner_html, html} -> {"set_inner_html", html, ""}
      {:set_inner_text, text} -> {"set_inner_text", text, ""}
      {:replace_html, html} -> {"replace_html", html, ""}
      {:replace_text, text} -> {"replace_text", text, ""}
      :remove -> {"remove", "", ""}
      :noop -> {"noop", "", ""}
      _ -> {"noop", "", ""}
    end)
  end
end
