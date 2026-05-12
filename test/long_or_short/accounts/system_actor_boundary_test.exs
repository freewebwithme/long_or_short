defmodule LongOrShort.Accounts.SystemActorBoundaryTest do
  use ExUnit.Case, async: true

  @web_dir Path.join([File.cwd!(), "lib", "long_or_short_web"])

  @doc """
  Structural guard for LON-15. `SystemActor` bypasses every resource policy that
  uses `bypass actor_attribute_equals(:system?, true)` — one accidental
  `actor: SystemActor.new()` in a controller / LiveView / channel handler is a
  full privilege escalation.

  Until the migration to `public? false + private_action?()` lands, this test
  fails fast on any reference in `lib/long_or_short_web/`. If you legitimately
  need to widen this boundary, do it in `lib/long_or_short/`, not in web.
  """
  test "no SystemActor references in lib/long_or_short_web/" do
    offenders =
      @web_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           """
           SystemActor must not be referenced in the web layer. Offending lines:

           #{Enum.map_join(offenders, "\n", fn {path, line, content} -> "  #{path}:#{line}  #{content}" end)}

           If a web-layer code path genuinely needs system privileges, the
           correct fix is to expose a dedicated user-facing action with proper
           policies — not to construct a SystemActor. See LON-15.
           """
  end

  defp scan_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _} -> String.contains?(line, "SystemActor") end)
    |> Enum.map(fn {line, lineno} ->
      {Path.relative_to_cwd(path), lineno, String.trim(line)}
    end)
  end
end
