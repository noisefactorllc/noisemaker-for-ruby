# frozen_string_literal: true

# The 2.x branch's workflow contract.
#
# The test jobs admit `2.x`: the push gate runs on every push to `2.x`, and no
# test job's condition holds it to `main`. Every release, notice or dispatch
# job runs only for `main`. A job runs only for `main` when its condition names
# `refs/heads/main` or a `workflow_run` head branch of `main`, or when every
# trigger of its workflow is a `schedule` (which runs only from the default
# branch) or a `push` or `workflow_run` filtered to `main` alone. A workflow
# that holds both test jobs and release jobs admits `2.x` in its triggers, so
# its release jobs must run only for `main` by their condition.
#
# The workflows are read as text, by indentation, so the check needs no YAML
# library.

require "minitest/autorun"

class TestWorkflowContract < Minitest::Test
  WORKFLOWS = File.expand_path("../.github/workflows", __dir__)

  # Test jobs, by workflow, that must admit 2.x. The push gate (test) runs on
  # every push; parity and windows run on the schedule and on dispatch.
  TEST_JOBS = { "export-kit.yml" => %w[test parity windows] }.freeze
  # Release, notice or dispatch jobs, by workflow, that must run only for main.
  RELEASE_JOBS = { "export-kit.yml" => %w[dispatch] }.freeze

  MAIN_ONLY_CONDITIONS = [
    /github\.ref\s*==\s*'refs\/heads\/main'/,
    /github\.event\.workflow_run\.head_branch\s*==\s*'main'/
  ].freeze

  def self.unquote(text)
    text.gsub(/\A['"]+|['"]+\z/, "")
  end

  # Each meaningful line as [indent, text], without comments or blank lines.
  def self.lines(name)
    found = []
    File.read(File.join(WORKFLOWS, name), encoding: "UTF-8").split(/\r\n|\r|\n/).each do |raw|
      raw = raw.sub(/\s+#[^'"]*\z/, "")
      next if raw.strip.empty? || raw.lstrip.start_with?("#")

      found << [raw.length - raw.sub(/\A +/, "").length, raw.strip]
    end
    found
  end

  # Return [key, value, index] for each key one level below lines[start].
  def self.children(all, start, indent)
    found = []
    child = nil
    ((start + 1)...all.length).each do |index|
      depth, text = all[index]
      break if depth <= indent

      child ||= depth
      next unless depth == child && !text.start_with?("- ")

      key, _, value = text.partition(":")
      found << [unquote(key.strip), value.strip, index]
    end
    found
  end

  # The scalar at lines[index]: inline, or a folded or literal block.
  def self.block(all, index)
    depth, text = all[index]
    value = text.partition(":")[2].strip
    return value unless [">", "|"].include?(value[0, 1])

    parts = []
    ((index + 1)...all.length).each do |later|
      break if all[later][0] <= depth

      parts << all[later][1]
    end
    parts.join(" ")
  end

  def self.top(all, key)
    index = all.index { |depth, text| depth.zero? && unquote(text.partition(":")[0].strip) == key }
    raise Minitest::Assertion, "no top-level '#{key}'" if index.nil?

    index
  end

  # Map each trigger to its branch filter (nil when it has none).
  def self.triggers(name)
    all = lines(name)
    start = top(all, "on")
    result = {}
    children(all, start, 0).each do |event, _value, index|
      branches = nil
      children(all, index, all[index][0]).each do |key, inline, child|
        next unless key == "branches"

        if inline.start_with?("[")
          branches = inline.gsub(/\A[\[\]]+|[\[\]]+\z/, "").split(",")
                           .reject { |b| b.strip.empty? }.map { |b| unquote(b.strip) }
        else
          branches = []
          ((child + 1)...all.length).each do |later|
            depth, text = all[later]
            break if depth <= all[child][0] && !text.start_with?("- ")

            branches << unquote(text[2..].strip) if text.start_with?("- ")
          end
        end
      end
      result[event] = branches
    end
    result
  end

  # Map each job to its condition ('' when it has none).
  def self.jobs(name)
    all = lines(name)
    start = top(all, "jobs")
    result = {}
    children(all, start, 0).each do |job, _value, index|
      condition = ""
      children(all, index, all[index][0]).each do |key, _inline, child|
        condition = block(all, child) if key == "if"
      end
      result[job] = condition
    end
    result
  end

  # A condition with an alternative can hold outside main, so it is never
  # main-only by its text.
  def self.main_only_by_condition?(condition)
    !condition.include?("||") && MAIN_ONLY_CONDITIONS.any? { |pattern| pattern.match?(condition) }
  end

  def self.runs_only_for_main?(name, condition)
    return true if main_only_by_condition?(condition)

    triggers(name).each do |event, branches|
      next if event == "schedule"
      next if %w[push workflow_run].include?(event) && branches == ["main"]

      return false
    end
    true
  end

  TEST_JOBS.each do |name, names|
    define_method("test_#{name.tr('.-', '__')}_runs_on_every_2x_push_and_its_test_jobs_admit_2x") do
      found = self.class.triggers(name)
      # A push trigger with no branch filter runs on every branch.
      assert found.key?("push") && (found["push"].nil? || found["push"].include?("2.x")),
             "#{name} does not run on a 2.x push"
      conditions = self.class.jobs(name)
      names.each do |job|
        assert conditions.key?(job), "#{name} has no job #{job}"
        condition = conditions[job]
        assert !condition.include?("refs/heads/main") || condition.include?("refs/heads/2.x"),
               "#{name} job #{job} runs only for main: #{condition}"
      end
    end
  end

  RELEASE_JOBS.each do |name, names|
    define_method("test_every_release_notice_or_dispatch_job_of_#{name.tr('.-', '__')}_runs_only_for_main") do
      conditions = self.class.jobs(name)
      # The test jobs of this workflow admit 2.x in its triggers, so only the
      # condition can hold its release jobs to main.
      mixed = TEST_JOBS.key?(name)
      names.each do |job|
        assert conditions.key?(job), "#{name} has no job #{job}"
        condition = conditions[job]
        held = mixed ? self.class.main_only_by_condition?(condition) : self.class.runs_only_for_main?(name, condition)
        assert held, "#{name} job #{job} can run outside main"
      end
    end
  end

  def test_the_contract_reader_finds_every_workflow_trigger_and_job
    (TEST_JOBS.keys | RELEASE_JOBS.keys).each do |name|
      refute_empty self.class.triggers(name), "no triggers read from #{name}"
      found = self.class.jobs(name).keys
      refute_empty found, "no jobs read from #{name}"
      # Every job is named as a test job or a release job, so none escapes
      # the contract.
      listed = TEST_JOBS.fetch(name, []) + RELEASE_JOBS.fetch(name, [])
      assert_equal listed.sort, found.sort, "#{name} has a job the contract does not name"
    end
    assert self.class.triggers("export-kit.yml").key?("push")
    assert self.class.triggers("export-kit.yml").key?("schedule")
  end
end
