# frozen_string_literal: true

require "rake"
require "etc"
require "rbconfig"
require "tempfile"

# Test entrypoint for CI. Implements the operator's changed-files contract
# and keeps wall time bounded:
#
# - NM_CHANGED_FILES (one path per line): run only the test files that
#   exercise the changed paths. A changed test file runs itself; a changed
#   source path selects every test file whose text names its basename stem.
#   Every selected test keeps running; nothing is dropped. An empty
#   selection runs nothing by design (the whole suite runs unscoped).
# - .nm-test-shards at the repository root holds the shard count (2-8).
#   When NM_SHARD_INDEX and NM_SHARD_COUNT are set, this task runs only
#   shard NM_SHARD_INDEX (from 0) of NM_SHARD_COUNT of the selected files,
#   so together the shards cover every selected test.
# - Unscoped runs execute the whole suite as concurrent file shards (same
#   files, same cases; each shard is one minitest invocation over a disjoint
#   file subset); any shard failure fails the task. This is the same shard
#   plan scripts/test drives for the container gate, so local and CI runs
#   exercise identical coverage in bounded wall time.
#   test_dsl_float_choices.rb is the slowest single unit; it runs as
#   concurrent file shards of its own (NOISEMAKER_TEST_FILE_SHARD=i/n; each
#   shard covers a disjoint (effect, choice) subset, union = the whole file).
def effective_cores
  cores = Etc.nprocessors
  if RUBY_PLATFORM.include?("linux")
    begin
      quota, period = File.read("/sys/fs/cgroup/cpu.max").split
      if quota.match?(/\A\d+\z/) && period.match?(/\A\d+\z/) && period.to_i.positive?
        cores = [cores, quota.to_i / period.to_i].min
      end
    rescue StandardError
      cores
    end
  end
  [cores, 1].max
end

# Same selection rule scripts/test applies: a changed test file runs itself,
# and a changed other path selects the test files that name its stem.
def select_changed_files(files)
  changed = ENV["NM_CHANGED_FILES"]
  return [files, false] if changed.nil? || changed.strip.empty?
  wanted = []
  changed.split(/\s+/).reject(&:empty?).each do |path|
    if path.start_with?("test/test_") && path.end_with?(".rb")
      wanted << path if File.file?(path)
    else
      stem = File.basename(path).sub(/\.[^.]+\z/, "")
      next if stem.empty?
      files.each { |t| wanted << t if File.read(t).include?(stem) }
    end
  end
  [wanted.uniq.sort, true]
end

def apply_shard_selector(files)
  index = ENV["NM_SHARD_INDEX"]
  count = ENV["NM_SHARD_COUNT"]
  return files if index.nil? || index.empty? || count.nil? || count.empty?
  abort "rake test: NM_SHARD_INDEX/NM_SHARD_COUNT require .nm-test-shards" unless File.file?(".nm-test-shards")
  n = File.read(".nm-test-shards").strip.to_i
  i = index.to_i
  abort "rake test: invalid shard selector #{i} of #{n}" if n.negative? || i.negative? || i >= n || n < 1 || n > 8
  files.select.with_index { |_f, file_index| file_index % n == i }
end

task :test do
  all_files = Dir["test/test_*.rb"].sort
  abort "rake test: no test files found" if all_files.empty?
  files, scoped = select_changed_files(all_files)
  if scoped
    warn "rake test: changed-path scope selected: #{files.empty? ? '(none)' : files.join(' ')}"
    next if files.empty?
  end
  files = apply_shard_selector(files)
  float_choices = "test/test_dsl_float_choices.rb"
  shards = files.reject { |f| f == float_choices }
  eff_n = effective_cores
  ENV["NM_EFF_CORES"] = eff_n.to_s
  shard_n = [eff_n, 6].min
  ruby = RbConfig.ruby
  loader = ["--yjit", "-Ilib", "-Itest", "-e", "ARGV.each { |f| require File.expand_path(f) }"]

  groups = Hash.new { |h, k| h[k] = [] }
  shards.each_with_index { |f, i| groups[i % shard_n] << f }

  pids = {}
  logs = {}
  spawned = {}
  groups.each do |group, group_files|
    next if group_files.empty?
    log = Tempfile.create(["rake-shard-#{group}.", ".log"])
    logs[group] = log.path
    spawned[group] = group_files.join(" ")
    pids[group] = Process.spawn({ "NM_EFF_CORES" => eff_n.to_s },
                                ruby, *loader, *group_files, out: log, err: log)
    log.close
  end
  if File.file?(float_choices) && files.include?(float_choices)
    eff_n.times do |split_i|
      log = Tempfile.create(["rake-split-#{split_i}.", ".log"])
      logs[:"split#{split_i}"] = log.path
      spawned[:"split#{split_i}"] = float_choices
      env = { "NOISEMAKER_TEST_FILE_SHARD" => "#{split_i}/#{eff_n}", "NM_EFF_CORES" => eff_n.to_s }
      pids[:"split#{split_i}"] = Process.spawn(env, ruby, *loader, float_choices, out: log, err: log)
      log.close
    end
  end

  failed = []
  pids.each do |key, pid|
    _pid, status = Process.waitpid2(pid)
    if status.success?
      # Keep the per-shard minitest summary visible: the last two lines are
      # the runs/assertions tally and the finish banner.
      tail = File.readlines(logs[key]).last(2).join
      warn "[shard #{key}] #{tail.empty? ? '(no output)' : tail.strip}"
    else
      failed << key
      warn "\n=== failed shard #{key} (#{spawned[key]}) ==="
    end
  end
  failed.each { |key| warn File.read(logs[key]) }
  logs.each_value { |path| File.delete(path) }
  if failed.any?
    warn "rake test: #{failed.size} shard(s) failed"
    exit! 1
  end
end

task default: :test
