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
#   scripts/oracle-lock.json selects the lock test and demands a real
#   oracle checkout; a changed source path
#   selects every test file whose text names its basename stem. A changed
#   path that no test names selects the whole suite, so the runner and any
#   unowned path stay covered. Every selected test keeps running; nothing
#   is dropped. Unscoped runs select the whole suite.
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
# and a changed other path selects the test files that name its stem. Returns
# the selected test files, the changed kernel parity case ids, and a
# require-oracle flag: changed kernel files have no minitest coverage by
# name, so the scope must exercise them through the parity gate instead
# (same mapping scripts/test applies).
def select_changed_files(files)
  changed = ENV["NM_CHANGED_FILES"]
  return [files, [], false] if changed.nil? || changed.strip.empty?
  wanted = []
  parity_ids = []
  unmatched = []
  require_oracle = false
  changed.split(/\s+/).reject(&:empty?).each do |path|
    case path
    when /\Alib\/noisemaker_cpu\/bundle\/kernels\/ruby\/.*\.rb\z/
      # Kernel files are named <family>__<effect>__<variant>.rb and several
      # variants of one effect share the case id <family>/<effect>.
      base = File.basename(path, ".rb")
      family = base.split("__", 2).first
      rest = base.split("__", 2).last || ""
      effect = rest.split("__", 2).first
      if family && effect && !effect.empty?
        parity_ids << "#{family}/#{effect}"
      else
        unmatched << path
      end
    when /\Atest\/test_.*\.rb\z/
      wanted << path if File.file?(path)
    when "scripts/oracle-lock.json"
      # The oracle pin: test/test_parity.rb's lock-and-snapshot test asserts
      # the oracle checkout's source-lock.js and snapshot against every
      # field of this lock (revision via the checkout HEAD check,
      # upstreamRevision and sourceDigest via the pinned constants). It runs
      # only against a real oracle checkout, so the scope demands one.
      wanted << "test/test_parity.rb" if File.file?("test/test_parity.rb")
      require_oracle = true
    else
      stem = File.basename(path).sub(/\.[^.]+\z/, "")
      if stem.empty?
        unmatched << path
        next
      end
      hits = files.select { |t| File.read(t).include?(stem) }
      hits.empty? ? unmatched << path : wanted.concat(hits)
    end
  end
  unless unmatched.empty?
    # A changed path that no test names (the runner itself, or an unowned
    # path) stays covered: run the whole suite, which exercises it.
    warn "rake test: no test names #{unmatched.join(' ')}; running the whole suite to cover them"
    wanted = files
  end
  [wanted.uniq.sort, parity_ids.uniq, require_oracle, true]
end

# Changed kernels render through the parity gate under the changed-path
# scope: run scripts/parity-summary for exactly their case ids.
def run_kernel_parity(parity_ids)
  return if parity_ids.empty?
  warn "rake test: changed-path scope runs the parity gate for the changed kernels: #{parity_ids.join(' ')}"
  ok = system(RbConfig.ruby, "--yjit", File.expand_path("parity-summary.rb", "scripts"),
              *parity_ids, out: $stderr, err: $stderr)
  abort "rake test: parity gate failed for the changed kernels" unless ok
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
  files, parity_ids, require_oracle, scoped = select_changed_files(all_files)
  if scoped
    warn "rake test: changed-path scope selected: #{files.empty? ? '(none)' : files.join(' ')}"
    if files.empty? && parity_ids.empty?
      next
    end
  end
  # The lock-selection scope demands a real oracle checkout: with
  # NOISEMAKER_REQUIRE_ORACLE=1 an absent oracle fails the run instead of
  # silently skipping the pin assertions.
  spawn_env = { "NM_EFF_CORES" => nil }
  spawn_env["NOISEMAKER_REQUIRE_ORACLE"] = "1" if require_oracle
  files = apply_shard_selector(files)
  float_choices = "test/test_dsl_float_choices.rb"
  shards = files.reject { |f| f == float_choices }
  eff_n = effective_cores
  ENV["NM_EFF_CORES"] = eff_n.to_s
  spawn_env["NM_EFF_CORES"] = eff_n.to_s
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
    pids[group] = Process.spawn(spawn_env,
                                ruby, *loader, *group_files, out: log, err: log)
    log.close
  end
  if File.file?(float_choices) && files.include?(float_choices)
    eff_n.times do |split_i|
      log = Tempfile.create(["rake-split-#{split_i}.", ".log"])
      logs[:"split#{split_i}"] = log.path
      spawned[:"split#{split_i}"] = float_choices
      env = spawn_env.merge("NOISEMAKER_TEST_FILE_SHARD" => "#{split_i}/#{eff_n}")
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
  run_kernel_parity(parity_ids)
end

task default: :test
