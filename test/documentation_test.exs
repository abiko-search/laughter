defmodule DocumentationTest do
  # File examples change the VM-wide working directory. Each block gets fresh
  # bindings so examples cannot accidentally depend on an earlier snippet.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @root Path.expand("..", __DIR__)

  for document <- ["README.md", "guides/parsing.md", "guides/rewriting.md", "guides/sessions.md"] do
    @document document
    test "Elixir examples in #{document} run independently" do
      markdown = File.read!(Path.join(@root, @document))

      examples =
        Regex.scan(~r/```elixir\n(.*?)\n```/s, markdown, capture: :all_but_first)
        |> Enum.map(&hd/1)
        # A dependency declaration belongs inside the consumer's Mix project.
        |> Enum.reject(&String.starts_with?(&1, "def deps do"))

      assert examples != []

      directory =
        Path.join(System.tmp_dir!(), "laughter-docs-#{System.unique_integer([:positive])}")

      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)

      File.cd!(directory, fn ->
        File.write!("input.html", "<script>bad()</script><p>keep</p>")

        capture_io(fn ->
          for {code, index} <- Enum.with_index(examples, 1) do
            {result, _} = Code.eval_string(code, [], file: "#{@document} example #{index}")

            case result do
              {:ok, pid} when is_pid(pid) -> Supervisor.stop(pid)
              _ -> :ok
            end
          end
        end)

        if @document == "README.md" do
          assert File.read!("output.html") == "<p>keep</p>"
        end
      end)
    end
  end
end
