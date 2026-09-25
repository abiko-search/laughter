defmodule Laughter.Rewriter.Content do
  @moduledoc false

  # Shared by public builder generation and RustQ's mutation schema/dispatch.
  @placements [
    {:prepend, :prepend, true, "Prepends content inside matched elements."},
    {:append, :append, true, "Appends content inside matched elements."},
    {:before, :before, false, "Inserts content before matched elements."},
    {:after, :after, false, "Inserts content after matched elements."},
    {:replace, :replace, false, "Replaces matched elements and their content."},
    {:set_inner, :set_inner_content, true, "Replaces the content inside matched elements."}
  ]

  def operations do
    for {prefix, method, inner?, description} <- @placements, format <- [:text, :html] do
      %{
        name: String.to_atom("#{prefix}_#{format}"),
        method: method,
        format: format,
        inner?: inner?,
        description: description
      }
    end
  end

  defmacro builders do
    operations = operations()
    names = Enum.map(operations, & &1.name)
    union = Enum.reduce(names, fn name, union -> {:|, [], [union, name]} end)

    builders =
      for operation <- operations do
        escaping =
          case operation.format do
            :text -> "Escapes `&`, `<`, and `>` before insertion."
            :html -> "Inserts HTML verbatim; only pass trusted markup."
          end

        doc =
          "#{operation.description} #{escaping}\n\nContent must be UTF-8 iodata, regardless of the document encoding."

        quote do
          @doc unquote(doc)
          @spec unquote(operation.name)(t(), String.t(), iodata()) :: t()
          def unquote(operation.name)(%__MODULE__{} = plan, selector, content)
              when is_binary(selector) do
            content = IO.iodata_to_binary(content)

            unless String.valid?(content) do
              raise ArgumentError, "rewrite content must be valid UTF-8"
            end

            add_rule(plan, selector, {unquote(operation.name), content})
          end
        end
      end

    quote do
      @type content_operation :: unquote(union)
      unquote_splicing(builders)
    end
  end
end
