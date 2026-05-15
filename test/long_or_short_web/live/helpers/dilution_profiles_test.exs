defmodule LongOrShortWeb.Live.DilutionProfilesTest do
  use LongOrShort.DataCase, async: true

  import LongOrShort.TickersFixtures

  alias LongOrShortWeb.Live.DilutionProfiles

  describe "load_for_tickers/1" do
    test "returns a map keyed by ticker_id" do
      t1 = build_ticker()
      t2 = build_ticker()

      result = DilutionProfiles.load_for_tickers([t1.id, t2.id])

      assert Map.has_key?(result, t1.id)
      assert Map.has_key?(result, t2.id)
      assert is_map(result[t1.id])
      assert is_map(result[t2.id])
    end

    test "dedupes the input list (one fetch per unique ticker)" do
      t1 = build_ticker()

      result = DilutionProfiles.load_for_tickers([t1.id, t1.id, t1.id])

      assert map_size(result) == 1
      assert Map.has_key?(result, t1.id)
    end

    test "returns an empty map for an empty input list" do
      assert DilutionProfiles.load_for_tickers([]) == %{}
    end

    test "loads :insufficient profile for tickers with no FilingAnalysis rows" do
      t1 = build_ticker()

      result = DilutionProfiles.load_for_tickers([t1.id])

      assert result[t1.id].data_completeness == :insufficient
    end
  end

  describe "refresh_one/2" do
    test "reloads the entry when the ticker is present in the map" do
      t1 = build_ticker()
      profiles = DilutionProfiles.load_for_tickers([t1.id])

      refreshed = DilutionProfiles.refresh_one(profiles, t1.id)

      assert Map.has_key?(refreshed, t1.id)
      assert refreshed[t1.id].ticker_id == t1.id
    end

    test "returns the map unchanged when the ticker is not present" do
      t1 = build_ticker()
      t2 = build_ticker()
      profiles = DilutionProfiles.load_for_tickers([t1.id])

      assert DilutionProfiles.refresh_one(profiles, t2.id) == profiles
    end

    test "preserves other entries when refreshing one ticker" do
      t1 = build_ticker()
      t2 = build_ticker()
      profiles = DilutionProfiles.load_for_tickers([t1.id, t2.id])

      refreshed = DilutionProfiles.refresh_one(profiles, t1.id)

      assert refreshed[t2.id] == profiles[t2.id]
    end
  end
end
