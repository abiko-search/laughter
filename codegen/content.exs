defmodule Laughter.Codegen.Content do
  @moduledoc false

  defmacro mutation_type do
    content =
      for operation <- Laughter.Rewriter.Content.operations() do
        {operation.name, [quote(do: String.t())]}
      end

    variants =
      [
        remove: [],
        set_attribute: [quote(do: attribute())],
        remove_attribute: [quote(do: String.t())]
      ] ++
        content

    quote do
      @type mutation :: RustQ.Type.enum(unquote(variants))
    end
  end

  defmacro dispatch(element, mutation) do
    arms =
      for operation <- Laughter.Rewriter.Content.operations() do
        call =
          quote do
            unquote(element).unquote(operation.method)(
              content,
              enum_variant(ContentType, unquote(operation.format))
            )
          end

        if operation.inner? do
          quote do
            enum_variant(Mutation, unquote(operation.name), content)
            when not unquote(element).removed() ->
              unquote(call)
          end
        else
          quote do
            enum_variant(Mutation, unquote(operation.name), content) -> unquote(call)
          end
        end
      end

    fallback = quote do: (_ -> {})
    {:case, [], [mutation, [do: List.flatten(arms) ++ fallback]]}
  end
end
