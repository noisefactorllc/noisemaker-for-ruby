# frozen_string_literal: true

# Release-gate checks over synthetic parity-summary logs. The gate audits a
# complete summary run before a kit release; these tests pin its verdicts
# without rendering anything (no oracle needed).

require "minitest/autorun"
require "fileutils"
require "json"
require "tempfile"
require "tmpdir"
require_relative "../scripts/release-gate"

class TestReleaseGate < Minitest::Test
  AUTHORITY = %w[filter/adjust filter/crt points/lenia synth/roll synth/solid].freeze
  DECLARED_SKIPS = %w[points/lenia].freeze
  ACCEPTED_FAILURES = %w[filter/crt].freeze
  POLICY = { declared_skips: DECLARED_SKIPS, accepted_failures: ACCEPTED_FAILURES }.freeze

  def evaluate(text, **overrides)
    NoisemakerReleaseGate.evaluate_release_gate(text, authority: AUTHORITY, **POLICY.merge(overrides))
  end

  # A summary output shaped like the real whole-port run: every authority case
  # reported once, the declared skip, and the accepted filter/crt failure.
  def summary_output(verdicts: {}, counts: {}, drop: [], extra: [])
    lines = ["Reference provenance: 0 recorded, #{AUTHORITY.length} unknown"]
    tally = Hash.new(0)
    AUTHORITY.each do |id|
      next if drop.include?(id)

      verdict = verdicts[id]
      verdict ||= DECLARED_SKIPS.include?(id) ? "SKIP" : ACCEPTED_FAILURES.include?(id) ? "FAIL" : "EXACT"
      tally[:expected] += 1
      if %w[EXACT STRICT FAIL].include?(verdict)
        tally[:executed] += 1
        tally[verdict.downcase.to_sym] += 1
      end
      tally[:skip] += 1 if verdict == "SKIP"
      tally[:missing] += 1 if verdict == "MISSING"
      lines << "#{verdict} #{id} (synthetic)"
    end
    lines.concat(extra)
    counts_full = { expected: 0, executed: 0, exact: 0, strict: 0, near: 0, defer: 0, skip: 0, fail: 0, missing: 0 }
    tally.each { |key, value| counts_full[key] = value }
    counts_full.merge!(counts)
    lines << "PARITY-SUMMARY #{JSON.generate({ tolerance: 2 }.merge(counts_full))}"
    "#{lines.join("\n")}\n"
  end

  def test_real_shaped_summary_passes
    result = evaluate(summary_output)
    assert_empty result[:errors]
    assert_equal true, result[:ok]
    assert_equal({ reported: AUTHORITY.length, missing: 0, skip: 1, fail: 1 }, result[:counts])
  end

  def test_missing_case_fails_even_when_counts_are_consistent
    result = evaluate(summary_output(verdicts: { "synth/roll" => "MISSING" }))
    assert_equal false, result[:ok]
    assert(result[:errors].any? { |e| e.start_with?("MISSING synth/roll") }, result[:errors].join("\n"))
    assert(result[:errors].include?("PARITY-SUMMARY missing=1, expected 0"), result[:errors].join("\n"))
  end

  def test_undeclared_skip_fails
    result = evaluate(summary_output(verdicts: { "filter/adjust" => "SKIP" }))
    assert_equal false, result[:ok]
    assert_includes result[:errors], "SKIP filter/adjust is not in the declared skip set"
  end

  def test_declared_skip_that_is_graded_fails_until_the_declaration_drops_it
    result = evaluate(summary_output(verdicts: { "points/lenia" => "EXACT" }))
    assert_equal false, result[:ok]
    assert(
      result[:errors].any? { |e| e.start_with?("declared skip points/lenia was reported EXACT") },
      result[:errors].join("\n")
    )
  end

  def test_failure_other_than_the_accepted_one_fails
    result = evaluate(summary_output(verdicts: { "filter/adjust" => "FAIL" }))
    assert_equal false, result[:ok]
    assert_includes result[:errors], "FAIL filter/adjust is not an accepted failure"
  end

  def test_accepted_failure_that_passes_fails_until_the_declaration_drops_it
    result = evaluate(summary_output(verdicts: { "filter/crt" => "EXACT" }))
    assert_equal false, result[:ok]
    assert(
      result[:errors].any? { |e| e.start_with?("accepted failure filter/crt was reported EXACT") },
      result[:errors].join("\n")
    )
  end

  def test_near_and_deferred_verdict_lines_fail
    result = evaluate(summary_output(verdicts: { "synth/solid" => "NEAR", "synth/roll" => "DEFER" }))
    assert_equal false, result[:ok]
    assert_includes result[:errors], "NEAR synth/solid: a release accepts no near cases"
    assert_includes result[:errors], "DEFER synth/roll: a release accepts no deferred cases"
  end

  def test_unreported_authority_case_fails
    result = evaluate(summary_output(drop: ["filter/adjust"]))
    assert_equal false, result[:ok]
    assert(
      result[:errors].any? { |e| e.start_with?("1 authority cases are not reported: filter/adjust") },
      result[:errors].join("\n")
    )
  end

  def test_duplicate_or_unknown_case_id_fails
    result = evaluate(summary_output(extra: ["EXACT filter/adjust (again)", "EXACT filter/bogus (x)"]))
    assert_equal false, result[:ok]
    assert_includes result[:errors], "filter/adjust is reported more than once"
    assert_includes result[:errors], "filter/bogus is reported but is not an authority-manifest case"
  end

  def test_missing_or_repeated_summary_line_fails
    without_summary = summary_output.lines.reject { |l| l.start_with?("PARITY-SUMMARY") }.join
    assert_includes evaluate(without_summary)[:errors], "expected one PARITY-SUMMARY line, found 0"
    repeated = summary_output + summary_output.lines.grep(/\APARITY-SUMMARY/).join
    assert_includes evaluate(repeated)[:errors], "expected one PARITY-SUMMARY line, found 2"
  end

  def test_summary_counts_that_disagree_with_case_lines_fail
    result = evaluate(summary_output(counts: { skip: 0, expected: AUTHORITY.length - 1 }))
    assert_equal false, result[:ok]
    assert_includes result[:errors], "PARITY-SUMMARY skip=0, expected 1"
    assert_includes result[:errors], "PARITY-SUMMARY expected=#{AUTHORITY.length - 1}, expected #{AUTHORITY.length}"
  end

  def test_summary_line_that_is_not_json_fails
    text = "EXACT synth/solid (x)\nPARITY-SUMMARY not-json\n"
    assert(evaluate(text)[:errors].first.start_with?("PARITY-SUMMARY line is not JSON"))
  end

  def test_strict_verdicts_fail
    result = evaluate(summary_output(verdicts: { "synth/solid" => "STRICT" }))
    assert_equal false, result[:ok]
    assert(
      result[:errors].any? { |e| e.start_with?("STRICT synth/solid: a release accepts no strict cases") },
      result[:errors].join("\n")
    )
    assert_includes result[:errors], "PARITY-SUMMARY strict=1, expected 0"
  end

  def test_cli_requires_explicit_declarations
    assert_raises(TypeError) { NoisemakerReleaseGate.parse_args(["log.txt", "--accepted-failures", "filter/crt"]) }
    assert_raises(TypeError) { NoisemakerReleaseGate.parse_args(["log.txt", "--declared-skips", ""]) }
    assert_equal(
      { log: "log.txt", declared_skips: [], accepted_failures: ["filter/crt"] },
      NoisemakerReleaseGate.parse_args(["log.txt", "--declared-skips", "", "--accepted-failures", "filter/crt"])
    )
    assert_raises(TypeError) { NoisemakerReleaseGate.parse_args(["log.txt", "--bogus"]) }
    assert_raises(TypeError) { NoisemakerReleaseGate.parse_args(["one.txt", "two.txt", "--declared-skips", "", "--accepted-failures", ""]) }
    assert_raises(TypeError) do
      NoisemakerReleaseGate.evaluate_release_gate(summary_output, declared_skips: DECLARED_SKIPS, accepted_failures: nil,
                                                                    authority: AUTHORITY)
    end
    unknown = NoisemakerReleaseGate.evaluate_release_gate(
      summary_output, declared_skips: DECLARED_SKIPS + ["filter/bogus"],
                      accepted_failures: ACCEPTED_FAILURES, authority: AUTHORITY
    )
    assert_includes unknown[:errors], "declared case filter/bogus is not an authority-manifest case"
  end

  def test_cli_passes_the_real_shaped_summary_and_fails_a_missing_case
    # The CLI reads the authority manifest from the pinned oracle snapshot; a
    # fake snapshot dir exercises that path without a real oracle checkout.
    Dir.mktmpdir do |oracle_dir|
      snapshot = File.join(oracle_dir, "src", "effects", "generated")
      FileUtils.mkdir_p(snapshot)
      File.write(File.join(snapshot, "upstream-snapshot.js"),
                 "module.exports = { sourceEffectIds: #{JSON.generate(AUTHORITY)} }")
      gate = File.expand_path("../scripts/release-gate.rb", __dir__)
      Tempfile.create("release-gate-test") do |log|
        path = log.path
        File.write(path, summary_output)
        cmd = "env NOISEMAKER_CPU_DIR=#{oracle_dir} ruby #{gate} #{path} " \
              "--declared-skips '#{DECLARED_SKIPS.join(' ')}' --accepted-failures '#{ACCEPTED_FAILURES.join(' ')}'"
        output = `#{cmd}`
        assert_equal 0, $?.exitstatus, output
        assert_includes output, "release gate: PASS"

        File.write(path, summary_output(verdicts: { "synth/roll" => "MISSING" }))
        output = `env NOISEMAKER_CPU_DIR=#{oracle_dir} ruby #{gate} #{path} --declared-skips '' --accepted-failures '' 2>&1`
        refute_equal 0, $?.exitstatus, output
        assert_includes output, "MISSING synth/roll: a release needs zero missing cases"
      end
    end
  end
end
