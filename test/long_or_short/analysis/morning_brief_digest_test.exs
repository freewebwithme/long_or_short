defmodule LongOrShort.Analysis.MorningBriefDigestTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.AccountsFixtures

  alias LongOrShort.Accounts.SystemActor
  alias LongOrShort.Analysis

  # Local fixture helpers. Lift to `AnalysisFixtures` when LON-151 /
  # LON-152 need them too — for now this test is the only consumer.

  defp valid_digest_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        bucket_date: ~D[2026-05-12],
        bucket: :premarket,
        content: "오늘 8:30 ET CPI 발표 후 시장 약세. [1] [2]",
        citations: [
          %{
            idx: 1,
            url: "https://www.cnbc.com/abc",
            title: "CNBC headline",
            source: "cnbc.com",
            cited_text: "snippet",
            accessed_at: DateTime.utc_now()
          }
        ],
        llm_provider: :anthropic,
        llm_model: "claude-haiku-4-5-20251001",
        input_tokens: 30_000,
        output_tokens: 800,
        search_calls: 3,
        raw_response: %{"sample" => true}
      },
      overrides
    )
  end

  defp build_digest(overrides \\ %{}) do
    case Analysis.upsert_digest(valid_digest_attrs(overrides), authorize?: false) do
      {:ok, d} -> d
      {:error, err} -> raise "build_digest failed: #{inspect(err)}"
    end
  end

  describe "upsert_digest/2" do
    test "creates a row with valid attrs and stamps generated_at" do
      {:ok, d} = Analysis.upsert_digest(valid_digest_attrs(), authorize?: false)

      assert d.bucket == :premarket
      assert d.bucket_date == ~D[2026-05-12]
      assert d.content =~ "CPI"
      assert d.llm_provider == :anthropic
      assert d.search_calls == 3
      assert %DateTime{} = d.generated_at
    end

    test "applies defaults for token counters and citations" do
      attrs =
        valid_digest_attrs()
        |> Map.drop([:input_tokens, :output_tokens, :search_calls, :citations])

      {:ok, d} = Analysis.upsert_digest(attrs, authorize?: false)

      assert d.input_tokens == 0
      assert d.output_tokens == 0
      assert d.search_calls == 0
      assert d.citations == []
    end

    test "rejects invalid bucket" do
      attrs = valid_digest_attrs(%{bucket: :midday})

      assert {:error, %Ash.Error.Invalid{} = err} =
               Analysis.upsert_digest(attrs, authorize?: false)

      assert error_on_field?(err, :bucket)
    end

    test "rejects invalid llm_provider" do
      attrs = valid_digest_attrs(%{llm_provider: :openai})

      assert {:error, %Ash.Error.Invalid{} = err} =
               Analysis.upsert_digest(attrs, authorize?: false)

      assert error_on_field?(err, :llm_provider)
    end

    test "rejects missing required content" do
      attrs = valid_digest_attrs() |> Map.delete(:content)

      assert {:error, %Ash.Error.Invalid{} = err} =
               Analysis.upsert_digest(attrs, authorize?: false)

      assert error_on_field?(err, :content)
    end
  end

  describe "unique_slot identity" do
    test "second upsert with same (bucket_date, bucket) updates the same row" do
      first = build_digest()

      attrs =
        valid_digest_attrs(%{
          content: "Updated brief content.",
          search_calls: 5,
          input_tokens: 45_000
        })

      {:ok, second} = Analysis.upsert_digest(attrs, authorize?: false)

      assert first.id == second.id
      assert second.content == "Updated brief content."
      assert second.search_calls == 5
      assert second.input_tokens == 45_000
    end

    test "different bucket on same date produces two rows" do
      a = build_digest(%{bucket: :overnight})
      b = build_digest(%{bucket: :premarket})

      refute a.id == b.id
      assert a.bucket == :overnight
      assert b.bucket == :premarket
    end

    test "same bucket on different date produces two rows" do
      a = build_digest(%{bucket_date: ~D[2026-05-12]})
      b = build_digest(%{bucket_date: ~D[2026-05-13]})

      refute a.id == b.id
    end
  end

  describe "get_digest/3" do
    test "returns the row for an existing slot" do
      digest = build_digest()

      {:ok, found} =
        Analysis.get_digest(digest.bucket_date, digest.bucket, authorize?: false)

      assert found.id == digest.id
    end

    test "returns nil for a missing slot (not_found_error?: false)" do
      assert {:ok, nil} =
               Analysis.get_digest(~D[1999-01-01], :overnight, authorize?: false)
    end
  end

  describe "list_digests/1" do
    test "returns rows newest-first via :recent action" do
      _older = build_digest(%{bucket: :overnight})
      newer = build_digest(%{bucket: :premarket})

      # `pagination required?: false` — without a `page:` opt the
      # action returns a plain list. Callers (cost dashboard) typically
      # don't paginate; pass `page: [limit: N]` to get a Keyset.
      {:ok, [first | _]} = Analysis.list_digests(authorize?: false)

      # UUIDv7 timestamp-ordered → newer has greater id → comes first
      assert first.id == newer.id
    end
  end

  describe "policies" do
    setup do
      digest = build_digest()
      {:ok, digest: digest}
    end

    test "SystemActor can upsert" do
      assert {:ok, _} =
               Analysis.upsert_digest(
                 valid_digest_attrs(%{bucket: :overnight}),
                 actor: SystemActor.new()
               )
    end

    test "admin can upsert" do
      admin = build_admin_user()

      assert {:ok, _} =
               Analysis.upsert_digest(
                 valid_digest_attrs(%{bucket: :after_open}),
                 actor: admin
               )
    end

    test "any authenticated trader can read (shared digest)",
         %{digest: digest} do
      trader = build_trader_user()

      {:ok, found} =
        Analysis.get_digest(digest.bucket_date, digest.bucket, actor: trader)

      assert found.id == digest.id
    end

    test "two distinct traders both see the same row", %{digest: digest} do
      a = build_trader_user()
      b = build_trader_user()

      {:ok, fa} = Analysis.get_digest(digest.bucket_date, digest.bucket, actor: a)
      {:ok, fb} = Analysis.get_digest(digest.bucket_date, digest.bucket, actor: b)

      assert fa.id == digest.id
      assert fb.id == digest.id
    end

    test "trader cannot upsert" do
      trader = build_trader_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Analysis.upsert_digest(
                 valid_digest_attrs(%{bucket: :overnight}),
                 actor: trader
               )
    end

    test "nil actor sees nil even when the slot has a row", %{digest: digest} do
      # `actor_present()` policy combines with `get?: true` such that an
      # unauthenticated read returns `{:ok, nil}` — the filter check
      # excludes every row, then `get?` collapses an empty result to
      # nil. Same surface as NewsAnalysis's per-user policy. No info
      # leak because the result is identical regardless of whether a
      # row exists for that slot.
      assert {:ok, nil} =
               Analysis.get_digest(digest.bucket_date, digest.bucket, actor: nil)
    end
  end
end
