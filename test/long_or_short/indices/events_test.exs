defmodule LongOrShort.Indices.EventsTest do
  use ExUnit.Case, async: true

  alias LongOrShort.Indices.Events

  describe "subscribe/0 + broadcast/2" do
    test "subscriber receives broadcast message" do
      Events.subscribe()

      payload = %{current: Decimal.new("420.13"), change_pct: Decimal.new("0.84")}
      :ok = Events.broadcast("DJIA", payload)

      assert_receive {:index_tick, "DJIA", ^payload}, 100
    end

    test "non-subscribed processes do not receive the broadcast" do
      :ok = Events.broadcast("DJIA", %{})
      refute_receive {:index_tick, _, _}, 100
    end
  end
end
