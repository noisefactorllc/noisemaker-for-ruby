#!/usr/bin/env ruby
# frozen_string_literal: true

# Release gate over a complete `scripts/parity-summary` output. A kit release
# runs it after the summary and releases a kit only when it exits 0.
#
# The gate passes only when all of these are true:
#   - the output ends its run with one PARITY-SUMMARY line;
#   - every authority-manifest case is reported exactly once, and no other id is;
#   - no case is MISSING and the near and defer counts are zero;
#   - the SKIP cases are exactly the declared skip set (an undeclared skip fails,
#     and a declared skip that is no longer skipped fails until it is undeclared);
#   - the FAIL cases are exactly the accepted failures;
#   - the PARITY-SUMMARY counts agree with the per-case verdict lines.
#
# The declared skip set and the accepted failures are arguments, so the release
# procedure that runs the gate states them. This port currently has no skip
# policy and no accepted failure: every authority case must render byte-exact.

require "json"
require "open3"
require "set"

module NoisemakerReleaseGate
  VERDICT = /\A(EXACT|STRICT|FAIL|SKIP|MISSING|NEAR|DEFER) (\S+)/
  SUMMARY = /\APARITY-SUMMARY (.*)\z/m

  module_function

  def parse_summary_output(text)
    verdicts = {}
    duplicates = []
    summaries = []
    text.split(/\r?\n/).each do |line|
      if (summary_match = SUMMARY.match(line))
        summaries << summary_match[1]
        next
      end
      next unless (match = VERDICT.match(line))

      verdict, id = match.captures
      duplicates << id if verdicts.key?(id)
      verdicts[id] = verdict
    end
    { verdicts: verdicts, duplicates: duplicates, summaries: summaries }
  end

  def evaluate_release_gate(text, declared_skips:, accepted_failures:, authority:)
    raise TypeError, "evaluate_release_gate needs explicit declared_skips and accepted_failures arrays" unless
      declared_skips.is_a?(Array) && accepted_failures.is_a?(Array)

    errors = []
    parsed = parse_summary_output(text)
    verdicts = parsed[:verdicts]
    duplicates = parsed[:duplicates]
    summaries = parsed[:summaries]
    authority_set = authority.to_set

    (declared_skips + accepted_failures).each do |id|
      errors << "declared case #{id} is not an authority-manifest case" unless authority_set.include?(id)
    end

    summary = nil
    if summaries.length != 1
      errors << "expected one PARITY-SUMMARY line, found #{summaries.length}"
    else
      begin
        summary = JSON.parse(summaries.first)
      rescue JSON::ParserError => e
        errors << "PARITY-SUMMARY line is not JSON: #{e.message}"
      end
    end

    duplicates.each { |id| errors << "#{id} is reported more than once" }
    verdicts.each_key do |id|
      errors << "#{id} is reported but is not an authority-manifest case" unless authority_set.include?(id)
    end
    unreported = authority.reject { |id| verdicts.key?(id) }
    errors << "#{unreported.length} authority cases are not reported: #{unreported.join(', ')}" unless unreported.empty?

    by_verdict = lambda do |verdict|
      verdicts.select { |_id, value| value == verdict }.keys.sort
    end
    missing = by_verdict.call("MISSING")
    skips = by_verdict.call("SKIP")
    fails = by_verdict.call("FAIL")
    near = by_verdict.call("NEAR")
    defer = by_verdict.call("DEFER")

    missing.each { |id| errors << "MISSING #{id}: a release needs zero missing cases" }
    near.each { |id| errors << "NEAR #{id}: a release accepts no near cases" }
    defer.each { |id| errors << "DEFER #{id}: a release accepts no deferred cases" }

    declared_skip_set = declared_skips.to_set
    skips.each do |id|
      errors << "SKIP #{id} is not in the declared skip set" unless declared_skip_set.include?(id)
    end
    declared_skips.each do |id|
      next unless verdicts.key?(id) && verdicts[id] != "SKIP"

      errors << "declared skip #{id} was reported #{verdicts[id]}; remove it from the declared skip set"
    end

    accepted_failure_set = accepted_failures.to_set
    fails.each do |id|
      errors << "FAIL #{id} is not an accepted failure" unless accepted_failure_set.include?(id)
    end
    accepted_failures.each do |id|
      next unless verdicts.key?(id) && verdicts[id] != "FAIL"

      errors << "accepted failure #{id} was reported #{verdicts[id]}; remove it from the accepted failures"
    end

    if summary
      exacts = by_verdict.call("EXACT")
      stricts = by_verdict.call("STRICT")
      expected_counts = {
        "expected" => authority.length,
        "executed" => exacts.length + stricts.length + fails.length,
        "exact" => exacts.length,
        "strict" => stricts.length,
        "near" => 0,
        "defer" => 0,
        "skip" => skips.length,
        "fail" => fails.length,
        "missing" => 0
      }
      expected_counts.each do |key, value|
        errors << "PARITY-SUMMARY #{key}=#{summary[key]}, expected #{value}" unless summary[key] == value
      end
      unless summary["expected"] == summary["executed"].to_i + summary["skip"].to_i + summary["missing"].to_i
        errors << "PARITY-SUMMARY expected does not equal executed + skip + missing"
      end
    end

    {
      ok: errors.empty?,
      errors: errors,
      counts: { reported: verdicts.length, missing: missing.length, skip: skips.length, fail: fails.length }
    }
  end

  # The authority case set is the current authority's full manifest, recorded
  # by the pinned oracle's upstream snapshot (the same source scripts/
  # parity-summary.rb reads).
  def authority_ids
    oracle_dir = ENV["NOISEMAKER_CPU_DIR"] || File.expand_path("../../noisemaker-for-cpu", __dir__)
    snapshot_path = File.join(oracle_dir, "src", "effects", "generated", "upstream-snapshot.js")
    raise "release gate: no pinned oracle checkout; cannot read the authority manifest " \
          "(set NOISEMAKER_CPU_DIR to the pinned noisemaker-for-cpu revision)" unless
      oracle_dir && File.file?(snapshot_path)

    out, err, status = Open3.capture3(
      "node", "-e",
      "const m = require(process.argv[1]); console.log(JSON.stringify((m.default || m).sourceEffectIds))",
      snapshot_path
    )
    raise "release gate: cannot read the authority manifest from the pinned oracle:\n#{err}" unless status.success?

    JSON.parse(out)
  end

  def parse_list(value, flag)
    raise TypeError, "#{flag} needs a value (use '' for none)" if value.nil?

    value.split(/[\s,]+/).reject(&:empty?)
  end

  def parse_args(argv)
    log = nil
    declared_skips = nil
    accepted_failures = nil
    index = 0
    while index < argv.length
      argument = argv[index]
      case argument
      when "--declared-skips"
        declared_skips = parse_list(argv[index + 1], argument)
        index += 2
      when "--accepted-failures"
        accepted_failures = parse_list(argv[index + 1], argument)
        index += 2
      when /\A--/
        raise TypeError, "Unknown release-gate option #{argument}"
      else
        raise TypeError, "Unexpected argument #{argument}" unless log.nil?

        log = argument
        index += 1
      end
    end
    raise TypeError, "usage: release-gate.rb <parity-summary log> --declared-skips <ids> --accepted-failures <ids>" if log.nil?
    raise TypeError, "--declared-skips is required" if declared_skips.nil?
    raise TypeError, "--accepted-failures is required" if accepted_failures.nil?

    { log: log, declared_skips: declared_skips, accepted_failures: accepted_failures }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    parsed = NoisemakerReleaseGate.parse_args(ARGV)
    text = File.read(parsed[:log])
    result = NoisemakerReleaseGate.evaluate_release_gate(
      text,
      declared_skips: parsed[:declared_skips],
      accepted_failures: parsed[:accepted_failures],
      authority: NoisemakerReleaseGate.authority_ids
    )
    counts = result[:counts]
    puts "release gate: #{counts[:reported]} cases reported, missing #{counts[:missing]}, " \
         "skip #{counts[:skip]} (declared #{parsed[:declared_skips].length}), " \
         "fail #{counts[:fail]} (accepted #{parsed[:accepted_failures].length})"
    result[:errors].each { |error| puts "::error::#{error}" }
    puts result[:ok] ? "release gate: PASS" : "release gate: FAIL (#{result[:errors].length} findings)"
    exit(result[:ok] ? 0 : 1)
  rescue StandardError => e
    warn "#{e.class}: #{e.message}"
    exit 2
  end
end
