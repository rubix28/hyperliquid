defmodule Hyperliquid.CacheFreshnessTest do
  use ExUnit.Case, async: false

  alias Hyperliquid.Cache

  # Clear the freshness timestamp before each test to ensure isolation.
  # The :all_mids cache entry may exist from other tests, but that's fine —
  # we're specifically testing the :last_mids_update_at key.
  setup do
    Cachex.del(:hyperliquid, :last_mids_update_at)
    :ok
  end

  describe "mids_age_ms/0" do
    test "returns :infinity when mids never updated (no timestamp)" do
      assert Cache.mids_age_ms() == :infinity
    end

    test "returns age in ms after update_mids/1" do
      Cache.update_mids(%{"BTC" => "95000.0"})
      age = Cache.mids_age_ms()
      assert is_integer(age)
      assert age >= 0
      assert age < 1000
    end

    test "age increases over time" do
      Cache.update_mids(%{"BTC" => "95000.0"})
      Process.sleep(50)
      age = Cache.mids_age_ms()
      assert age >= 50
    end
  end

  describe "mids_fresh?/1" do
    test "returns false when mids never updated" do
      refute Cache.mids_fresh?(30_000)
    end

    test "returns true immediately after update" do
      Cache.update_mids(%{"BTC" => "95000.0"})
      assert Cache.mids_fresh?(30_000)
    end

    test "returns false after threshold exceeded" do
      Cache.update_mids(%{"BTC" => "95000.0"})
      Process.sleep(60)
      refute Cache.mids_fresh?(50)
    end

    test "returns true with generous threshold" do
      Cache.update_mids(%{"BTC" => "95000.0"})
      Process.sleep(10)
      assert Cache.mids_fresh?(5_000)
    end
  end

  describe "update_mid/2 also updates freshness" do
    test "single mid update refreshes timestamp" do
      Cache.update_mid("ETH", "3500.0")
      assert Cache.mids_fresh?(1_000)
    end
  end
end
