defmodule Hyperliquid.CacheFreshnessTest do
  use ExUnit.Case, async: false

  alias Hyperliquid.Cache

  # Clear the freshness state before each test to ensure isolation.
  # We clear :all_mids, :last_mids_update_at, and :mid_update_times so per-coin
  # freshness tests start from a known empty state.
  setup do
    Cachex.del(:hyperliquid, :all_mids)
    Cachex.del(:hyperliquid, :last_mids_update_at)
    Cachex.del(:hyperliquid, :mid_update_times)
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

  describe "get_mid_fresh/2" do
    test "per-coin staleness — BTC value stuck while ETH updates keep global fresh" do
      Cache.update_mids(%{"BTC" => "100", "ETH" => "200"})
      Process.sleep(50)
      Cache.update_mids(%{"ETH" => "201"})

      assert Cache.mids_fresh?(20)
      assert Cache.get_mid_fresh("ETH", 20) == 201.0
      assert Cache.get_mid_fresh("BTC", 20) == nil
      assert Cache.get_mid_fresh("BTC", 200) == 100.0
    end

    test "get_mid_fresh fails closed when :mid_update_times is missing" do
      Cachex.put(:hyperliquid, :all_mids, %{"BTC" => "100"})
      Cachex.del(:hyperliquid, :mid_update_times)

      assert Cache.get_mid_fresh("BTC", 60_000) == nil
    end

    test "get_mid_fresh returns nil for unknown coin" do
      Cache.update_mids(%{"BTC" => "100"})

      assert Cache.get_mid_fresh("DOGE", 60_000) == nil
    end

    test "get_mid_fresh parses string values" do
      Cache.update_mids(%{"BTC" => "12345.67"})

      assert Cache.get_mid_fresh("BTC", 60_000) == 12_345.67
    end

    test "get_mid_fresh accepts float values" do
      Cache.update_mids(%{"BTC" => 99_000.5})

      assert Cache.get_mid_fresh("BTC", 60_000) == 99_000.5
    end

    test "update_mid (single-coin) sets per-coin timestamp" do
      Cache.update_mid("SOL", "150.0")

      assert Cache.get_mid_fresh("SOL", 1_000) == 150.0
    end

    test "get_mid_fresh returns nil when :all_mids is missing" do
      Cachex.del(:hyperliquid, :all_mids)

      assert Cache.get_mid_fresh("BTC", 60_000) == nil
    end
  end
end
