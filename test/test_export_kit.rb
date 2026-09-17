# frozen_string_literal: true

require "minitest/autorun"
require "json"

class TestExportKit < Minitest::Test
  def test_export_kit_config_points_to_valid_metadata
    config_path = File.expand_path("../export-kit/kit.config.json", __dir__)
    assert File.exist?(config_path), "export-kit/kit.config.json must exist"
    config = JSON.parse(File.read(config_path))

    metadata_rel = config.dig("compat", "fromBundleMetadata")
    assert metadata_rel, "compat.fromBundleMetadata must be configured"
    metadata_path = File.expand_path("../#{metadata_rel}", __dir__)
    assert File.exist?(metadata_path), "#{metadata_rel} must exist"

    metadata = JSON.parse(File.read(metadata_path))
    assert_equal 208, metadata.fetch("effects").length, "expected 208 bundled effects"
  end
end
